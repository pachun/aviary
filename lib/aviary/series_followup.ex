defmodule Aviary.SeriesFollowup do
  @moduledoc """
  Two-stage download flow for shows. When a user clicks ↓ on a single
  episode in the show detail page:

    1. Aviary fires `Sonarr.watch_episode/3` for that one episode
       (existing behavior — monitor=none for the series, monitor=true
       for the chosen episode, EpisodeSearch).
    2. `after_episode_imports/3` (this module) is spawned as a
       detached Task. It polls Sonarr roughly every 30 s for the
       chosen episode's `has_file` field. When that flips true, it
       calls `Sonarr.watch_show/1` to broaden monitoring to the rest
       of the series and grab everything still missing.

  Net effect: the one episode the user actually wants to start with
  gets the entire download pipe to itself. Once the file lands, the
  rest of the series queues up behind it. Two users starting two
  different shows at the same time don't compete for bandwidth on
  later episodes neither of them is about to watch.

  No persistence — the Task runs in-process and dies on aviary
  restart. If aviary restarts mid-poll the followup is lost; the
  next time the user clicks any other episode they'll re-trigger.
  This is intentional v1 simplicity; persisting is a follow-up if
  the loss-on-restart turns out to matter.
  """

  require Logger

  alias Aviary.Sonarr

  # Poll Sonarr every 30s. Sonarr's qBit refresh runs every ~90s on
  # its own, so polling faster doesn't get us fresher data; 30s is
  # comfortably below that and matches typical "I started this and
  # now I'm scrolling" cadence.
  @poll_interval_ms 30_000

  # Hard ceiling of 60 polls = 30 minutes. Most 1080p TV episodes
  # finish well under that; a release that takes longer is probably
  # never going to land (dead torrent, no usenet article). We don't
  # want to leak processes if Sonarr's stuck on something forever.
  @max_polls 60

  @doc """
  Start a detached Task that watches the chosen episode and, when
  that episode's file has landed, broadens monitoring to the whole
  series.

  Returns the spawned Task's pid (for tests + telemetry). Callers
  fire-and-forget — the LiveView click handler doesn't await.
  """
  def after_episode_imports(tmdb_id, season, episode) do
    Task.start(fn -> poll(tmdb_id, season, episode, @max_polls) end)
  end

  defp poll(_tmdb_id, _season, _episode, 0) do
    Logger.info("series_followup giving up — episode never imported within budget")
    :timeout
  end

  defp poll(tmdb_id, season, episode, polls_remaining) do
    Process.sleep(@poll_interval_ms)

    case episode_has_file?(tmdb_id, season, episode) do
      true ->
        Logger.info(
          "series_followup episode imported; broadening to series tmdb_id=#{tmdb_id}"
        )

        # Same call the "Watch the whole show" button would make —
        # idempotent (ensure_series widens monitoring; search_each_missing
        # only fires for episodes Sonarr knows are missing).
        Sonarr.watch_show(tmdb_id)
        :ok

      false ->
        poll(tmdb_id, season, episode, polls_remaining - 1)

      :unknown ->
        # Couldn't reach Sonarr or the series isn't there yet. Keep
        # trying — the budget still counts down so a permanent
        # unreachability eventually times out.
        poll(tmdb_id, season, episode, polls_remaining - 1)
    end
  end

  defp episode_has_file?(tmdb_id, season, episode) do
    case Sonarr.series_status(tmdb_id) do
      {:ok, %{episodes: episodes}} ->
        case Map.get(episodes, {season, episode}) do
          %{has_file: true} -> true
          %{has_file: false} -> false
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end
end
