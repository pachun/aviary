defmodule AviaryWeb.API.NhlController do
  @moduledoc """
  Today's NHL games for the tvOS home shelf, and the live playlist the
  client plays. `stream` is the bearer-authed handshake at the moment of
  play: it checks the feed is broadcasting (503 `not_live` when it isn't,
  so the client can say "hasn't started" instead of "broken") and hands
  back the playlist path. `playlist` is what AVPlayer then reloads every
  few seconds; like the subtitle proxy it carries the token in the URL
  because AVPlayer doesn't forward Authorization to HLS sub-requests.
  """
  use AviaryWeb, :controller

  def games(conn, _params) do
    json(conn, %{games: Enum.map(Aviary.Nhl.games(), &serialize_game/1)})
  end

  def stream(conn, %{"id" => game_id, "feed" => feed_id}) do
    case Aviary.Nhl.playlist(game_id, feed_id) do
      {:ok, _playlist} ->
        json(conn, %{
          streamUrl: playlist_path(game_id, feed_id, conn.assigns.current_user.token),
          contentType: "hls"
        })

      {:error, :not_live} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "not_live"})

      {:error, :unavailable} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "stream_unavailable"})
    end
  end

  def playlist(conn, %{"id" => game_id, "feed" => feed_id, "token" => token}) do
    with true <- Aviary.Auth.token_valid?(token),
         {:ok, playlist} <- Aviary.Nhl.playlist(game_id, feed_id) do
      conn
      |> put_resp_content_type("application/vnd.apple.mpegurl")
      |> send_resp(200, playlist)
    else
      false -> send_resp(conn, 401, "")
      {:error, :not_live} -> send_resp(conn, 503, "")
      {:error, :unavailable} -> send_resp(conn, 502, "")
    end
  end

  def playlist(conn, _params), do: send_resp(conn, 401, "")

  defp playlist_path(game_id, feed_id, token) do
    "/api/v1/nhl/games/#{game_id}/feeds/#{feed_id}/playlist.m3u8?" <>
      URI.encode_query(token: token)
  end

  defp serialize_game(game) do
    %{
      id: game.id,
      time: game.time,
      awayTeam: game.away_team,
      homeTeam: game.home_team,
      feeds: Enum.map(game.feeds, &%{id: &1.id, label: &1.label})
    }
  end
end
