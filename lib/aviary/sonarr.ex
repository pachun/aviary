defmodule Aviary.Sonarr do
  require Logger

  @moduledoc """
  Thin wrapper over Sonarr's v3 API. Three things drive everything
  aviary asks of it:

    * **Add intent** — `watch_show/1` and `watch_episode/3` translate
      the two button tiers into Sonarr
      operations. Each is "ensure series exists in Sonarr, set
      monitoring at this scope, kick off a search at this scope."
      Idempotent: re-running widens monitoring; it never narrows
      (per the multi-user model — once anyone in the household
      committed to a show, only an admin going to Sonarr directly
      can pull back).

    * **Status query** — `series_status/1` returns the current
      monitoring + per-episode availability + download progress
      for a single show, given its TMDB id. This is what the show
      detail page calls every poll cycle to decide what state each
      button should render in.

    * **Internal lookups** — `find_series_by_tmdb/1`,
      `add_series/2` are the building blocks. Exposed so tests and
      the queue-polling subscriber process can use them directly.

  Sonarr's preferred external id is TVDB id, not TMDB id — its
  lookup endpoint takes either, but the series record itself stores
  tvdbId as the primary external link. We never expose tvdbId to
  callers; aviary's whole world stays TMDB-keyed and we resolve
  internally.
  """

  @behaviour_default_monitor "all"
  @behaviour_default_quality_profile 4
  @behaviour_default_root_folder "/shows"

  @doc """
  "Watch the whole show" — adds the series with monitor=all, then
  fires a per-episode EpisodeSearch for every aired, monitored,
  fileless episode in sequence (E1, E2, ... so the earliest episode
  is queued first and grabbed first).

  Why not `SeriesSearch` (Sonarr's "search the whole series" command)?
  `SeriesSearch` and Sonarr's automatic post-add search both issue a
  SINGLE season-level indexer query whose response is paginated
  (~50 results per indexer). The most-recently-aired / most-seeded
  episodes dominate that result page, so less-popular older episodes
  get crowded out and never grabbed — even when releases for them
  exist on the indexer. We learned this the hard way when Widow's Bay
  E2-E7 sat ungrabbed for weeks despite 11+ approved 1080p releases
  each. Per-episode searches force one indexer query per episode,
  giving each its own result depth.

  When the series already exists in Sonarr, widens monitoring +
  re-fires per-episode searches for whatever's still missing.
  """
  def watch_show(tmdb_id) do
    with {:ok, series} <- ensure_series(tmdb_id, monitor: "all", search: false) do
      # search_each_missing runs in a Task because it has to wait out
      # Sonarr's async RefreshEpisodeService — the /series POST returns
      # before episodes are populated, so we'd see [] from /episode and
      # fire zero searches on a fresh add. Backgrounding lets the
      # LiveView return immediately (the button flips to "Searching"
      # right away) while the wait-then-fire happens off the request
      # path.
      Task.start(fn -> search_each_missing(series["id"]) end)
      {:ok, series}
    end
  end

  @doc """
  Resolves the first aired episode (lowest real season, earliest episode)
  so "add the whole show" can grab that one first and broaden to the rest
  afterward — the same two-stage flow tapping a single episode uses.
  Returns `{:ok, season, episode}` or `:error` (e.g. nothing aired yet,
  or Sonarr unreachable).
  """
  def first_episode(tmdb_id) do
    with {:ok, series} <- ensure_series(tmdb_id, monitor: "none", search: false) do
      today = Aviary.LocalTime.today()

      series["id"]
      |> wait_for_episodes()
      |> Enum.filter(fn ep -> (ep["seasonNumber"] || 0) > 0 and aired?(ep, today) end)
      |> Enum.sort_by(fn ep -> {ep["seasonNumber"], ep["episodeNumber"]} end)
      |> List.first()
      |> case do
        %{"seasonNumber" => season, "episodeNumber" => episode} ->
          {:ok, season, episode}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  @doc """
  "Watch one episode" — ensures the series exists (monitor=none),
  monitors the specific episode, fires an EpisodeSearch. Doesn't
  touch season-level monitoring, so this stays a low-commitment
  trial; the user can broaden to season or full show later.
  """
  def watch_episode(tmdb_id, season_number, episode_number) do
    with {:ok, series} <- ensure_series(tmdb_id, monitor: "none"),
         {:ok, episode} <- find_episode(series["id"], season_number, episode_number),
         :ok <- monitor_episodes([episode["id"]], true) do
      command("EpisodeSearch", %{episodeIds: [episode["id"]]})
      {:ok, episode}
    end
  end

  @doc """
  Forces Sonarr to re-query qBittorrent for download progress right
  now. Sonarr's own `RefreshMonitoredDownloads` scheduled task only
  runs ~every 90 seconds, so progress in our chip otherwise updates
  in big chunks (and gets stuck at the last reported percent for up
  to a minute and a half after qBit actually finishes). Polling
  this from the show detail page collapses that lag.
  """
  def refresh_monitored_downloads do
    command("RefreshMonitoredDownloads", %{})
  end

  @doc """
  Fires an EpisodeSearch command for one or more episode ids. Public
  because `Aviary.Reconcile` re-uses it to retry grabs that failed
  on Sonarr's side without aviary having issued them in the first
  place.
  """
  def episode_search(episode_ids) when is_list(episode_ids) do
    command("EpisodeSearch", %{episodeIds: episode_ids})
  end

  @doc """
  Returns `{:ok, %{"records" => […], "totalRecords" => N}}` from
  Sonarr's paginated `/wanted/missing` endpoint. Used by
  `Aviary.Reconcile` to enumerate monitored-aired-missing episodes
  for catch-up.
  """
  def wanted_missing(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :pageSize, 100)

    case get("/wanted/missing",
           page: page,
           pageSize: page_size,
           sortKey: "airDateUtc",
           sortDirection: "descending"
         ) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> :error
    end
  end

  @doc """
  Returns Sonarr's `/queue` body. Used by `Aviary.Reconcile` to skip
  re-firing searches on episodes that are already actively
  downloading.
  """
  def queue(opts \\ []) do
    page_size = Keyword.get(opts, :pageSize, 100)

    case get("/queue", pageSize: page_size, includeEpisode: true) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> :error
    end
  end

  @doc """
  Lists Sonarr's manual-import candidates for a completed download —
  each parsed file with its matched series/episodes/quality and any
  rejections. `Aviary.Reconcile` uses this to auto-clear downloads
  Sonarr flags as "matched to series by ID" (import-blocked but with
  clean, unambiguous files).
  """
  def manual_import_candidates(download_id) do
    case get("/manualimport", downloadId: download_id, filterExistingFiles: false) do
      {:ok, files} when is_list(files) -> {:ok, files}
      _ -> :error
    end
  end

  @doc """
  Force-imports already-prepared files via Sonarr's ManualImport
  command. `files` are candidate rows from `manual_import_candidates/1`
  shaped into the command's expected form. `importMode: "auto"` lets
  Sonarr hardlink/copy per its own download-client settings.
  """
  def manual_import(files) when is_list(files) and files != [] do
    command("ManualImport", %{importMode: "auto", files: files})
  end

  def manual_import(_), do: :error

  @doc """
  Returns a `%{monitored: bool, episodes: map, queue: list}` snapshot
  for a single show. The episodes map is keyed by
  `{season, episode}` so callers can look up state per episode
  without scanning. The queue is the active download records for
  this series; each carries `episodeId`, `size`, `sizeleft`, `status`.

  Returns `:not_found` when the series isn't in Sonarr yet —
  callers treat that as "user hasn't pressed any Watch button yet."
  """
  def series_status(tmdb_id) do
    case find_series_by_tmdb(tmdb_id) do
      {:ok, series} ->
        episodes = list_episodes(series["id"])
        queue = list_queue_for_series(series["id"])

        {:ok,
         %{
           sonarr_series_id: series["id"],
           # Sonarr knows the on-disk path; we surface it so the
           # show detail page can use it to call Jellyfin's
           # /Library/Media/Updated when an import lands, telling
           # Jellyfin "scan this specific folder for new files
           # right now" instead of waiting for its scheduled scan.
           path: series["path"],
           monitored: series["monitored"] == true,
           episodes:
             Map.new(episodes, fn ep ->
               {{ep["seasonNumber"], ep["episodeNumber"]},
                %{
                  id: ep["id"],
                  monitored: ep["monitored"] == true,
                  has_file: ep["hasFile"] == true,
                  air_date: ep["airDate"]
                }}
             end),
           queue: queue
         }}

      :not_found ->
        :not_found

      :error ->
        :error
    end
  end

  ## Building blocks (public so the polling subscriber can use them)

  # Cache key for the Sonarr-wide /series list. 15s fresh / 60s stale —
  # the show detail page polls series_status every few seconds and each
  # poll walks /series; SWR makes the second-and-onward poll instant
  # (and we still pick up newly-added series within 15s, which is well
  # below the Sonarr add → Jellyfin scan → user-visible latency).
  @series_fresh_ms 15_000
  @series_stale_ms 60_000

  def find_series_by_tmdb(tmdb_id) do
    case all_series() do
      {:ok, all} ->
        case Enum.find(all, &(to_string(&1["tmdbId"]) == to_string(tmdb_id))) do
          nil -> :not_found
          series -> {:ok, series}
        end

      _ ->
        :error
    end
  end

  defp all_series do
    Aviary.Cache.swr(:sonarr_series_list, @series_fresh_ms, @series_stale_ms, fn ->
      case get("/series", []) do
        {:ok, list} when is_list(list) -> {:ok, list}
        _ -> :error
      end
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      :error ->
        Aviary.Cache.invalidate(:sonarr_series_list)
        :error
    end
  end

  def lookup(tmdb_id) do
    case get("/series/lookup", term: "tmdb:#{tmdb_id}") do
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> :not_found
      _ -> :error
    end
  end

  def add_series(lookup_result, opts) do
    monitor = Keyword.get(opts, :monitor, @behaviour_default_monitor)
    search? = Keyword.get(opts, :search, monitor == "all")

    body =
      lookup_result
      |> Map.put("qualityProfileId", @behaviour_default_quality_profile)
      |> Map.put("rootFolderPath", @behaviour_default_root_folder)
      |> Map.put("seasonFolder", true)
      |> Map.put("monitored", monitor != "none")
      |> Map.put("addOptions", %{
        "monitor" => monitor,
        "searchForMissingEpisodes" => search?,
        "searchForCutoffUnmetEpisodes" => false
      })

    case post("/series", body) do
      {:ok, series} ->
        # New series isn't in the cached /series list — invalidate
        # so the next find_series_by_tmdb sees the addition.
        Aviary.Cache.invalidate(:sonarr_series_list)
        {:ok, series}

      _ ->
        :error
    end
  end

  ## Internals

  # Fires a single-episode EpisodeSearch for every aired, monitored,
  # fileless episode in (optionally) a specific season, in (season,
  # episode) order so the earliest episode is queued first. One
  # POST per episode is deliberate — bundling all ids into a single
  # EpisodeSearch (or relying on SeriesSearch / SeasonSearch) makes
  # Sonarr issue a single season-level indexer query whose paginated
  # response is dominated by popular episodes; quieter older episodes
  # get nothing. Per-episode searches guarantee each gets its own
  # indexer-query result depth.
  defp search_each_missing(sonarr_series_id) do
    today = Aviary.LocalTime.today()

    sonarr_series_id
    |> wait_for_episodes()
    |> Enum.filter(fn ep ->
      ep["monitored"] == true and
        ep["hasFile"] != true and
        aired?(ep, today)
    end)
    |> Enum.sort_by(fn ep -> {ep["seasonNumber"], ep["episodeNumber"]} end)
    |> Enum.each(fn ep ->
      command("EpisodeSearch", %{episodeIds: [ep["id"]]})
    end)
  end

  # Sonarr's POST /series returns BEFORE RefreshEpisodeService
  # populates the episode list. If we call /episode in that gap we get
  # [] back and would silently fire zero searches — that's what left
  # Silo stuck on "Searching" with no qBit handoff on a fresh add.
  # Poll /episode until it returns something or we've waited long
  # enough. Sonarr's refresh typically finishes in ~1s; the cap at 30s
  # is for badly-degraded states (cold Sonarr, slow metadata source).
  defp wait_for_episodes(sonarr_series_id, attempts \\ 60) do
    case list_episodes(sonarr_series_id) do
      [] when attempts > 0 ->
        Process.sleep(500)
        wait_for_episodes(sonarr_series_id, attempts - 1)

      result ->
        result
    end
  end

  defp aired?(%{"airDate" => air}, today) when is_binary(air) and air != "" do
    case Date.from_iso8601(air) do
      {:ok, date} -> Date.compare(date, today) != :gt
      _ -> false
    end
  end

  defp aired?(_, _), do: false

  defp ensure_series(tmdb_id, opts) do
    case find_series_by_tmdb(tmdb_id) do
      {:ok, series} ->
        # Widen monitoring if the caller is asking for more than what's
        # currently set. Never narrows.
        if Keyword.get(opts, :monitor) == "all" do
          if series["monitored"] != true do
            update_series_monitoring(series["id"], true)
          end

          # Critical: also flip every episode's monitored flag.
          # update_series_monitoring only sets the SERIES-level flag.
          # Without this, an existing series added via watch_episode
          # (which sets monitor=none and then monitors only the one
          # episode) stays mostly-unmonitored after a watch_show
          # widen — and search_each_missing's `ep["monitored"] == true`
          # filter matches only that one already-imported episode, so
          # zero new searches fire. Net symptom: the followup says
          # "broadening to series" in the log, but nothing actually
          # downloads. Listing episodes + bulk-monitoring the
          # unmonitored ones closes the gap.
          unmonitored_ids =
            series["id"]
            |> list_episodes()
            |> Enum.reject(&(&1["monitored"] == true))
            |> Enum.map(& &1["id"])

          if unmonitored_ids != [] do
            monitor_episodes(unmonitored_ids, true)
          end
        end

        {:ok, series}

      :not_found ->
        with {:ok, looked_up} <- lookup(tmdb_id) do
          add_series(looked_up, opts)
        end

      :error ->
        :error
    end
  end

  defp update_series_monitoring(sonarr_series_id, monitored?) do
    case get("/series/#{sonarr_series_id}", []) do
      {:ok, series} ->
        put("/series/#{sonarr_series_id}", Map.put(series, "monitored", monitored?))

      _ ->
        :error
    end
  end

  defp find_episode(sonarr_series_id, season, episode) do
    case list_episodes(sonarr_series_id) do
      [] ->
        :not_found

      list ->
        case Enum.find(list, &(&1["seasonNumber"] == season and &1["episodeNumber"] == episode)) do
          nil -> :not_found
          ep -> {:ok, ep}
        end
    end
  end

  defp list_episodes(sonarr_series_id) do
    case get("/episode", seriesId: sonarr_series_id) do
      {:ok, eps} when is_list(eps) -> eps
      _ -> []
    end
  end

  defp list_queue_for_series(sonarr_series_id) do
    case get("/queue", seriesId: sonarr_series_id, pageSize: 100, includeEpisode: true) do
      {:ok, %{"records" => records}} when is_list(records) -> records
      _ -> []
    end
  end

  defp monitor_episodes(episode_ids, monitored?) do
    case put("/episode/monitor", %{"episodeIds" => episode_ids, "monitored" => monitored?}) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  # Sonarr's POST /command returns the queued command record with its
  # id, status (queued/started/completed), and any exception. We log
  # the full response (success or failure) because Sonarr's own
  # /command list buffer ages out fast and there's no second chance
  # to find out what happened to a command after the fact. A
  # silently-failed search command is exactly what left Widow's Bay
  # S01E02-E07 ungrabbed for weeks — no audit trail without this.
  defp command(name, params) do
    require Logger
    body = Map.put(params, :name, name)

    case post("/command", body) do
      {:ok, response} ->
        Logger.info(
          "sonarr_command ok name=#{name} body=#{inspect(body)} response=#{inspect(Map.take(response || %{}, ["id", "name", "status", "queued", "started", "ended", "exception"]))}"
        )

        {:ok, response}

      :error ->
        Logger.warning("sonarr_command failed name=#{name} body=#{inspect(body)}")
        :error
    end
  end

  @doc """
  Tells the caller whether every successful download for this series
  came from a Usenet client (SAB) — i.e., deleting the on-disk files
  won't break a torrent seed. If ANY history record shows an import
  via a torrent client (qBittorrent, Transmission, Deluge,
  rTorrent), returns false → don't auto-delete.

  False on Sonarr unreachability too: failing open here would risk
  deleting things we shouldn't, so the auto-delete scheduler defers
  the work until the next cycle when Sonarr is back.
  """
  def all_imports_were_usenet?(sonarr_series_id) do
    case get("/history",
           seriesId: sonarr_series_id,
           eventType: "downloadFolderImported",
           pageSize: 1000
         ) do
      {:ok, %{"records" => records}} when is_list(records) ->
        Enum.all?(records, fn r ->
          client = get_in(r, ["data", "downloadClient"]) || ""
          not torrent_client?(client)
        end)

      _ ->
        false
    end
  end

  @doc """
  Removes the series from Sonarr and deletes the on-disk files.
  `addImportListExclusion: false` so a future re-add doesn't require
  manual override — re-adding via aviary should just work and trigger
  fresh searches.
  """
  def delete_series(sonarr_series_id) do
    case delete("/series/#{sonarr_series_id}",
           deleteFiles: true,
           addImportListExclusion: false
         ) do
      {:ok, _} ->
        # Newly-deleted series is no longer in the cached /series list;
        # next find_series_by_tmdb should miss + re-fetch.
        Aviary.Cache.invalidate(:sonarr_series_list)
        :ok

      _ ->
        :error
    end
  end

  defp torrent_client?(name) when is_binary(name) do
    lower = String.downcase(name)

    String.contains?(lower, "qbit") or
      String.contains?(lower, "transmission") or
      String.contains?(lower, "deluge") or
      String.contains?(lower, "rtorrent")
  end

  defp torrent_client?(_), do: false

  ## HTTP helpers

  defp get(path, params) do
    request(:get, path, params, nil)
  end

  defp post(path, body) do
    request(:post, path, [], body)
  end

  defp put(path, body) do
    request(:put, path, [], body)
  end

  defp delete(path, params) do
    request(:delete, path, params, nil)
  end

  defp request(method, path, params, body) do
    require Logger

    with key when not is_nil(key) <- api_key(),
         url = base_url() <> "/api/v3" <> path do
      opts = [
        headers: [{"x-api-key", key}],
        receive_timeout: 10_000,
        retry: false,
        params: params
      ]

      opts = if body, do: Keyword.put(opts, :json, body), else: opts

      case Req.request([method: method, url: url] ++ opts) do
        {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %Req.Response{status: status, body: response_body}} ->
          Logger.warning(
            "sonarr_http non-2xx method=#{method} path=#{path} status=#{status} response=#{inspect(response_body) |> String.slice(0, 400)}"
          )

          :error

        {:error, exc} ->
          Logger.warning(
            "sonarr_http transport error method=#{method} path=#{path} error=#{inspect(exc) |> String.slice(0, 400)}"
          )

          :error
      end
    else
      _ ->
        Logger.warning("sonarr_http missing config (api_key or base_url)")
        :error
    end
  rescue
    e ->
      Logger.warning(
        "sonarr_http raised method=#{method} path=#{path} error=#{inspect(e) |> String.slice(0, 400)}"
      )

      :error
  end

  defp base_url do
    case Application.get_env(:aviary, :sonarr_url) do
      nil -> nil
      "" -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp api_key do
    case Application.get_env(:aviary, :sonarr_api_key) do
      nil -> nil
      "" -> nil
      key -> key
    end
  end
end
