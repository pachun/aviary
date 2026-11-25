defmodule AviaryWeb.StatusControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias Aviary.{Radarr, Sabnzbd, Sonarr}
  alias AviaryWeb.API.StatusController

  @tmdb_id "155537"
  @series_id 80
  @episode_id 15111
  @download_id "black-bird-pilot"
  @movie_tmdb_id "167073"
  @radarr_movie_id 115
  @movie_download_id "brooklyn"

  setup do
    Aviary.Cache.invalidate(:sonarr_series_list)
    Aviary.Cache.invalidate(:radarr_movie_list)
    Aviary.Cache.invalidate({:dl_refresh, :radarr})
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

  test "both indicators say the download is being checked once every byte is in" do
    stub_sonarr(95)
    stub_sabnzbd("Downloading", 100)
    verifying = %{"kind" => "verifying"}

    assert episode_status() == {verifying, verifying}
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

  describe "a movie being downloaded" do
    test "stays searching throughout the availability check" do
      for percent <- [0, 50, 100] do
        stub_radarr(queue: [movie_queue_record(percent)])
        stub_sabnzbd("Checking", percent, @movie_download_id)

        assert movie_status()["overall"] == %{"kind" => "searching"}
      end
    end

    test "shows the actual transfer after the availability check finishes" do
      stub_radarr(queue: [movie_queue_record(42)])
      stub_sabnzbd("Downloading", 42, @movie_download_id)

      assert movie_status()["overall"] == %{"kind" => "downloading", "percent" => 42}
    end

    test "says the download is being checked while SABnzbd verifies and unpacks it" do
      stub_radarr(queue: [movie_queue_record(100)])
      stub_sabnzbd_without_slots()

      status = movie_status()

      assert status["overall"] == %{"kind" => "verifying"}
      assert status["label"] == "Checking the download"
    end

    test "says importing once Radarr takes the finished download" do
      stub_radarr(queue: [Map.put(movie_queue_record(100), "trackedDownloadState", "importing")])
      stub_sabnzbd_without_slots()
      stub_quiet_jellyfin()

      assert movie_status()["overall"] == %{"kind" => "imported"}
    end

    test "says it is trying another copy after a broken one is thrown out" do
      stub_radarr(
        queue: [],
        last_searched_at: DateTime.to_iso8601(DateTime.utc_now()),
        history: [
          %{"eventType" => "grabbed", "date" => "2026-11-25T00:01:18Z"},
          %{"eventType" => "downloadFailed", "date" => "2026-11-25T00:04:08Z"}
        ]
      )

      status = movie_status()

      assert status["overall"] == %{"kind" => "retrying"}
      assert status["label"] == "That copy was broken. Trying another"
    end
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

  defp movie_status do
    build_conn()
    |> assign(:current_user, %{id: "viewer", token: "viewer-token"})
    |> StatusController.movie(%{"tmdb_id" => @movie_tmdb_id})
    |> json_response(200)
  end

  defp movie_queue_record(percent) do
    complete_percent = 100

    %{
      "movieId" => @radarr_movie_id,
      "downloadId" => @movie_download_id,
      "status" => "downloading",
      "trackedDownloadState" => "downloading",
      "size" => complete_percent,
      "sizeleft" => complete_percent - percent
    }
  end

  defp stub_radarr(opts) do
    movie = %{
      "id" => @radarr_movie_id,
      "tmdbId" => String.to_integer(@movie_tmdb_id),
      "monitored" => true,
      "hasFile" => false,
      "status" => "released",
      "lastSearchTime" => Keyword.get(opts, :last_searched_at)
    }

    Req.Test.stub(Radarr, fn conn ->
      case conn.request_path do
        "/api/v3/movie" -> Req.Test.json(conn, [movie])
        "/api/v3/queue" -> Req.Test.json(conn, %{"records" => Keyword.fetch!(opts, :queue)})
        "/api/v3/history/movie" -> Req.Test.json(conn, Keyword.get(opts, :history, []))
        "/api/v3/command" -> Req.Test.json(conn, %{})
      end
    end)
  end

  defp stub_sabnzbd_without_slots do
    Req.Test.stub(Sabnzbd, &Req.Test.json(&1, %{"queue" => %{"slots" => []}}))
  end

  defp stub_quiet_jellyfin do
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
  end
end
