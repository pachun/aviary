defmodule AviaryWeb.ImageController do
  @moduledoc """
  Proxies image fetches.

  `show/2` (route `/image/:item_id`) proxies poster + backdrop
  images from Jellyfin. The current user's auth (read from session)
  authorizes the upstream fetch — Jellyfin sees a request made as
  the actual signed-in user.

  `tmdb/2` (route `/image/tmdb/:size/*path`) proxies TMDB CDN
  images with a disk-backed cache (see `Aviary.TmdbImageCache`).
  First request fetches from `image.tmdb.org` and writes to disk;
  every subsequent request hits the local disk and pays no
  network. Used by Discover where most artwork is TMDB-sourced.

  Both routes set aggressive `Cache-Control` headers so the
  browser caches the response across page loads — the disk layer
  is the fallback for cold browser caches.
  """
  use AviaryWeb, :controller

  def show(conn, %{"item_id" => item_id} = params) do
    fetcher = fetcher_for(params["kind"])
    user = conn.assigns.current_user

    case fetcher.(item_id, user) do
      {:ok, body, content_type} ->
        send_image(conn, body, content_type)

      :error ->
        fall_back(conn, params["fallback"], user)
    end
  end

  # Episode stills 404 in Jellyfin for episodes whose artwork never
  # backfilled. When a `fallback` series id is supplied (the native home
  # feed does this for show episodes), serve that series' backdrop rather
  # than a broken image. Web callers omit `fallback` and get the plain
  # 404 as before.
  defp fall_back(conn, nil, _user), do: send_resp(conn, 404, "")

  defp fall_back(conn, series_id, user) do
    case Aviary.Jellyfin.fetch_backdrop(series_id, user) do
      {:ok, body, content_type} -> send_image(conn, body, content_type)
      :error -> send_resp(conn, 404, "")
    end
  end

  defp send_image(conn, body, content_type) do
    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("cache-control", "public, max-age=86400, immutable")
    |> send_resp(200, body)
  end

  def user(conn, %{"user_id" => user_id}) do
    case Aviary.Jellyfin.fetch_user_image(user_id) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_header("content-type", content_type)
        # Aggressive cache: the URL includes ?tag=<PrimaryImageTag>
        # as a cache-buster, so when the user uploads a new image in
        # Jellyfin the tag changes and the browser fetches the new
        # bytes. Same `immutable` strategy as TMDB images.
        |> put_resp_header("cache-control", "public, max-age=2592000, immutable")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "")
    end
  end

  def tmdb(conn, %{"size" => size, "path" => path_segments}) do
    # Phoenix splits the catch-all into a list of segments. TMDB
    # filenames are flat, but joining keeps us safe if a future
    # path includes a slash.
    path = Enum.join(List.wrap(path_segments), "/")

    case Aviary.TmdbImageCache.fetch(size, path) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("cache-control", "public, max-age=2592000, immutable")
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 400, "")

      :error ->
        send_resp(conn, 404, "")
    end
  end

  defp fetcher_for("backdrop"), do: &Aviary.Jellyfin.fetch_backdrop/2
  defp fetcher_for(_), do: &Aviary.Jellyfin.fetch_poster/2
end
