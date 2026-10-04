defmodule Aviary.ImportNudge do
  @moduledoc """
  Gets Jellyfin to notice files Sonarr or Radarr just imported, so the
  "Importing…" chip turns into "Play" without waiting for Jellyfin's
  scheduled scan.

  Two things go wrong without care here, and both showed up on
  2026-10-04 with a freshly added show:

    * Jellyfin creates a new series under one key and re-keys it once
      its metadata arrives, but the episodes keep the old key until
      something re-saves them, and until then the episodes endpoint
      returns nothing. A refresh scoped to the series re-saves them in
      seconds. A full library scan also does, eventually.

    * Asking for a full library scan restarts any scan already running.
      Polling that asked every five seconds kept cancelling the scan it
      was waiting on, for as long as someone watched the page.

  So: when the series is already known to Jellyfin, refresh that series;
  ask for a library-wide scan only on a long cooldown and never while
  one is running.
  """
  require Logger

  alias Aviary.Jellyfin

  @series_refresh_cooldown_ms 30_000
  @library_scan_cooldown_ms 30_000

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
    throttle(:jellyfin_library_refresh, @library_scan_cooldown_ms, fn ->
      case Jellyfin.refresh_library(auth) do
        :ok -> Logger.info("import_nudge: library scan requested")
        :already_running -> Logger.info("import_nudge: library scan already running, left alone")
        :error -> Logger.warning("import_nudge: library scan request failed")
      end
    end)
  end

  defp throttle(key, cooldown_ms, fun) do
    Aviary.Cache.fetch(key, cooldown_ms, fn ->
      fun.()
      :stamped
    end)

    :ok
  end
end
