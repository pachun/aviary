defmodule AviaryWeb.API.StatusController do
  @moduledoc """
  Live download status for native clients — polled every few seconds
  while a title is being grabbed. Keyed by TMDB id so it works whether
  the title is in the library yet or not, and reflects downloads
  triggered on any device (the truth lives in Sonarr/Radarr).

  Returns the same states the web detail page shows, through the shared
  `Aviary.DownloadState`: the overall state (mirrors the first episode /
  the movie), the "until watchable" label, and — for shows — a per-
  episode overlay map keyed "season:episode". `runtime` (minutes) is
  passed by the client so the pre-download estimate can be computed.
  """
  use AviaryWeb, :controller

  alias Aviary.DownloadState

  def show(conn, %{"tmdb_id" => tmdb_id} = params) do
    user = conn.assigns.current_user

    status =
      case Aviary.Sonarr.series_status(tmdb_id) do
        {:ok, status} -> status
        _ -> nil
      end

    overall = DownloadState.show_overall(status)
    overlays = DownloadState.episode_overlays(status)

    nudge_downloads(user, :sonarr, Enum.map(Map.values(overlays), & &1.kind))

    json(conn, %{
      overall: DownloadState.serialize(overall),
      label: Aviary.WatchProgress.label(overall, runtime(params), show_timeleft(status)),
      episodes: overlays
    })
  end

  def movie(conn, %{"tmdb_id" => tmdb_id} = params) do
    user = conn.assigns.current_user

    status =
      case Aviary.Radarr.movie_status(tmdb_id) do
        {:ok, status} -> status
        _ -> nil
      end

    state = DownloadState.movie_state(status)

    nudge_downloads(user, :radarr, [DownloadState.serialize(state).kind])

    json(conn, %{
      overall: DownloadState.serialize(state),
      label: Aviary.WatchProgress.label(state, runtime(params), movie_timeleft(status))
    })
  end

  # Same side-effects the web detail page fires while a download is in
  # flight, so the native client's Importing → Play transition doesn't
  # wait on Jellyfin's scheduled scan. A live download nudges the
  # downloader to refresh its queue; an import nudges Jellyfin to rescan
  # so the finished file appears promptly. Throttled globally (5s) via
  # the cache, matching the poll cadence; Jellyfin dedupes concurrent
  # scans.
  defp nudge_downloads(user, downloader, kinds) do
    if "downloading" in kinds do
      throttle({:dl_refresh, downloader}, 5_000, fn -> refresh_downloader(downloader) end)
    end

    if "imported" in kinds do
      throttle(:jellyfin_library_refresh, 5_000, fn -> Aviary.Jellyfin.refresh_library(user) end)
    end

    :ok
  end

  defp refresh_downloader(:sonarr), do: Aviary.Sonarr.refresh_monitored_downloads()
  defp refresh_downloader(:radarr), do: Aviary.Radarr.refresh_monitored_downloads()

  defp throttle(key, cooldown_ms, fun) do
    Aviary.Cache.fetch(key, cooldown_ms, fn ->
      fun.()
      :stamped
    end)

    :ok
  end

  defp show_timeleft(nil), do: nil

  defp show_timeleft(status) do
    with {s, e} <- DownloadState.first_episode_key(status),
         %{id: id} <- Map.get(status.episodes, {s, e}) do
      DownloadState.timeleft_seconds(status.queue, id)
    else
      _ -> nil
    end
  end

  defp movie_timeleft(%{queue: [%{"movieId" => id} | _], radarr_movie_id: _} = status),
    do: DownloadState.timeleft_seconds(status.queue, id)

  defp movie_timeleft(_), do: nil

  defp runtime(%{"runtime" => runtime}) when is_binary(runtime) do
    case Integer.parse(runtime) do
      {minutes, _} -> minutes
      :error -> nil
    end
  end

  defp runtime(_), do: nil
end
