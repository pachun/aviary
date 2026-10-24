defmodule AviaryWeb.DailyWireControllerTest do
  use AviaryWeb.ConnCase, async: true

  test "episode lists require a signed-in Aviary session", %{conn: conn} do
    conn = get(conn, "/api/v1/daily-wire/shows/the-ben-shapiro-show/episodes")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "playback requires a signed-in Aviary session", %{conn: conn} do
    conn = get(conn, "/api/v1/daily-wire/episodes/member-episode/playback")
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
