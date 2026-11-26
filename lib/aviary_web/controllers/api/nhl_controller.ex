defmodule AviaryWeb.API.NhlController do
  @moduledoc """
  What the NHL schedule adds to the live section for the tvOS client:
  the playlist a relayed feed plays from, team logos, the standings and
  each team's page. The events themselves and the handshake at the
  moment of play are `AviaryWeb.API.LiveController`'s.

  `playlist` is what AVPlayer reloads every few seconds; like the
  subtitle proxy it carries the token in the URL because AVPlayer
  doesn't forward Authorization to HLS sub-requests.

  Every segment and key in that playlist points back at `segment`, so
  the video reaches the player through aviary and the player never has
  to reach the stream host itself. A household router that blocks the
  host's name (eero's filtering did, on 2026-10-22) then blocks nothing,
  and aviary resolves the name through public DNS.

  A server that defines its own live section has none of this: every
  address here answers that it does not exist.
  """
  use AviaryWeb, :controller

  plug :exist_only_where_live_is_the_nhl_schedule

  defp exist_only_where_live_is_the_nhl_schedule(conn, _options) do
    if Aviary.Live.sports?(),
      do: conn,
      else: conn |> put_status(:not_found) |> json(%{error: "not_found"}) |> halt()
  end

  def standings(conn, _params) do
    case Aviary.Nhl.Standings.divisions() do
      {:ok, divisions} ->
        json(conn, %{divisions: Enum.map(divisions, &serialize_division/1)})

      :error ->
        conn |> put_status(:bad_gateway) |> json(%{error: "standings_unavailable"})
    end
  end

  def teams(conn, _params) do
    case Aviary.Nhl.Standings.teams() do
      {:ok, teams} -> json(conn, %{teams: Enum.map(teams, &serialize_standing/1)})
      :error -> conn |> put_status(:bad_gateway) |> json(%{error: "teams_unavailable"})
    end
  end

  def team(conn, %{"id" => team_id}) do
    case Aviary.Nhl.Team.fetch(team_id) do
      {:ok, team} -> json(conn, AviaryWeb.API.NhlTeam.serialize(team))
      :error -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def playlist(conn, %{"id" => game_id, "feed" => feed_id, "token" => token}) do
    rewrite_media_url = &segment_path(game_id, feed_id, token, &1)

    with true <- Aviary.Auth.token_valid?(token),
         {:ok, playlist} <- Aviary.Nhl.playlist(game_id, feed_id, rewrite_media_url) do
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

  def segment(conn, %{"id" => game_id, "feed" => feed_id, "token" => token, "url" => url}) do
    with true <- Aviary.Auth.token_valid?(token),
         {:ok, %{body: body, content_type: content_type}} <-
           Aviary.Nhl.segment(game_id, feed_id, url) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, body)
    else
      false -> send_resp(conn, 401, "")
      :error -> send_resp(conn, 502, "")
    end
  end

  def segment(conn, _params), do: send_resp(conn, 401, "")

  defp segment_path(game_id, feed_id, token, media_url) do
    "/api/v1/nhl/games/#{game_id}/feeds/#{feed_id}/segment?" <>
      URI.encode_query(token: token, url: media_url)
  end

  def logo(conn, %{"team" => team_id} = params) do
    background = if params["background"] == "dark", do: :dark, else: :light

    case Aviary.Nhl.logo(team_id, background) do
      {:ok, png} ->
        conn
        |> put_resp_content_type("image/png")
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_resp(200, png)

      :error ->
        send_resp(conn, 404, "")
    end
  end

  defp serialize_division(division) do
    %{
      name: division.name,
      conference: division.conference,
      teams: Enum.map(division.teams, &serialize_standing/1)
    }
  end

  defp serialize_standing(team) do
    team
    |> serialize_team()
    |> Map.merge(%{
      rank: team.rank,
      leagueRank: team.league_rank,
      gamesPlayed: team.games_played,
      wins: team.wins,
      losses: team.losses,
      overtimeLosses: team.overtime_losses,
      points: team.points,
      goalDifference: team.goal_difference,
      lastTen: team.last_ten,
      streak: team.streak
    })
  end

  defp serialize_team(team) do
    %{
      id: team.id,
      name: team.name,
      nickname: team.nickname,
      logo: "/api/v1/nhl/logos/#{team.id}?background=dark"
    }
  end
end
