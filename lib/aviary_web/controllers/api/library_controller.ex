defmodule AviaryWeb.API.LibraryController do
  @moduledoc """
  The user's curated library for native clients — the same per-user
  `Aviary.Catalog` lists the web Shows / Movies tabs render, flattened
  into the shape the tvOS client's catalog grid expects, with image
  URLs pointing at the token-authed image proxy (`/api/v1/image/:id`).
  """
  use AviaryWeb, :controller

  def shows(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Catalog.list_shows()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  def movies(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Catalog.list_movies()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  @doc """
  Adds a discover/search item to the user's library and kicks off the
  grab — shows via Sonarr, movies via Radarr. `id` is the TMDB id (the
  detail endpoints expose it as `tmdbId`). Mirrors the web detail
  page's Watch button so a title added from the tvOS client downloads
  the same way.
  """
  def add(conn, %{"kind" => "show", "id" => id, "season" => season, "episode" => episode})
      when is_integer(season) and is_integer(episode) do
    user = conn.assigns.current_user
    tmdb_id = to_string(id)

    Aviary.Library.add(user.id, tmdb_id)

    case Aviary.Sonarr.watch_episode(tmdb_id, season, episode) do
      {:ok, _} ->
        Aviary.SeriesFollowup.after_episode_imports(tmdb_id, season, episode)
        json(conn, %{ok: true})

      _ ->
        conn |> put_status(:bad_gateway) |> json(%{error: "downloader_unavailable"})
    end
  end

  def add(conn, %{"kind" => kind, "id" => id}) do
    user = conn.assigns.current_user
    tmdb_id = to_string(id)

    Aviary.Library.add(user.id, tmdb_id)

    result =
      case kind do
        "movie" -> Aviary.Radarr.watch_movie(tmdb_id)
        _ -> Aviary.Sonarr.watch_show(tmdb_id)
      end

    case result do
      {:ok, _} -> json(conn, %{ok: true})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "downloader_unavailable"})
    end
  end

  defp serialize(item) do
    %{
      id: item.id,
      kind: to_string(item.type),
      title: item.title,
      year: year_label(item.year),
      image: "/api/v1/image/#{item.id}"
    }
  end

  # Movies carry a plain production year; shows carry a {start, finish}
  # range ({start, nil} while continuing). Flatten both to the string
  # the client renders, mirroring the web's year formatting.
  defp year_label(year) when is_integer(year), do: Integer.to_string(year)
  defp year_label({start, nil}) when is_integer(start), do: "#{start} – present"

  defp year_label({start, finish}) when is_integer(start) and is_integer(finish),
    do: "#{start} – #{finish}"

  defp year_label(_), do: nil
end
