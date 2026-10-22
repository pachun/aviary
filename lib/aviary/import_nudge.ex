defmodule Aviary.ImportNudge do
  @moduledoc """
  Gets Jellyfin to notice files Sonarr or Radarr just imported, so the
  "Importing…" chip turns into "Play" without waiting for Jellyfin's
  scheduled scan.

  The moment that matters is the import itself: Sonarr's webhook
  reports it with the show's TMDB id, and `episode_landed/1` either
  refreshes that series in Jellyfin (seconds) or, for a show Jellyfin
  has never seen, asks for one library scan. Clients polling download
  status still nudge through `imported_show/2` and `library/1`, but
  gently, because they can't tell when a file actually landed.

  Two things go wrong without care here, and both showed up on
  2026-10-04 with a freshly added show:

    * Jellyfin creates a new series under one key and re-keys it once
      its metadata arrives, but the episodes keep the old key until
      something re-saves them, and until then the episodes endpoint
      returns nothing. A refresh scoped to the series re-saves them in
      seconds. A full library scan also does, eventually.

    * Asking for a full library scan restarts any scan already running,
      and stops Jellyfin's own file watcher while it runs. Polling that
      asked every few seconds kept cancelling the scan it was waiting
      on, and once walked a show's folder three seconds before its
      first episode arrived, so neither the scan nor the watcher saw
      the file.
  """
  require Logger

  alias Aviary.Jellyfin

  @series_refresh_cooldown_ms 30_000
  @polled_library_scan_cooldown_ms :timer.minutes(2)
  @import_series_refresh_cooldown_ms 5_000
  @busy_scan_retry_ms 15_000
  @busy_scan_retries 4

  @doc """
  Sonarr just imported an episode of the show with this TMDB id.
  Refreshes the series if Jellyfin lists it, otherwise asks for a
  library scan so Jellyfin creates it, waiting out a scan already in
  progress rather than restarting it.
  """
  def episode_landed(tmdb_id, options \\ []) do
    busy_scan_retry_ms = Keyword.get(options, :busy_scan_retry_ms, @busy_scan_retry_ms)

    case Jellyfin.server_auth() do
      nil ->
        Logger.warning(
          "import_nudge: no Jellyfin API key; leaving the import to Jellyfin's own scan"
        )

      auth ->
        case Jellyfin.find_series_by_tmdb(tmdb_id, auth) do
          nil -> scan_library_once_idle(auth, busy_scan_retry_ms, @busy_scan_retries)
          series_id -> refresh_series_after_import(series_id, auth)
        end
    end

    :ok
  end

  @doc "A show, by TMDB id, has files on disk that Jellyfin hasn't listed yet."
  def imported_show(tmdb_id, auth) do
    case Aviary.Catalog.jellyfin_series_id(tmdb_id, auth) do
      nil ->
        library(auth)

      series_id ->
        throttle({:jellyfin_series_refresh, series_id}, @series_refresh_cooldown_ms, fn ->
          Logger.info("import_nudge: refreshing series #{series_id}")
          Jellyfin.refresh_series(series_id, auth)
        end)

        library(auth)
    end
  end

  @doc "Something has files on disk that Jellyfin hasn't listed yet, and no narrower target is known."
  def library(auth) do
    throttle(:jellyfin_library_refresh, @polled_library_scan_cooldown_ms, fn ->
      case Jellyfin.refresh_library(auth) do
        :ok -> Logger.info("import_nudge: library scan requested")
        :already_running -> Logger.info("import_nudge: library scan already running, left alone")
        :error -> Logger.warning("import_nudge: library scan request failed")
      end
    end)
  end

  defp refresh_series_after_import(series_id, auth) do
    throttle(
      {:jellyfin_series_refresh_after_import, series_id},
      @import_series_refresh_cooldown_ms,
      fn ->
        Logger.info("import_nudge: refreshing series #{series_id} for an import")
        Jellyfin.refresh_series(series_id, auth)
      end
    )
  end

  defp scan_library_once_idle(_auth, _retry_ms, 0) do
    Logger.warning(
      "import_nudge: library scan stayed busy; leaving the new series to the next scan"
    )
  end

  defp scan_library_once_idle(auth, retry_ms, tries_left) do
    case Jellyfin.refresh_library(auth) do
      :ok ->
        Logger.info("import_nudge: library scan requested for a series Jellyfin hasn't seen")

      :already_running ->
        Process.sleep(retry_ms)
        scan_library_once_idle(auth, retry_ms, tries_left - 1)

      :error ->
        Logger.warning("import_nudge: library scan request failed")
    end
  end

  defp throttle(key, cooldown_ms, fun) do
    Aviary.Cache.fetch(key, cooldown_ms, fn ->
      fun.()
      :stamped
    end)

    :ok
  end
end
