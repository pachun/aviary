defmodule AviaryWeb.ImageController do
  @moduledoc """
  Proxies poster images from Jellyfin to the browser. The current
  user's auth (read from session via `fetch_current_user`) authorizes
  the upstream fetch — Jellyfin sees a request made as the actual
  signed-in user.

  Aggressively cached client-side (Jellyfin's item IDs are stable
  enough that we treat each URL as content-addressed).
  """
  use AviaryWeb, :controller

  def show(conn, %{"item_id" => item_id}) do
    case Aviary.Jellyfin.fetch_poster(item_id, conn.assigns.current_user) do
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
