defmodule AviaryWeb.StatusControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias Aviary.{Sabnzbd, Sonarr}
  alias AviaryWeb.API.StatusController

  @tmdb_id "155537"
  @series_id 80
  @episode_id 15111
  @download_id "black-bird-pilot"

  setup do
    Aviary.Cache.invalidate(:sonarr_series_list)
    Aviary.Cache.invalidate({:dl_refresh, :sonarr})
    Aviary.Cache.invalidate({:jellyfin_list_shows, "viewer"})
    Aviary.Cache.invalidate(:jellyfin_library_refresh)
    :ok
  end

  test "both episode indicators stay searching throughout the availability check" do
    for percent <- [0, 50, 100] do
      stub_sonarr(percent)
      stub_sabnzbd("Checking", percent)

      assert episode_status() == {%{"kind" => "searching"}, %{"kind" => "searching"}}
    end
  end

  test "both indicators show the actual transfer after the availability check finishes" do
    stub_sonarr(100)

    for percent <- [0, 50, 99] do
      stub_sabnzbd("Downloading", percent)
      downloading = %{"kind" => "downloading", "percent" => percent}

      assert episode_status() == {downloading, downloading}
    end
  end

  test "both indicators switch to importing when the transfer reaches completion" do
    stub_sonarr(95)
    stub_sabnzbd("Downloading", 100)

    Req.Test.stub(Aviary.Jellyfin, fn conn ->
      case conn.request_path do
        "/Items" ->
          Req.Test.json(conn, %{"Items" => []})

        "/ScheduledTasks" ->
          Req.Test.json(conn, [%{"Key" => "RefreshLibrary", "State" => "Idle"}])

        "/Library/Refresh" ->
          send_resp(conn, 204, "")
      end
    end)

    assert episode_status() == {%{"kind" => "imported"}, %{"kind" => "imported"}}
  end

  test "download progress remains available when SABnzbd cannot be reached" do
    stub_sonarr(42)
    Req.Test.stub(Sabnzbd, &Req.Test.transport_error(&1, :timeout))
    downloading = %{"kind" => "downloading", "percent" => 42}

    assert episode_status() == {downloading, downloading}
  end

  test "another download's availability check leaves this episode's progress alone" do
    stub_sonarr(42)
    stub_sabnzbd("Checking", 90, "another-download")
    downloading = %{"kind" => "downloading", "percent" => 42}

    assert episode_status() == {downloading, downloading}
  end

  defp episode_status do
    conn =
      build_conn()
      |> assign(:current_user, %{id: "viewer", token: "viewer-token"})
      |> StatusController.show(%{"tmdb_id" => @tmdb_id})

    response = json_response(conn, 200)
    {response["overall"], response["episodes"]["1:1"]}
  end

  defp stub_sonarr(percent) do
    Req.Test.stub(Sonarr, fn conn ->
      case conn.request_path do
        "/api/v3/series" ->
          Req.Test.json(conn, [%{"id" => @series_id, "tmdbId" => @tmdb_id}])

        "/api/v3/episode" ->
          Req.Test.json(conn, [
            %{
              "id" => @episode_id,
              "seasonNumber" => 1,
              "episodeNumber" => 1,
              "monitored" => true,
              "hasFile" => false
            }
          ])

        "/api/v3/queue" ->
          complete_percent = 100

          Req.Test.json(conn, %{
            "records" => [
              %{
                "episodeId" => @episode_id,
                "downloadId" => @download_id,
                "status" => "downloading",
                "size" => complete_percent,
                "sizeleft" => complete_percent - percent
              }
            ]
          })

        "/api/v3/command" ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  defp stub_sabnzbd(status, percent, download_id \\ @download_id) do
    Req.Test.stub(Sabnzbd, fn conn ->
      conn = fetch_query_params(conn)
      assert conn.query_params["mode"] == "queue"

      Req.Test.json(conn, %{
        "queue" => %{
          "slots" => [
            %{"nzo_id" => download_id, "status" => status, "percentage" => to_string(percent)}
          ]
        }
      })
    end)
  end
end
