defmodule AviaryWeb.API.MovieController do
  @moduledoc """
  Movie detail for native clients — the same `Aviary.Catalog.get_movie/2`
  the web detail page uses, flattened for the tvOS detail screen. Carries
  the per-user resume position for the Play/Resume affordance. Images
  point at the token-authed proxy.
  """
  use AviaryWeb, :controller

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Aviary.Catalog.get_movie(id, user) do
      {:ok, movie} ->
        json(
          conn,
          serialize(movie, in_library?(movie, user), recommended_by(user, movie.tmdb_id, "movie"))
        )

      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp in_library?(%{source: :library, tmdb_id: tmdb_id}, user)
       when is_binary(tmdb_id),
       do: Aviary.Library.member?(user.id, tmdb_id)

  defp in_library?(_, _), do: false

  # Names of household members who recommended this to the current user,
  # for the "X thinks you'll like this" note. Skips the Jellyfin user
  # lookup entirely when there are no recommenders (the common case).
  defp recommended_by(user, tmdb_id, kind) do
    case Aviary.Recommendations.recommenders_for(user.id, tmdb_id, kind) do
      [] ->
        []

      sender_ids ->
        names = user |> Aviary.Jellyfin.list_users() |> Map.new(&{&1["Id"], &1["Name"]})
        sender_ids |> Enum.map(&Map.get(names, &1)) |> Enum.reject(&is_nil/1)
    end
  end

  defp serialize(movie, in_library, recommended_by) do
    %{
      id: movie.id,
      tmdbId: movie.tmdb_id,
      source: to_string(movie.source),
      title: movie.title,
      year: movie.year,
      runtimeMinutes: movie.runtime_minutes,
      officialRating: movie.official_rating,
      genre: movie.genre,
      synopsis: movie.synopsis,
      trailerUrl: movie.trailer_url,
      poster: image_path(movie.poster_url),
      backdrop: backdrop(movie),
      rating: movie.rating,
      resumeSeconds: movie.resume_seconds,
      inLibrary: in_library,
      recommendedBy: recommended_by
    }
  end

  defp backdrop(%{source: :discover, poster_url: poster}), do: image_path(poster)
  defp backdrop(movie), do: "/api/v1/image/#{movie.id}?kind=backdrop"

  defp image_path(nil), do: nil
  defp image_path(url), do: "/api/v1" <> url
end
