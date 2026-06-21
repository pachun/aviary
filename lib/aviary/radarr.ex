defmodule Aviary.Radarr do
  require Logger

  @moduledoc """
  Thin wrapper over Radarr's v3 API — the movie-side counterpart to
  `Aviary.Sonarr`. Simpler than Sonarr because a movie is a single
  unit with no season/episode tiers: one Watch button, one progress
  chip, one Play button when it lands.

  Two things drive everything aviary asks of it:

    * **Add intent** — `watch_movie/1` is "ensure movie exists in
      Radarr, monitor it, kick a search now." Idempotent: re-running
      against a movie already present widens nothing (a movie's only
      monitor state is on/off) but re-fires the search so a
      transient grab failure can be retried by the user clicking
      Watch again.

    * **Status query** — `movie_status/1` returns the current
      monitoring + has-file + active-download record for a single
      movie given its TMDB id. This is what `MoviesDetailLive`
      polls every few seconds to decide what state the button
      should render in.

  Both are keyed on TMDB id externally — Radarr's preferred id is
  also TMDB id (unlike Sonarr which prefers TVDB internally), so the
  bridging dance is simpler here.
  """

  @behaviour_default_quality_profile 4
  @behaviour_default_root_folder "/movies"

  @doc """
  "Watch this movie" — adds the movie monitored, immediately
  searching for a release. Idempotent for already-present movies:
  re-fires the search so a transient grab failure can be retried by
  the user simply clicking Watch again.
  """
  def watch_movie(tmdb_id) do
    case find_movie_by_tmdb(tmdb_id) do
      {:ok, movie} ->
        # Already in Radarr — re-kick a search. MovieSearch doesn't
        # have the per-episode-result-page issue Sonarr's SeriesSearch
        # has; one movie = one indexer query, the top hits ARE the
        # movie's releases. Safe to fire here.
        command("MoviesSearch", %{movieIds: [movie["id"]]})
        {:ok, movie}

      :not_found ->
        case lookup(tmdb_id) do
          {:ok, looked_up} -> add_movie(looked_up)
          other -> other
        end

      :error ->
        :error
    end
  end

  @doc """
  Forces Radarr to re-query qBittorrent for download progress right
  now — same staleness pattern as Sonarr's
  `refresh_monitored_downloads/0`. Polled from the movie detail page
  while a download is in flight so the progress chip updates within
  a few seconds rather than 90.
  """
  def refresh_monitored_downloads do
    command("RefreshMonitoredDownloads", %{})
  end

  @doc """
  Returns a `%{radarr_movie_id, monitored, has_file, path, queue}`
  snapshot for a single movie, keyed by TMDB id. Returns `:not_found`
  when the movie isn't in Radarr — callers treat that as "user
  hasn't pressed Watch yet."
  """
  def movie_status(tmdb_id) do
    case find_movie_by_tmdb(tmdb_id) do
      {:ok, movie} ->
        queue = list_queue_for_movie(movie["id"])

        {:ok,
         %{
           radarr_movie_id: movie["id"],
           # Radarr knows the on-disk folder for the movie; surface it
           # so the detail page can tell Jellyfin "scan this specific
           # path now" via /Library/Media/Updated once the file lands,
           # instead of waiting on Jellyfin's scheduled scan.
           path: movie["path"],
           monitored: movie["monitored"] == true,
           has_file: movie["hasFile"] == true,
           queue: queue
         }}

      :not_found ->
        :not_found

      :error ->
        :error
    end
  end

  ## Building blocks (public so tests / future reconcile can reuse them)

  # Cache the Radarr-wide /movie list — same SWR rationale as Sonarr's
  # series-list cache. The detail page polls every few seconds; without
  # this cache each poll walks the full library.
  @movie_fresh_ms 15_000
  @movie_stale_ms 60_000

  def find_movie_by_tmdb(tmdb_id) do
    case all_movies() do
      {:ok, all} ->
        case Enum.find(all, &(to_string(&1["tmdbId"]) == to_string(tmdb_id))) do
          nil -> :not_found
          movie -> {:ok, movie}
        end

      _ ->
        :error
    end
  end

  defp all_movies do
    Aviary.Cache.swr(:radarr_movie_list, @movie_fresh_ms, @movie_stale_ms, fn ->
      case get("/movie", []) do
        {:ok, list} when is_list(list) -> {:ok, list}
        _ -> :error
      end
    end)
    |> case do
      {:ok, _} = ok ->
        ok

      :error ->
        Aviary.Cache.invalidate(:radarr_movie_list)
        :error
    end
  end

  def lookup(tmdb_id) do
    case get("/movie/lookup/tmdb", tmdbId: tmdb_id) do
      {:ok, %{} = movie} -> {:ok, movie}
      {:ok, [first | _]} -> {:ok, first}
      {:ok, []} -> :not_found
      _ -> :error
    end
  end

  def add_movie(lookup_result) do
    body =
      lookup_result
      |> Map.put("qualityProfileId", @behaviour_default_quality_profile)
      |> Map.put("rootFolderPath", @behaviour_default_root_folder)
      |> Map.put("monitored", true)
      |> Map.put("addOptions", %{
        "monitor" => "movieOnly",
        "searchForMovie" => true
      })

    case post("/movie", body) do
      {:ok, movie} ->
        # New movie isn't in the cached /movie list — invalidate so
        # the next find_movie_by_tmdb sees the addition without
        # waiting for the SWR refresh window.
        Aviary.Cache.invalidate(:radarr_movie_list)
        {:ok, movie}

      _ ->
        :error
    end
  end

  ## Internals

  # Radarr's /queue includes movieId on each record; we filter
  # client-side rather than hitting the per-movie variant because
  # /queue?movieId=… isn't documented as supported across versions and
  # the queue list is small in practice.
  defp list_queue_for_movie(radarr_movie_id) do
    case get("/queue", pageSize: 100, includeMovie: false) do
      {:ok, %{"records" => records}} when is_list(records) ->
        Enum.find(records, &(&1["movieId"] == radarr_movie_id))

      _ ->
        nil
    end
  end

  # Same logging discipline as Sonarr.command — Radarr's /command list
  # buffer ages out fast, so this log is the audit trail for any
  # search/refresh we fired.
  defp command(name, params) do
    body = Map.put(params, :name, name)

    case post("/command", body) do
      {:ok, response} ->
        Logger.info(
          "radarr_command ok name=#{name} body=#{inspect(body)} response=#{inspect(Map.take(response || %{}, ["id", "name", "status", "queued", "started", "ended", "exception"]))}"
        )

        {:ok, response}

      :error ->
        Logger.warning("radarr_command failed name=#{name} body=#{inspect(body)}")
        :error
    end
  end

  @doc """
  True when every successful download for this movie came via Usenet
  (SAB). False (skip auto-delete) on any torrent-client import OR on
  Radarr unreachability — failing-open here would risk deleting files
  we shouldn't.
  """
  def all_imports_were_usenet?(radarr_movie_id) do
    case get("/history",
           movieId: radarr_movie_id,
           eventType: "downloadFolderImported",
           pageSize: 100
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
  Removes the movie from Radarr and deletes the on-disk file.
  `addImportExclusion: false` so a future re-add doesn't require
  manual override.
  """
  def delete_movie(radarr_movie_id) do
    case delete("/movie/#{radarr_movie_id}",
           deleteFiles: true,
           addImportExclusion: false
         ) do
      {:ok, _} ->
        Aviary.Cache.invalidate(:radarr_movie_list)
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

  ## HTTP helpers — same shape as Aviary.Sonarr; not worth a shared
  ## module yet.

  defp get(path, params), do: request(:get, path, params, nil)
  defp post(path, body), do: request(:post, path, [], body)
  defp delete(path, params), do: request(:delete, path, params, nil)

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

        {:ok, %Req.Response{status: status, body: response_body}} ->
          Logger.warning(
            "radarr_http non-2xx method=#{method} path=#{path} status=#{status} response=#{inspect(response_body) |> String.slice(0, 400)}"
          )

          :error

        {:error, exc} ->
          Logger.warning(
            "radarr_http transport error method=#{method} path=#{path} error=#{inspect(exc) |> String.slice(0, 400)}"
          )

          :error
      end
    else
      _ ->
        Logger.warning("radarr_http missing config (api_key or base_url)")
        :error
    end
  rescue
    e ->
      Logger.warning(
        "radarr_http raised method=#{method} path=#{path} error=#{inspect(e) |> String.slice(0, 400)}"
      )

      :error
  end

  defp base_url do
    case Application.get_env(:aviary, :radarr_url) do
      nil -> nil
      "" -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp api_key do
    case Application.get_env(:aviary, :radarr_api_key) do
      nil -> nil
      "" -> nil
      key -> key
    end
  end
end
