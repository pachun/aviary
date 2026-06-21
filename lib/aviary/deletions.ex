defmodule Aviary.Deletions do
  @moduledoc """
  Auto-delete downloaded media that nobody's currently tracking, after
  a 24-hour grace period — so disk space frees up without instantly
  losing accidental removes.

  Trigger: when the LAST household subscriber removes a show/movie
  from their library AND every successful import for that title came
  via Usenet (so deletion can't break a torrent seed), a
  `pending_deletions` row is inserted with `scheduled_for = now + 24h`.

  Cancel: any re-add (by anyone) deletes the matching row. There's no
  user-facing "cancel" gesture beyond re-adding.

  Execute: `Aviary.Deletions.Scheduler` polls hourly. For each due
  row it re-verifies state hasn't changed (still zero subscribers,
  still usenet-only) and then deletes via Sonarr/Radarr API.
  """

  import Ecto.Query

  alias Aviary.{Library, Radarr, Repo, Sonarr}
  alias Aviary.Deletions.PendingDeletion

  require Logger

  # Default if the env var isn't set — kept here rather than baked
  # into config/runtime.exs's `Map.get` default so tests can override
  # via Application.put_env without touching the system env.
  @default_grace_hours 24

  @doc """
  Hours of grace between a library removal and the scheduled
  deletion. Reads `:aviary, :deletion_grace_period_hours` at runtime
  so a config change (env var → app config in runtime.exs) takes
  effect without recompile.
  """
  def grace_hours do
    Application.get_env(:aviary, :deletion_grace_period_hours, @default_grace_hours)
  end

  @doc """
  Enqueue an auto-deletion for `tmdb_id` (`kind` = "show" | "movie")
  IF the criteria are met:

    - No remaining library subscribers (caller should usually have
      just verified this; we re-check for safety).
    - The arr that owns this title reports every import came from
      Usenet (no torrent contamination).

  Returns:
    {:ok, :scheduled}     — row inserted (or updated to a fresh
                            grace window if one already existed)
    {:ok, :still_subscribed} — somebody still has it; no-op
    {:ok, :has_torrents}     — torrent contamination; no-op
    {:ok, :not_in_arr}       — the arr doesn't know this title
                              (manual import? user purge?) — no-op
    :error                   — couldn't reach the arr
  """
  def schedule(tmdb_id, kind) when kind in ["show", "movie"] do
    cond do
      Library.subscribers(tmdb_id) != [] ->
        {:ok, :still_subscribed}

      true ->
        case usenet_only?(tmdb_id, kind) do
          {:ok, true} ->
            do_schedule(tmdb_id, kind)
            {:ok, :scheduled}

          {:ok, false} ->
            {:ok, :has_torrents}

          {:error, :not_in_arr} ->
            {:ok, :not_in_arr}

          :error ->
            :error
        end
    end
  end

  @doc """
  Delete any pending_deletion row for this tmdb_id. Idempotent —
  no error if nothing was scheduled. Called from Library.add on
  every add so a re-add transparently cancels a pending delete.
  """
  def cancel(tmdb_id) do
    from(pd in PendingDeletion, where: pd.tmdb_id == ^to_string(tmdb_id))
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Returns a list of `PendingDeletion` rows whose scheduled_for is in
  the past. Caller (the Scheduler) decides what to do with each.
  """
  def due_now do
    now = DateTime.utc_now()

    from(pd in PendingDeletion,
      where: pd.scheduled_for <= ^now,
      order_by: [asc: pd.scheduled_for]
    )
    |> Repo.all()
  end

  @doc """
  List all pending_deletions (any scheduled_for). Used by the Scheduler
  for telemetry / future surfacing on the detail page.
  """
  def all do
    Repo.all(from(pd in PendingDeletion, order_by: [asc: pd.scheduled_for]))
  end

  # ============================================================
  # Internals
  # ============================================================

  defp do_schedule(tmdb_id, kind) do
    scheduled_for =
      DateTime.utc_now()
      |> DateTime.add(grace_hours() * 60 * 60, :second)

    attrs = %{
      tmdb_id: to_string(tmdb_id),
      scheduled_for: scheduled_for,
      kind: kind,
      reason: "all_subscribers_removed"
    }

    Logger.info(
      "deletions schedule tmdb_id=#{tmdb_id} kind=#{kind} scheduled_for=#{scheduled_for}"
    )

    # Upsert by tmdb_id: a second remove (after a re-add and re-remove
    # within the grace window) resets the timer fresh. Without this,
    # a user could re-add → re-remove and the original scheduled_for
    # would still be authoritative, which is surprising.
    %PendingDeletion{}
    |> PendingDeletion.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:scheduled_for, :reason, :updated_at]},
      conflict_target: [:tmdb_id]
    )
  end

  defp usenet_only?(tmdb_id, "show") do
    case Sonarr.find_series_by_tmdb(tmdb_id) do
      {:ok, series} -> {:ok, Sonarr.all_imports_were_usenet?(series["id"])}
      :not_found -> {:error, :not_in_arr}
      :error -> :error
    end
  end

  defp usenet_only?(tmdb_id, "movie") do
    case Radarr.find_movie_by_tmdb(tmdb_id) do
      {:ok, movie} -> {:ok, Radarr.all_imports_were_usenet?(movie["id"])}
      :not_found -> {:error, :not_in_arr}
      :error -> :error
    end
  end

  @doc """
  Carry out a single due PendingDeletion: re-verify state and call
  the arr to delete. Returns:
    :ok               — deletion executed (or correctly skipped)
    :skipped_resubscribed — somebody re-added; row already deleted
                            via cancel/1 by Library.add — this should
                            not happen but is handled defensively
    :skipped_now_has_torrents — usenet-only flipped to false; defer
    :error            — arr call failed; leave row for next cycle
  """
  def execute(%PendingDeletion{} = pd) do
    cond do
      Library.subscribers(pd.tmdb_id) != [] ->
        # Race: re-added between scan and execute. Drop the row.
        Repo.delete(pd)
        Logger.info("deletions skip resubscribed tmdb_id=#{pd.tmdb_id}")
        :skipped_resubscribed

      true ->
        case usenet_only?(pd.tmdb_id, pd.kind) do
          {:ok, false} ->
            # A torrent landed since we scheduled. Defer indefinitely —
            # the row stays, but next cycles will keep skipping. If you
            # ever want this to time-out and fail-loud, add an age check.
            Logger.info("deletions skip now_has_torrents tmdb_id=#{pd.tmdb_id}")
            :skipped_now_has_torrents

          {:error, :not_in_arr} ->
            # The arr forgot about it (manual purge, etc). Nothing to
            # delete; drop the row.
            Repo.delete(pd)
            Logger.info("deletions skip not_in_arr tmdb_id=#{pd.tmdb_id}")
            :ok

          {:ok, true} ->
            execute_arr_delete(pd)

          :error ->
            Logger.warning(
              "deletions arr_unreachable tmdb_id=#{pd.tmdb_id} kind=#{pd.kind} — will retry next cycle"
            )

            :error
        end
    end
  end

  defp execute_arr_delete(pd) do
    result =
      case pd.kind do
        "show" ->
          case Sonarr.find_series_by_tmdb(pd.tmdb_id) do
            {:ok, series} -> Sonarr.delete_series(series["id"])
            _ -> :error
          end

        "movie" ->
          case Radarr.find_movie_by_tmdb(pd.tmdb_id) do
            {:ok, movie} -> Radarr.delete_movie(movie["id"])
            _ -> :error
          end
      end

    case result do
      :ok ->
        Repo.delete(pd)

        Logger.info(
          "deletions executed tmdb_id=#{pd.tmdb_id} kind=#{pd.kind} reason=#{pd.reason}"
        )

        :ok

      :error ->
        Logger.warning(
          "deletions arr_delete_failed tmdb_id=#{pd.tmdb_id} kind=#{pd.kind} — leaving row, will retry"
        )

        :error
    end
  end
end
