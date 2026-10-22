defmodule AviaryWeb.SonarrWebhookControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias Aviary.Jellyfin

  setup :set_req_test_to_shared

  test "an import gets Jellyfin to list the episode right away", %{conn: conn} do
    stub_jellyfin(series: [%{"Id" => "series-42009", "ProviderIds" => %{"Tmdb" => "42009"}}])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/sonarr/webhook", Jason.encode!(import_event(tmdb_id: 42009)))

    assert response(conn, 200)
    assert_receive {:jellyfin, :refreshed_series, "series-42009"}, 1_000
  end

  test "an import of a show Jellyfin hasn't seen asks for a library scan", %{conn: conn} do
    stub_jellyfin(series: [])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/sonarr/webhook", Jason.encode!(import_event(tmdb_id: 42009)))

    assert response(conn, 200)
    assert_receive {:jellyfin, :library_scan}, 1_000
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp import_event(tmdb_id: tmdb_id) do
    %{
      "eventType" => "Download",
      "series" => %{
        "id" => 7,
        "title" => "Black Mirror",
        "path" => "/shows/Black Mirror",
        "tmdbId" => tmdb_id
      },
      "episodes" => [
        %{"id" => 99, "seasonNumber" => 1, "episodeNumber" => 1, "title" => "The National Anthem"}
      ],
      "episodeFile" => %{"path" => "/shows/Black Mirror/Season 1/Black.Mirror.S01E01.mkv"},
      "isUpgrade" => false
    }
  end

  defp stub_jellyfin(series: series) do
    test = self()

    Req.Test.stub(Jellyfin, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/Items"} ->
          Req.Test.json(conn, %{"Items" => series})

        {"POST", "/Items/" <> rest} ->
          send(test, {:jellyfin, :refreshed_series, String.trim_trailing(rest, "/Refresh")})
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/ScheduledTasks"} ->
          Req.Test.json(conn, [%{"Key" => "RefreshLibrary", "State" => "Idle"}])

        {"POST", "/Library/Refresh"} ->
          send(test, {:jellyfin, :library_scan})
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end
end
