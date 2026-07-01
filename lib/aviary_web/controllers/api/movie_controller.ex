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
        json(conn, serialize(movie, in_library?(movie, user)))

      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp in_library?(%{source: :library, tmdb_id: tmdb_id}, user)
       when is_binary(tmdb_id),
       do: Aviary.Library.member?(user.id, tmdb_id)

  defp in_library?(_, _), do: false

  defp serialize(movie, in_library) do
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
      poster: "/api/v1/image/#{movie.id}",
      backdrop: "/api/v1/image/#{movie.id}?kind=backdrop",
      rating: movie.rating,
      resumeSeconds: movie.resume_seconds,
      inLibrary: in_library
    }
  end
end
