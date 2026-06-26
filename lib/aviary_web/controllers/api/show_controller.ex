defmodule AviaryWeb.API.ShowController do
  @moduledoc """
  Show detail for native clients — the same `Aviary.Catalog.get_show/2`
  the web detail page uses, flattened into the shape the tvOS detail
  screen renders. Episodes carry their per-user watch state (played
  percentage + resume position) so the client can show progress on each
  episode card. Images point at the token-authed proxy.
  """
  use AviaryWeb, :controller

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Aviary.Catalog.get_show(id, user) do
      {:ok, show} ->
        json(conn, serialize(show, in_library?(show, user)))

      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp in_library?(%{source: :library, tmdb_id: tmdb_id}, user)
       when is_binary(tmdb_id),
       do: Aviary.Library.member?(user.id, tmdb_id)

  defp in_library?(_, _), do: false

  defp serialize(show, in_library) do
    %{
      id: show.id,
      tmdbId: show.tmdb_id,
      source: to_string(show.source),
      title: show.title,
      year: year_label(show.year),
      status: show.status,
      officialRating: show.official_rating,
      genre: show.genre,
      synopsis: show.synopsis,
      trailerUrl: show.trailer_url,
      runtimeMinutes: show.runtime_minutes,
      poster: image_path(show.poster_url),
      backdrop: backdrop(show),
      seasonCount: show.season_count,
      rating: show.rating,
      inLibrary: in_library,
      nextUp: serialize_next_up(show.next_up),
      seasons:
        Enum.map(show.episodes_by_season, fn {season, eps} ->
          %{season: season, episodes: Enum.map(eps, &serialize_episode/1)}
        end)
    }
  end

  defp serialize_episode(ep) do
    downloaded = not String.starts_with?(ep.id, "tmdb-")

    %{
      id: ep.id,
      season: ep.season,
      episode: ep.episode,
      title: ep.title,
      synopsis: ep.synopsis,
      runtimeMinutes: ep.runtime_minutes,
      playedPercentage: ep.played_percentage,
      resumeSeconds: ep.resume_seconds,
      lastPlayedAt: ep.last_played_at,
      airDate: ep.air_date,
      aired: ep.aired,
      downloaded: downloaded,
      image:
        if(downloaded,
          do: "/api/v1/image/#{ep.id}",
          else: image_path(Map.get(ep, :still_url))
        )
    }
  end

  # Library items carry a Jellyfin backdrop; discover (TMDB) items have
  # no Jellyfin id to proxy, so fall back to their poster art.
  defp backdrop(%{source: :discover, poster_url: poster}), do: image_path(poster)
  defp backdrop(show), do: "/api/v1/image/#{show.id}?kind=backdrop"

  # Catalog image paths are browser-relative ("/image/..."); prefix
  # them into the token-authed native image proxy. nil passes through.
  defp image_path(nil), do: nil
  defp image_path(url), do: "/api/v1" <> url

  defp serialize_next_up(nil), do: nil

  defp serialize_next_up(%{caught_up: true}),
    do: %{caughtUp: true, id: nil, season: nil, episode: nil, resumeSeconds: nil}

  defp serialize_next_up(ep) do
    %{
      id: ep.id,
      season: ep.season,
      episode: ep.episode,
      resumeSeconds: Map.get(ep, :resume_seconds),
      caughtUp: false
    }
  end

  defp year_label({start, nil}) when is_integer(start), do: "#{start} – present"

  defp year_label({start, finish}) when is_integer(start) and is_integer(finish),
    do: "#{start} – #{finish}"

  defp year_label(_), do: nil
end
