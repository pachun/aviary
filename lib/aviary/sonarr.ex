defmodule Aviary.Sonarr do
  @moduledoc """
  Thin wrapper over Sonarr's v3 API. Three things drive everything
  aviary asks of it:

    * **Add intent** — `watch_show/1`, `watch_season/2`,
      `watch_episode/3` translate the three button tiers into Sonarr
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
  "Watch the whole show" — adds the series with monitor=all, ensures
  S1 E1 is searched first (so the user can start watching ASAP), then
  fires a SeriesSearch for the rest. Without the explicit E1 search,
  Sonarr's per-indexer responses dictate queue order; the user would
  see E8 finish before E1 just because that release happened to be
  cached at the indexer.

  When the series already exists in Sonarr, widens monitoring + does
  the same dual search.
  """
  def watch_show(tmdb_id) do
    with {:ok, series} <- ensure_series(tmdb_id, monitor: "all", search: false) do
      prioritize_first_episode(series["id"])
      command("SeriesSearch", %{seriesId: series["id"]})
      {:ok, series}
    end
  end

  @doc """
  "Watch a specific season" — ensures the series exists (added with
  monitor=none so we don't auto-search the whole library), sets the
  target season + future seasons to monitored, then fires a
  SeasonSearch for that season. Future seasons get picked up
  automatically as they air.
  """
  def watch_season(tmdb_id, season_number) when is_integer(season_number) do
    with {:ok, series} <- ensure_series(tmdb_id, monitor: "none"),
         :ok <- monitor_seasons_from(series["id"], season_number) do
      prioritize_first_episode(series["id"], season_number)
      command("SeasonSearch", %{seriesId: series["id"], seasonNumber: season_number})
      {:ok, series}
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

  def find_series_by_tmdb(tmdb_id) do
    case get("/series", []) do
      {:ok, all} when is_list(all) ->
        case Enum.find(all, &(to_string(&1["tmdbId"]) == to_string(tmdb_id))) do
          nil -> :not_found
          series -> {:ok, series}
        end

      _ ->
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
      {:ok, series} -> {:ok, series}
      _ -> :error
    end
  end

  ## Internals

  # Fires a single EpisodeSearch for the first episode of the given
  # scope (whole show ⇒ S1 E1; season ⇒ S<n> E1) BEFORE the broader
  # SeriesSearch/SeasonSearch runs, so the user's "first thing to
  # watch" is the first thing Sonarr finds a release for. Skipped
  # when the episode already has a file (re-clicks are idempotent
  # AND don't waste an indexer query).
  defp prioritize_first_episode(sonarr_series_id, season_number \\ 1) do
    case find_episode(sonarr_series_id, season_number, 1) do
      {:ok, %{"hasFile" => true}} ->
        :ok

      {:ok, ep} ->
        command("EpisodeSearch", %{episodeIds: [ep["id"]]})
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_series(tmdb_id, opts) do
    case find_series_by_tmdb(tmdb_id) do
      {:ok, series} ->
        # Widen monitoring if the caller is asking for more than what's
        # currently set. Never narrows.
        if Keyword.get(opts, :monitor) == "all" and series["monitored"] != true do
          update_series_monitoring(series["id"], true)
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

  defp monitor_seasons_from(sonarr_series_id, from_season) do
    case get("/series/#{sonarr_series_id}", []) do
      {:ok, series} ->
        updated_seasons =
          Enum.map(series["seasons"] || [], fn s ->
            if s["seasonNumber"] >= from_season,
              do: Map.put(s, "monitored", true),
              else: s
          end)

        updated = Map.put(series, "seasons", updated_seasons) |> Map.put("monitored", true)

        case put("/series/#{sonarr_series_id}", updated) do
          {:ok, _} -> :ok
          _ -> :error
        end

      _ ->
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

  defp command(name, params) do
    post("/command", Map.put(params, :name, name))
  end

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

  defp request(method, path, params, body) do
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

        _ ->
          :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
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
