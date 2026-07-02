defmodule AviaryWeb.API.TrailerController do
  @moduledoc """
  Resolves a title's YouTube trailer to a stream the tvOS client can play
  in-app. The client passes the `trailerUrl` it already got from the
  detail endpoint; we validate it's a YouTube link and hand back a
  directly-playable URL via `Aviary.Trailer`.
  """
  use AviaryWeb, :controller

  def show(conn, %{"url" => url}) do
    case Aviary.Trailer.stream_url(url) do
      {:ok, stream_url} ->
        json(conn, %{streamUrl: stream_url})

      :error ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "trailer_unavailable"})
    end
  end
end
