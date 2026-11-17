defmodule Aviary.Reconcile do
  @moduledoc """
  Catches up missed grabs by asking Sonarr for everything that's
  monitored + aired + without a file, then re-firing `EpisodeSearch`
  per episode.

  Why this exists: Sonarr's `On Grab` decision can succeed at the
  release-search step and then silently fail at the hand-off-to-qBit
  step (most commonly because qBittorrent's container restarted and
  Sonarr cached the connection failure). Sonarr does not auto-retry
  those one-shot failures, so we do — driven by webhooks Sonarr posts
  when health is restored, but also safe to invoke directly for ad-
  hoc catch-up.

  Also clears the states an *arr will sit in forever on its own: a
  completed download it refuses to import, and a release it grabbed for
  a protocol it has no download client for. `sweep_stuck_downloads/0`
  does only that part, cheaply enough to run every few minutes.

  Throttled so a flurry of events (qBit flapping, multiple health
  issues clearing in sequence) doesn't pile up dozens of identical
  re-searches against the indexer. One reconcile per minute is plenty
  — Sonarr's own search machinery batches the per-episode commands
  into its command queue.
  """
  require Logger

  @throttle_ms 60_000
  @throttle_key :aviary_reconcile

  # A download client that blipped during the hand-off is usually back
  # within a minute or two, and Radarr picks the grab up on its own. Only
  # step in once it clearly hasn't.
  @orphan_grace_seconds 900

  # An import the *arr has flagged never un-flags itself, but give a
  # download that only just finished a few minutes before giving up on
  # it, so a post-processing step still settling isn't mistaken for a
  # bad file.
  @stuck_grace_seconds 300

  @hevc_custom_format "Codec: HEVC / x265"
  @multiple_audio_custom_format "Multi / Dual Audio"
  @tolerated_custom_formats [@hevc_custom_format, @multiple_audio_custom_format]
  @watchable_resolutions [720, 1080]
  @unknown_resolution 0
  @no_releases_grabbed 0

  @doc """
  Runs the reconcile pass. Returns `:ok` if it actually ran, or
  `:throttled` if the previous run was within the throttle window
  (no work done, no error).
  """
  def run do
    case Aviary.Cache.fetch(@throttle_key, @throttle_ms, fn ->
           do_run()
           :stamped
         end) do
      :stamped -> :ok
      _ -> :throttled
    end
  end

  defp do_run do
    sweep_stuck_downloads()
    refire_missing_searches()
  end

  @doc """
  Clears every download Sonarr or Radarr has stopped making progress
  on: finished downloads they won't import, and grabs parked for a
  download client Radarr doesn't have.
  """
  def sweep_stuck_downloads do
    clear_stuck_sonarr_downloads()
    clear_stuck_radarr_downloads()
    clear_orphaned_grabs()
    :ok
  end

  # Radarr will happily accept a grab for a protocol it has no download
  # client for. The release parks in the queue as
  # `downloadClientUnavailable` at 0% and stays there: nothing retries
  # it, and no health check fires, because Radarr counts itself healthy
  # as long as *some* client is enabled. Re-drive the ones a client
  # could now take, and say so about the ones it can't — re-searching
  # those would only grab into the same void.
  defp clear_orphaned_grabs do
    with {:ok, %{"records" => records}} when is_list(records) <-
           Aviary.Radarr.queue(pageSize: 100),
         {:ok, protocols} <- Aviary.Radarr.enabled_download_protocols() do
      {recoverable, stranded} =
        records
        |> Enum.filter(&orphaned_grab?/1)
        |> Enum.split_with(&MapSet.member?(protocols, &1["protocol"]))

      Enum.each(stranded, fn record ->
        Logger.warning(
          "reconcile: #{describe(record)} was grabbed as #{record["protocol"]} but no #{record["protocol"]} download client is enabled — leaving it parked"
        )
      end)

      if recoverable != [] do
        Logger.info("reconcile: re-driving #{length(recoverable)} orphaned grab(s)")
      end

      Enum.each(recoverable, fn record ->
        with :ok <- Aviary.Radarr.remove_from_queue(record["id"]),
             movie_id when is_integer(movie_id) <- record["movieId"] do
          Logger.info("reconcile: re-searching #{describe(record)}")
          Aviary.Radarr.movie_search([movie_id])
        end
      end)

      :ok
    else
      _ -> :error
    end
  end

  defp orphaned_grab?(record) do
    record["status"] == "downloadClientUnavailable" and
      settled?(record["added"], @orphan_grace_seconds)
  end

  defp settled?(added, grace_seconds) when is_binary(added) do
    case DateTime.from_iso8601(added) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at) >= grace_seconds
      _ -> false
    end
  end

  defp settled?(_, _), do: false

  defp describe(record) do
    get_in(record, ["movie", "title"]) || record["title"] || "queue record #{record["id"]}"
  end

  # A finished download the *arr has flagged is one of three things,
  # and each has one right move:
  #
  #   * the episode (or movie) already has a file from another release
  #     — the download is redundant; drop it;
  #   * the files parse cleanly but the *arr only trusts the grab
  #     history to say which series/movie they belong to — the files
  #     are fine, so import them ourselves;
  #   * anything else (a zero-filled "video", a release whose file is a
  #     different episode, a mismatched quality) — give up on this
  #     release, blocklist it so it isn't grabbed yet again, and let
  #     the *arr grab the next one.
  #
  # Left alone, every one of these sits at 100%-downloaded forever and
  # shows as "stuck" in aviary and perch; the third kind also gets
  # re-grabbed, since nothing ever told the *arr the release was bad.
  defp clear_stuck_sonarr_downloads do
    case Aviary.Sonarr.queue(pageSize: 300) do
      {:ok, %{"records" => records}} when is_list(records) ->
        download_counts = Enum.frequencies(Enum.map(records, & &1["downloadId"]))
        stuck = Enum.filter(records, &stuck?/1)
        {redundant, unimported} = Enum.split_with(stuck, &episode_already_imported?/1)
        {matched_by_id, hopeless} = Enum.split_with(unimported, &matched_by_id_only?/1)

        # Only drop a download when it is solely for that one episode,
        # so we never delete one another still-missing episode rides on.
        redundant
        |> Enum.filter(fn r -> download_counts[r["downloadId"]] == 1 end)
        |> Enum.each(fn r ->
          Logger.info("reconcile: dropping #{describe(r)}: its episode already has a file")
          Aviary.Sonarr.remove_from_queue(r["id"])
        end)

        matched_by_id
        |> Enum.uniq_by(& &1["downloadId"])
        |> Enum.each(fn r ->
          case force_sonarr_import(r["downloadId"]) do
            :imported -> :ok
            :nothing_clean -> give_up_on(:sonarr, r)
          end
        end)

        hopeless
        |> Enum.uniq_by(& &1["downloadId"])
        |> Enum.each(&give_up_on(:sonarr, &1))

        :ok

      _ ->
        :error
    end
  end

  defp clear_stuck_radarr_downloads do
    case Aviary.Radarr.queue(pageSize: 100) do
      {:ok, %{"records" => records}} when is_list(records) ->
        stuck = Enum.filter(records, &stuck?/1)
        {redundant, unimported} = Enum.split_with(stuck, &movie_already_imported?/1)
        {matched_by_id, hopeless} = Enum.split_with(unimported, &matched_by_id_only?/1)

        Enum.each(redundant, fn r ->
          Logger.info("reconcile: dropping #{describe(r)}: the movie already has a file")
          Aviary.Radarr.remove_from_queue_and_client(r["id"])
        end)

        matched_by_id
        |> Enum.uniq_by(& &1["downloadId"])
        |> Enum.each(fn r ->
          case force_radarr_import(r["downloadId"]) do
            :imported -> :ok
            :nothing_clean -> give_up_on(:radarr, r)
          end
        end)

        hopeless
        |> Enum.uniq_by(& &1["downloadId"])
        |> Enum.each(&give_up_on(:radarr, &1))

        :ok

      _ ->
        :error
    end
  end

  # Finished downloading, flagged, and been that way long enough. A
  # warning on a download still in flight ("stalled with no
  # connections") is not stuck, just slow, and never qualifies.
  defp stuck?(record) do
    record["status"] == "completed" and
      (record["trackedDownloadState"] == "importBlocked" or
         (record["trackedDownloadStatus"] == "warning" and status_messages(record) != [])) and
      settled?(record["added"], @stuck_grace_seconds)
  end

  defp status_messages(record) do
    Enum.flat_map(record["statusMessages"] || [], fn m -> m["messages"] || [] end)
  end

  defp matched_by_id_only?(record) do
    Enum.any?(status_messages(record), &String.contains?(&1, "by ID"))
  end

  defp episode_already_imported?(record) do
    record["episodeHasFile"] == true or match?(%{"hasFile" => true}, record["episode"])
  end

  defp movie_already_imported?(record) do
    match?(%{"hasFile" => true}, record["movie"])
  end

  defp give_up_on(arr, record) do
    reasons = Enum.join(status_messages(record), "; ")

    Logger.info(
      "reconcile: giving up on #{describe(record)} (#{reasons}): blocklisting it and searching again"
    )

    case arr do
      :sonarr -> Aviary.Sonarr.mark_download_failed(record["id"])
      :radarr -> Aviary.Radarr.mark_download_failed(record["id"])
    end
  end

  defp force_sonarr_import(download_id) do
    with {:ok, candidates} <- Aviary.Sonarr.manual_import_candidates(download_id) do
      files =
        candidates
        |> Enum.filter(&importable_episode_file?/1)
        |> Enum.map(&to_sonarr_import_file(&1, download_id))

      case files do
        [] ->
          :nothing_clean

        _ ->
          Logger.info("reconcile: force-importing #{download_id} (#{length(files)} file(s))")
          Aviary.Sonarr.manual_import(files)
          :imported
      end
    end
  end

  defp importable_episode_file?(file) do
    (file["rejections"] || []) == [] and is_map(file["series"]) and
      file["series"]["id"] != nil and is_list(file["episodes"]) and file["episodes"] != []
  end

  defp to_sonarr_import_file(file, download_id) do
    %{
      id: file["id"],
      path: file["path"],
      folderName: file["folderName"],
      seriesId: file["series"]["id"],
      episodeIds: Enum.map(file["episodes"], & &1["id"]),
      quality: file["quality"],
      languages: file["languages"],
      releaseGroup: file["releaseGroup"],
      downloadId: file["downloadId"] || download_id
    }
  end

  defp force_radarr_import(download_id) do
    with {:ok, candidates} <- Aviary.Radarr.manual_import_candidates(download_id) do
      files =
        candidates
        |> Enum.filter(&importable_movie_file?/1)
        |> Enum.map(&to_radarr_import_file(&1, download_id))

      case files do
        [] ->
          :nothing_clean

        _ ->
          Logger.info("reconcile: force-importing #{download_id} (#{length(files)} file(s))")
          Aviary.Radarr.manual_import(files)
          :imported
      end
    end
  end

  defp importable_movie_file?(file) do
    (file["rejections"] || []) == [] and is_map(file["movie"]) and file["movie"]["id"] != nil
  end

  defp to_radarr_import_file(file, download_id) do
    %{
      id: file["id"],
      path: file["path"],
      folderName: file["folderName"],
      movieId: file["movie"]["id"],
      quality: file["quality"],
      languages: file["languages"],
      releaseGroup: file["releaseGroup"],
      downloadId: file["downloadId"] || download_id
    }
  end

  @doc """
  Grabs a release Sonarr's quality profile rejects for each episode
  whose every accepted release has already failed to download, so the
  episode is watchable instead of "Searching" forever. Sonarr still
  upgrades it once a release the profile accepts turns up.

  Returns how many releases it grabbed.
  """
  def grab_last_resort_releases do
    with {:ok, failed_downloads} <- Aviary.Sonarr.failed_downloads(),
         {:ok, %{"records" => queue}} when is_list(queue) <- Aviary.Sonarr.queue(pageSize: 300) do
      queued_episode_ids = MapSet.new(queue, & &1["episodeId"])

      failed_downloads
      |> Enum.map(& &1["episode"])
      |> Enum.filter(&still_wanted?/1)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.reject(&MapSet.member?(queued_episode_ids, &1["id"]))
      |> Enum.count(&grab_last_resort_release/1)
    else
      _ -> @no_releases_grabbed
    end
  end

  defp still_wanted?(%{"monitored" => true, "hasFile" => false}), do: true
  defp still_wanted?(_), do: false

  defp grab_last_resort_release(episode) do
    with {:ok, releases} <- Aviary.Sonarr.releases(episode["id"]),
         false <- Enum.any?(releases, &sonarr_will_grab?/1),
         [best | _] <-
           releases |> Enum.filter(&last_resort?/1) |> Enum.sort_by(&last_resort_rank/1),
         :ok <- Aviary.Sonarr.grab_release(best) do
      Logger.info(
        "reconcile: every accepted release of episode #{episode["id"]} failed; grabbed #{best["title"]} as a last resort (Sonarr rejected it for: #{Enum.join(best["rejections"], "; ")})"
      )

      true
    else
      _ -> false
    end
  end

  defp sonarr_will_grab?(release) do
    release["approved"] == true or release["temporarilyRejected"] == true
  end

  defp last_resort?(release) do
    rejections = release["rejections"] || []

    release["downloadAllowed"] == true and rejections != [] and
      Enum.all?(rejections, &rejected_only_by_preference?/1) and
      Enum.all?(custom_format_names(release), &(&1 in @tolerated_custom_formats)) and
      resolution(release) in @watchable_resolutions and
      Enum.any?(release["languages"] || [], &(&1["name"] == "English"))
  end

  defp rejected_only_by_preference?(rejection) when is_binary(rejection) do
    String.starts_with?(rejection, "Custom Formats ") or
      String.ends_with?(rejection, "is not wanted in profile")
  end

  defp rejected_only_by_preference?(_), do: false

  defp last_resort_rank(release) do
    formats = custom_format_names(release)

    {@hevc_custom_format in formats, -resolution(release),
     @multiple_audio_custom_format in formats, -(release["size"] || 0)}
  end

  defp custom_format_names(release) do
    Enum.map(release["customFormats"] || [], & &1["name"])
  end

  defp resolution(release) do
    get_in(release, ["quality", "quality", "resolution"]) || @unknown_resolution
  end

  defp refire_missing_searches do
    queued_episode_ids = fetch_queued_episode_ids()

    case fetch_missing() do
      {:ok, episodes} ->
        # Skip episodes that are already in flight in Sonarr's queue
        # — they're not stuck, they're just downloading. Re-firing
        # EpisodeSearch on a queued episode makes Sonarr go looking
        # for an upgrade, which we don't want here.
        actionable =
          Enum.reject(episodes, &MapSet.member?(queued_episode_ids, &1["id"]))

        ids = Enum.map(actionable, & &1["id"])

        Logger.info(
          "reconcile: #{length(episodes)} missing total, #{MapSet.size(queued_episode_ids)} in queue, re-firing EpisodeSearch for #{length(ids)}: #{inspect(ids |> Enum.take(20))}#{if length(ids) > 20, do: " ...", else: ""}"
        )

        # Per-episode EpisodeSearch (single-id list each). Same shape
        # as Aviary.Sonarr.watch_show's search_each_missing path, for
        # the same reason: a batched multi-id EpisodeSearch makes
        # Sonarr issue one season-level indexer query whose paginated
        # results are dominated by the most-popular episodes, leaving
        # quieter older missing episodes unfound. Per-episode forces
        # per-episode indexer queries.
        Enum.each(actionable, fn ep ->
          Aviary.Sonarr.episode_search([ep["id"]])
        end)

        :ok

      :error ->
        Logger.warning("reconcile: failed to fetch /wanted/missing from Sonarr")
        :error
    end
  end

  defp fetch_queued_episode_ids do
    case Aviary.Sonarr.queue(pageSize: 200) do
      {:ok, %{"records" => records}} when is_list(records) ->
        records
        |> Enum.map(& &1["episodeId"])
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # Walks Sonarr's /wanted/missing paginated endpoint. We only care
  # about episodes that have aired (Sonarr's filter is already
  # "missing", which by default means `monitored=true` and
  # `hasFile=false`; the `monitored=true` default keeps the result
  # set sane).
  defp fetch_missing(page \\ 1, acc \\ []) do
    case Aviary.Sonarr.wanted_missing(page: page, pageSize: 100) do
      {:ok, %{"records" => records, "totalRecords" => total}} when is_list(records) ->
        new_acc = acc ++ records

        if length(new_acc) >= total or records == [] do
          today = Date.utc_today()

          aired_only =
            Enum.filter(new_acc, fn r ->
              case r["airDateUtc"] || r["airDate"] do
                d when is_binary(d) and d != "" ->
                  case Date.from_iso8601(String.slice(d, 0, 10)) do
                    {:ok, date} -> Date.compare(date, today) != :gt
                    _ -> false
                  end

                _ ->
                  false
              end
            end)

          {:ok, aired_only}
        else
          fetch_missing(page + 1, new_acc)
        end

      _ ->
        :error
    end
  end
end
