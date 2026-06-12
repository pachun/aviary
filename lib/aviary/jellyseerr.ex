defmodule Aviary.Jellyseerr do
  @moduledoc """
  Thin wrapper over Jellyseerr's REST API. We use Jellyseerr for one
  thing only right now: knowing when the next episode of an actively-
  airing show is scheduled to release. Jellyfin's own metadata stops
  at "what's been released" — the future-air-date intel comes from
  Jellyseerr's TMDB sync.

  Auth is a single API key (not per-user) — Jellyseerr's read endpoints
  are not user-scoped in the way we need, and the data we're pulling
  (release dates) is the same for every user. Keyed at the application
  env via `:jellyseerr_api_key`.

  This module returns `:none` (rather than raising / `:error`) for any
  case where the schedule can't be determined — show is ended, no
  upcoming episode known, TMDB id missing, Jellyseerr unreachable, etc.
  Callers are expected to fall back to the existing trailer treatment
  in those cases.
  """

  @doc """
  Returns a schedule shape for a TV show given its TMDB id, or `:none`.

  Schedule shape:

      %{
        air_date: ~D[2026-06-14],
        season: 9,
        episode: 4,
        kind: :continuation | :new_season
      }

  `:continuation` means the next episode is part of the same season as
  the last-aired one (a weekly drop inside an ongoing season).
  `:new_season` means a new season has been announced — the calendar
  widget swaps to an announcement treatment for these.
  """
  def get_tv_schedule(nil), do: :none

  def get_tv_schedule(tmdb_id) when is_binary(tmdb_id) or is_integer(tmdb_id) do
    case get(tmdb_id) do
      {:ok, %{"nextEpisodeToAir" => nil}} ->
        :none

      {:ok, %{"nextEpisodeToAir" => next} = body} ->
        build_schedule(next, body["lastEpisodeToAir"])

      _ ->
        :none
    end
  end

  defp build_schedule(next, last) do
    with %{"airDate" => air_date_str, "seasonNumber" => s, "episodeNumber" => e}
         when is_binary(air_date_str) <- next,
         {:ok, air_date} <- Date.from_iso8601(air_date_str) do
      %{
        air_date: air_date,
        season: s,
        episode: e,
        kind: schedule_kind(s, last)
      }
    else
      _ -> :none
    end
  end

  # New season iff the upcoming episode's season number is higher than
  # the last-aired episode's. When we don't have a last episode to
  # compare (brand new show with announced premiere), default to
  # :new_season too — that treatment is more accurate than "weekly
  # drop calendar" for a never-aired show.
  defp schedule_kind(_next_season, nil), do: :new_season

  defp schedule_kind(next_season, %{"seasonNumber" => last_season})
       when is_integer(next_season) and is_integer(last_season) do
    if next_season > last_season, do: :new_season, else: :continuation
  end

  defp schedule_kind(_, _), do: :continuation

  defp get(tmdb_id) do
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
