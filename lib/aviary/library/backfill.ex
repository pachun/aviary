defmodule Aviary.Library.Backfill do
  @moduledoc """
  Seeds `library_entries` from a user's pre-existing Jellyfin watch
  history. Without this, deploying the library-gated home page would
  show empty Continue Watching to every user that already had a
  watch history (which is everyone right now).

  Runs at most once per user: the existence of a row in
  `user_backfills` is the signal "already done." Idempotent in
  insert behavior (the unique constraint on library_entries handles
  collisions) but the user_backfills check avoids the wasted
  Jellyfin round-trip on every page load.
  """

  alias Aviary.Library
  alias Aviary.Library.UserBackfill
  alias Aviary.Repo

  @doc """
  Runs backfill for the given user if it hasn't been done. Cheap
  short-circuit when already done — a single primary-key lookup.
  Safe to call from request hot paths; intended use is in
  `fetch_current_user` after token validation.
  """
  def ensure_run(auth) do
    if Repo.get(UserBackfill, auth.id) == nil do
      run(auth)
    end

    :ok
  end

  defp run(auth) do
    # Same two signals applied to both kinds of media:
    #   1. Has played any episode of a show / any movie (Filters=IsPlayed)
    #   2. Has any saved playback position
    # Episodes → parent SeriesId → batch-lookup TMDB ids → insert.
    # Movies → ProviderIds.Tmdb is on the item itself → insert directly.
    played = Aviary.Jellyfin.recently_watched(auth)
    in_progress = Aviary.Jellyfin.resume_items(auth)
    all = played ++ in_progress

    series_ids =
      all
      |> Enum.filter(&(&1["Type"] == "Episode"))
      |> Enum.map(& &1["SeriesId"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    tmdb_map = Aviary.Jellyfin.series_tmdb_map(series_ids, auth)

    Enum.each(tmdb_map, fn
      {_jellyfin_id, tmdb_id} when is_binary(tmdb_id) and tmdb_id != "" ->
        Library.add(auth.id, tmdb_id)

      _ ->
        :ok
    end)

    all
    |> Enum.filter(&(&1["Type"] == "Movie"))
    |> Enum.map(&get_in(&1, ["ProviderIds", "Tmdb"]))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.each(&Library.add(auth.id, &1))

    Repo.insert!(%UserBackfill{
      jellyfin_user_id: auth.id,
      backfilled_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    :ok
  rescue
    _ -> :error
  end
end
