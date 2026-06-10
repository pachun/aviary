defmodule AviaryWeb.ImageController do
  @moduledoc """
  Proxies poster images from Jellyfin to the browser. Reasons we proxy
  instead of having `<img src>` hit Jellyfin directly:

    * The deployed container reaches Jellyfin via host.docker.internal,
      which means nothing to a browser on someone's laptop.
    * The API key stays server-side — never appears in a `<img src>`
      attribute, network log, or page source.
    * Aviary controls caching headers and can swap the upstream
      (Jellyfin, alternative server, etc.) without the UI noticing.

  Cached aggressively client-side: posters keyed by Jellyfin's item ID
  are content-addressed for our purposes (they don't change without the
  ID changing).
  """
  use AviaryWeb, :controller

  def show(conn, %{"item_id" => item_id}) do
    case Aviary.Jellyfin.fetch_poster(item_id) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("cache-control", "public, max-age=86400, immutable")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "")
    end
  end
end
