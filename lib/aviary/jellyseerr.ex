defmodule Aviary.Jellyseerr do
  @moduledoc """
  Thin wrapper over Jellyseerr's REST API. We use it as our TMDB proxy:
  per-show metadata (`get_tv/1`), per-season episode lists with future
  air dates (`get_tv_season/2`), and network-scoped discover lists
  (`discover_tv_network/2`, `discover_tv_premieres/2`). Jellyfin's
  metadata stops at "what's been released," so future-air-date intel
  comes through here.

  Auth is a single API key (not per-user) — these endpoints aren't
  user-scoped in any way we depend on, and the data is the same for
  every user. Keyed at the application env via `:jellyseerr_api_key`.

  Caching: all three public functions are cached via `Aviary.Cache`'s
  stale-while-revalidate. TMDB metadata barely moves within a day, so
  a 1h fresh / 24h stale window means the first page load eats the
  network round-trip and every subsequent load (within 24h) returns
  instantly. Only errors aren't cached — a transient failure shouldn't
  poison the cache.
  """

  alias Aviary.Cache

  @tv_fresh_ms 60 * 60 * 1_000
  @tv_stale_ms 24 * 60 * 60 * 1_000
  @discover_fresh_ms 5 * 60 * 1_000
  @discover_stale_ms 60 * 60 * 1_000

  @doc """
  Returns the raw Jellyseerr `/tv/{tmdbId}` response body, or `:error`.
  Exposed so `Aviary.Catalog.get_show/2` can build a full show detail
  for a TMDB id (a show not in the user's library yet, surfaced via
  Discover).
  """
  def get_tv(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    Cache.swr({:jellyseerr_get_tv, to_string(tmdb_id)}, @tv_fresh_ms, @tv_stale_ms, fn ->
      do_get_tv(tmdb_id)
    end)
    |> uncache_errors({:jellyseerr_get_tv, to_string(tmdb_id)})
  end

  def get_tv(_), do: :error

  defp do_get_tv(tmdb_id) do
    case api_key() do
      nil ->
        :error

      key ->
        url = base_url() <> "/api/v1/tv/#{tmdb_id}"

        case Req.get(url, request_options(key, [])) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  @doc """
  Returns Jellyseerr's `/movie/{tmdbId}` response body, or `:error`.
  Used by `Aviary.Catalog.get_movie/2` to build a full movie detail
  for a TMDB id (a movie surfaced via Search that isn't in the user's
  library — and which we therefore can't load from Jellyfin).
  """
  def get_movie(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    Cache.swr({:jellyseerr_get_movie, to_string(tmdb_id)}, @tv_fresh_ms, @tv_stale_ms, fn ->
      do_get_movie(tmdb_id)
    end)
    |> uncache_errors({:jellyseerr_get_movie, to_string(tmdb_id)})
  end

  def get_movie(_), do: :error

  defp do_get_movie(tmdb_id) do
    case api_key() do
      nil ->
        :error

      key ->
        url = base_url() <> "/api/v1/movie/#{tmdb_id}"

        case Req.get(url, request_options(key, [])) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  @doc """
  Returns Jellyseerr's per-season episode list for a show. Each
  episode entry has airDate, episodeNumber, name, etc. — enough to
  render the full episode list with aired/not-aired indicators on
  the show detail page, even for shows not yet in the user's library.
  """
  def get_tv_season(tmdb_id, season_number) do
    Cache.swr(
      {:jellyseerr_get_tv_season, to_string(tmdb_id), season_number},
      @tv_fresh_ms,
      @tv_stale_ms,
      fn -> do_get_tv_season(tmdb_id, season_number) end
    )
    |> uncache_errors({:jellyseerr_get_tv_season, to_string(tmdb_id), season_number})
  end

  defp do_get_tv_season(tmdb_id, season_number) do
    case api_key() do
      nil ->
        :error

      key ->
        url = base_url() <> "/api/v1/tv/#{tmdb_id}/season/#{season_number}"

        case Req.get(url, request_options(key, [])) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  @doc """
  Multi-search across TV + movies via Jellyseerr's `/search/multi`.
  Returns `{:ok, results}` where each result has `mediaType` ("tv" or
  "movie"; "person" results are filtered upstream), TMDB id, name/
  title, posterPath, backdropPath, and a mediaInfo block that carries
  the Jellyfin id when the item is already in the library — same
  shape the discover endpoints use, so search results flow through
  the same card render unchanged.

  Not SWR-cached: a typed query is a unique key and the user expects
  liveness as they refine. We still bound the request timeout so a
  slow Jellyseerr doesn't hang the LiveView.
  """
  def search(query) when is_binary(query) and query != "" do
    # Jellyseerr's `query` validator is strict RFC-3986: spaces MUST be
    # `%20`, apostrophes MUST be `%27`. Req's `params:` option form-
    # encodes (space → `+`), which Jellyseerr 400s with "must be url
    # encoded." Build the querystring by hand with `URI.encode/2` so
    # only unreserved chars stay raw.
    encoded_q = URI.encode(query, &URI.char_unreserved?/1)

    with key when not is_nil(key) <- api_key(),
         url = base_url() <> "/api/v1/search?query=#{encoded_q}&page=1",
         {:ok, %Req.Response{status: 200, body: %{"results" => results}}} <-
           Req.get(url,
             headers: [{"x-api-key", key}],
             receive_timeout: 5_000,
             retry: false
           ) do
      filtered =
        Enum.filter(results, &(&1["mediaType"] in ["tv", "movie"]))

      {:ok, filtered}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def search(_), do: {:ok, []}

  @doc """
  One page of TMDB's all-time popular shows for a network, as
  `{:ok, results}`. Each result has id (TMDB), name, popularity,
  posterPath, backdropPath, and a mediaInfo block carrying the
  Jellyfin id when the show is in the library.
  """
  def discover_tv_network(network_id, page \\ 1) do
    cached_discover(
      {:jellyseerr_discover_tv_network, network_id, page},
      "/api/v1/discover/tv/network/#{network_id}",
      page: page
    )
  end

  @doc """
  The shows that premiered on a network on or after `since`, most
  popular first, as `{:ok, results}` in the same shape as
  `discover_tv_network/2`.
  """
  def discover_tv_premieres(network_id, since) do
    cached_discover(
      {:jellyseerr_discover_tv_premieres, network_id, since},
      "/api/v1/discover/tv",
      network: network_id,
      firstAirDateGte: Date.to_iso8601(since),
      sortBy: "popularity.desc"
    )
  end

  defp cached_discover(cache_key, path, params) do
    Cache.swr(cache_key, @discover_fresh_ms, @discover_stale_ms, fn -> discover(path, params) end)
    |> uncache_errors(cache_key)
  end

  defp discover(path, params) do
    with key when not is_nil(key) <- api_key(),
         {:ok, %Req.Response{status: 200, body: %{"results" => results}}} <-
           Req.get(base_url() <> path, request_options(key, params: params)) do
      {:ok, results}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp request_options(key, options) do
    [headers: [{"x-api-key", key}], receive_timeout: 5_000, retry: false]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:aviary, :jellyseerr_req_options, []))
  end

  # Don't poison the cache with transient errors. If the wrapped
  # function returned :error, evict the entry so the NEXT call
  # retries instead of serving :error from cache for an hour.
  defp uncache_errors(:error, key) do
    Cache.invalidate(key)
    :error
  end

  defp uncache_errors(result, _key), do: result

  defp base_url do
    case Application.get_env(:aviary, :jellyseerr_url) do
      nil -> nil
      "" -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp api_key do
    case Application.get_env(:aviary, :jellyseerr_api_key) do
      nil -> nil
      "" -> nil
      key -> key
    end
  end
end
