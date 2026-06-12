defmodule Aviary.Jellyseerr do
  @moduledoc """
  Thin wrapper over Jellyseerr's REST API. We use it as our TMDB proxy:
  per-show metadata (`get_tv/1`), per-season episode lists with future
  air dates (`get_tv_season/2`), and network-scoped discover rows
  (`discover_tv_network/1`). Jellyfin's metadata stops at "what's been
  released," so future-air-date intel comes through here.

  Auth is a single API key (not per-user) — these endpoints aren't
  user-scoped in any way we depend on, and the data is the same for
  every user. Keyed at the application env via `:jellyseerr_api_key`.
  """

  @doc """
  Returns the raw Jellyseerr `/tv/{tmdbId}` response body, or `:error`.
  Exposed so `Aviary.Catalog.get_show/2` can build a full show detail
  for a TMDB id (a show not in the user's library yet, surfaced via
  Discover).
  """
  def get_tv(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    case api_key() do
      nil ->
        :error

      key ->
        url = base_url() <> "/api/v1/tv/#{tmdb_id}"

        case Req.get(url,
               headers: [{"x-api-key", key}],
               receive_timeout: 5_000,
               retry: false
             ) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  def get_tv(_), do: :error

  @doc """
  Returns Jellyseerr's per-season episode list for a show. Each
  episode entry has airDate, episodeNumber, name, etc. — enough to
  render the full episode list with aired/not-aired indicators on
  the show detail page, even for shows not yet in the user's library.
  """
  def get_tv_season(tmdb_id, season_number) do
    case api_key() do
      nil ->
        :error

      key ->
        url = base_url() <> "/api/v1/tv/#{tmdb_id}/season/#{season_number}"

        case Req.get(url,
               headers: [{"x-api-key", key}],
               receive_timeout: 5_000,
               retry: false
             ) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end

  @doc """
  Returns `{:ok, results}` where results is the TMDB show list for the
  given network — used by the discover page to populate each
  streaming-service row. Each result has id (TMDB), name, posterPath,
  backdropPath, and a mediaInfo block carrying the Jellyfin id when
  the show is in the library.
  """
  def discover_tv_network(network_id) do
    with key when not is_nil(key) <- api_key(),
         url = base_url() <> "/api/v1/discover/tv/network/#{network_id}",
         {:ok, %Req.Response{status: 200, body: %{"results" => results}}} <-
           Req.get(url,
             headers: [{"x-api-key", key}],
             receive_timeout: 5_000,
             retry: false
           ) do
      {:ok, results}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

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
