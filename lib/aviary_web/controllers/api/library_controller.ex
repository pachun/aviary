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
  # Answers once Sonarr has the show, then starts the download in the
  # background: a busy Sonarr can take most of a minute to list a new
  # show's episodes, and the app should show the show as searching in
  # the meantime rather than sit on "Adding…".
  def add(conn, %{"kind" => "show", "id" => id, "season" => season, "episode" => episode})
      when is_integer(season) and is_integer(episode) do
    add_show(conn, to_string(id), {season, episode})
  end

  # "Add to library" on a show with no episode chosen. Grab the
  # starting episode at high priority and queue the rest behind it —
  # the same flow tapping a single episode uses, so the show is
  # watchable in minutes instead of burying episode one behind a
  # whole-series download. Falls back to the whole series if we can't
  # resolve a starting episode (e.g. nothing has aired yet).
  def add(conn, %{"kind" => "show", "id" => id}) do
    add_show(conn, to_string(id), :starting_episode)
  end

  def add(conn, %{"kind" => "movie", "id" => id}) do
    user = conn.assigns.current_user
    tmdb_id = to_string(id)

    Aviary.Library.add(user.id, tmdb_id)

    case Aviary.Radarr.watch_movie(tmdb_id) do
      {:ok, _} -> json(conn, %{ok: true})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "downloader_unavailable"})
    end
  end

  defp add_show(conn, tmdb_id, chosen_episode) do
    Aviary.Library.add(conn.assigns.current_user.id, tmdb_id)

    case Aviary.Sonarr.track_series(tmdb_id) do
      {:ok, _series} ->
        Task.Supervisor.start_child(Aviary.TaskSupervisor, fn ->
          start_watching(tmdb_id, chosen_episode)
        end)

        json(conn, %{ok: true})

      _ ->
        conn |> put_status(:bad_gateway) |> json(%{error: "downloader_unavailable"})
    end
  end

  defp start_watching(tmdb_id, :starting_episode) do
    case Aviary.Sonarr.starting_episode(tmdb_id) do
      {:ok, season, episode} -> start_watching(tmdb_id, {season, episode})
      :error -> Aviary.Sonarr.watch_show(tmdb_id)
    end
  end

  defp start_watching(tmdb_id, {season, episode}) do
    with {:ok, _episode} <- Aviary.Sonarr.watch_episode(tmdb_id, season, episode) do
      Aviary.SkipTheLine.for_episode(tmdb_id, season, episode)
      Aviary.SeriesFollowup.queue_the_rest(tmdb_id)
    end
  end

  @doc """
  Removes a title from the user's library. A per-user curation action —
  the files and downloads are untouched, so re-adding is instant.
  """
  def remove(conn, %{"tmdb_id" => tmdb_id, "kind" => kind})
      when kind in ["show", "movie"] do
    Aviary.Library.remove(conn.assigns.current_user.id, tmdb_id, kind)
    json(conn, %{ok: true})
  end

  defp serialize(item) do
    %{
      id: item.id,
      tmdb_id: to_string(item.tmdb_id),
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
