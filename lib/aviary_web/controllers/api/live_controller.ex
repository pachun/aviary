defmodule AviaryWeb.API.LiveController do
  @moduledoc """
  The server's live section for the tvOS client: the events on offer
  and, at the moment of play, where a chosen feed plays from. A feed
  aviary relays itself answers with the playlist path the NHL
  controller serves; a feed the server's sections file points at
  answers with that address directly.
  """
  use AviaryWeb, :controller

  def events(conn, _params) do
    json(conn, %{events: Enum.map(Aviary.Live.events(), &serialize_event/1)})
  end

  def feed(conn, %{"id" => event_id, "feed" => feed_id}) do
    case Aviary.Live.feed(event_id, feed_id) do
      {:ok, {:direct, url}} ->
        json(conn, %{streamUrl: url, contentType: "hls"})

      {:ok, :through_aviary} ->
        json(conn, %{
          streamUrl:
            "/api/v1/nhl/games/#{event_id}/feeds/#{feed_id}/playlist.m3u8?" <>
              URI.encode_query(token: conn.assigns.current_user.token),
          contentType: "hls"
        })

      {:error, :not_live} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "not_live"})

      {:error, :unavailable} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "stream_unavailable"})
    end
  end

  defp serialize_event(event) do
    %{
      id: event.id,
      title: event.title,
      time: event.time,
      startsAt: event.starts_at,
      images: event.images,
      feeds: event.feeds
    }
  end
end
