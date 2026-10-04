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

    kinds = Enum.map(Map.values(overlays), & &1.kind)
    nudge_downloads(:sonarr, kinds, fn -> Aviary.ImportNudge.imported_show(tmdb_id, user) end)

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

    kinds = [DownloadState.serialize(state).kind]
    nudge_downloads(:radarr, kinds, fn -> Aviary.ImportNudge.library(user) end)

    json(conn, %{
      overall: DownloadState.serialize(state),
      label: Aviary.WatchProgress.label(state, runtime(params), movie_timeleft(status))
    })
  end

  # Same side-effects the web detail page fires while a download is in
  # flight, so the native client's Importing → Play transition doesn't
  # wait on Jellyfin's scheduled scan. A live download nudges the
  # downloader to refresh its queue; an import hands off to
  # Aviary.ImportNudge, which paces its own requests to Jellyfin.
  defp nudge_downloads(downloader, kinds, nudge_jellyfin) do
    if "downloading" in kinds do
      throttle({:dl_refresh, downloader}, 5_000, fn -> refresh_downloader(downloader) end)
    end

    if "imported" in kinds, do: nudge_jellyfin.()

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
