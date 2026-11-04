defmodule AviaryWeb.ShowControllerTest do
  use AviaryWeb.ConnCase, async: true

  test "setting a watch point requires a signed-in Aviary session", %{conn: conn} do
    conn = post(conn, "/api/v1/shows/some-show/watch-point", %{"episodeId" => "s1e1"})
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
