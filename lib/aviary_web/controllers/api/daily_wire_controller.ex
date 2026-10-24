defmodule AviaryWeb.API.DailyWireController do
  use AviaryWeb, :controller

  def episodes(conn, %{"show" => show} = params) do
    respond(conn, Aviary.DailyWire.episodes(conn.assigns.current_user, show, params["page"]))
  end

  def playback(conn, %{"slug" => slug}) do
    respond(conn, Aviary.DailyWire.playback(conn.assigns.current_user, slug))
  end

  defp respond(conn, {:ok, body}) do
    conn |> put_resp_header("cache-control", "no-store") |> json(body)
  end

  defp respond(conn, {:error, reason}) do
    status =
      case reason do
        :forbidden -> :forbidden
        :not_found -> :not_found
        :invalid_page -> :bad_request
        _ -> :service_unavailable
      end

    conn |> put_status(status) |> json(%{error: reason})
  end
end
