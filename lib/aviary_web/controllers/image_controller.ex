defmodule AviaryWeb.ImageController do
  @moduledoc """
  Proxies poster + backdrop images from Jellyfin. The current user's
  auth (read from session) authorizes the upstream fetch — Jellyfin
  sees a request made as the actual signed-in user.

  `kind=backdrop` returns the 16:9 backdrop for marquee thumbnails;
  default returns the 2:3 poster for grid items.
  """
  use AviaryWeb, :controller

  def show(conn, %{"item_id" => item_id} = params) do
    fetcher = fetcher_for(params["kind"])

    case fetcher.(item_id, conn.assigns.current_user) do
      {:ok, body, content_type} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("cache-control", "public, max-age=86400, immutable")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "")
    end
  end

  defp fetcher_for("backdrop"), do: &Aviary.Jellyfin.fetch_backdrop/2
  defp fetcher_for(_), do: &Aviary.Jellyfin.fetch_poster/2
end
