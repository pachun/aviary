defmodule AviaryWeb.API.SeriesController do
  @moduledoc """
  The server's series section for the tvOS client: a show's episodes,
  where one plays from, and the user's place in it.
  """
  use AviaryWeb, :controller

  def episodes(conn, %{"show" => show} = params) do
    respond(conn, Aviary.Series.episodes(conn.assigns.current_user, show, params["page"]))
  end

  def playback(conn, %{"id" => episode_id}) do
    respond(conn, Aviary.Series.playback(conn.assigns.current_user, episode_id))
  end

  def progress(conn, %{"id" => episode_id} = params) do
    respond(conn, Aviary.Series.save_progress(conn.assigns.current_user, episode_id, params))
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
        :invalid_progress -> :bad_request
        :stale_progress -> :conflict
        _ -> :service_unavailable
      end

    conn |> put_status(status) |> json(%{error: reason})
  end
end
