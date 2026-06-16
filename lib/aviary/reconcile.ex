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

  Throttled so a flurry of events (qBit flapping, multiple health
  issues clearing in sequence) doesn't pile up dozens of identical
  re-searches against the indexer. One reconcile per minute is plenty
  — Sonarr's own search machinery batches the per-episode commands
  into its command queue.
  """
  require Logger

  @throttle_ms 60_000
  @throttle_key :aviary_reconcile

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
