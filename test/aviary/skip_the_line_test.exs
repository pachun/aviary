defmodule Aviary.SkipTheLineTest do
  use ExUnit.Case, async: false

  alias Aviary.{Sabnzbd, SkipTheLine, Sonarr}

  @tmdb_id "42009"
  @sonarr_series_id 7
  @sonarr_episode_id 99
  @front_of_the_queue "2"

  setup :set_req_test_to_shared
  setup :fresh_sonarr_caches

  test "moves the grab to the front of SABnzbd's queue once Sonarr makes it" do
    stub_sonarr(history: in_order([[], [grab("nzo-1")], [imported(), grab("nzo-1")]]))
    stub_sabnzbd()

    SkipTheLine.for_episode(@tmdb_id, 1, 1, poll_every_ms: 1)

    assert_receive {:sabnzbd,
                    %{
                      "mode" => "queue",
                      "name" => "priority",
                      "value" => "nzo-1",
                      "value2" => @front_of_the_queue
                    }},
                   1_000

    refute_receive {:sabnzbd, _}, 50
  end

  test "promotes the replacement when a grab fails and Sonarr grabs again" do
    stub_sonarr(
      history:
        in_order([
          [grab("nzo-1")],
          [failed("nzo-1"), grab("nzo-1")],
          [grab("nzo-2"), failed("nzo-1"), grab("nzo-1")],
          [imported(), grab("nzo-2"), failed("nzo-1"), grab("nzo-1")]
        ])
    )

    stub_sabnzbd()

    SkipTheLine.for_episode(@tmdb_id, 1, 1, poll_every_ms: 1)

    assert_receive {:sabnzbd, %{"value" => "nzo-1"}}, 1_000
    assert_receive {:sabnzbd, %{"value" => "nzo-2"}}, 1_000
    refute_receive {:sabnzbd, _}, 50
  end

  test "leaves a torrent grab in its own client's order" do
    stub_sonarr(history: in_order([[grab("hash-1", client: "qBittorrent")], [imported()]]))
    stub_sabnzbd()

    pid = SkipTheLine.for_episode(@tmdb_id, 1, 1, poll_every_ms: 1)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    refute_received {:sabnzbd, _}
  end

  test "stops watching once the episode is in" do
    stub_sonarr(history: in_order([[imported(), grab("nzo-1")]]))
    stub_sabnzbd()

    pid = SkipTheLine.for_episode(@tmdb_id, 1, 1, poll_every_ms: 1)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    refute_received {:sabnzbd, _}
  end

  test "gives up after the watch window" do
    stub_sonarr(history: in_order([[]]))
    stub_sabnzbd()

    pid = SkipTheLine.for_episode(@tmdb_id, 1, 1, poll_every_ms: 1, watch_for_ms: 20)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    refute_received {:sabnzbd, _}
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp fresh_sonarr_caches(_context) do
    Aviary.Cache.invalidate(:sonarr_series_list)
    :ok
  end

  defp stub_sonarr(history: history) do
    Req.Test.stub(Sonarr, fn conn ->
      case conn.request_path do
        "/api/v3/series" ->
          Req.Test.json(conn, [
            %{"id" => @sonarr_series_id, "tmdbId" => String.to_integer(@tmdb_id)}
          ])

        "/api/v3/episode" ->
          Req.Test.json(conn, [
            %{
              "id" => @sonarr_episode_id,
              "seasonNumber" => 1,
              "episodeNumber" => 1,
              "monitored" => true,
              "hasFile" => false
            }
          ])

        "/api/v3/queue" ->
          Req.Test.json(conn, %{"records" => []})

        "/api/v3/history" ->
          %{"episodeId" => episode_id} = conn.query_params
          assert episode_id == Integer.to_string(@sonarr_episode_id)
          Req.Test.json(conn, %{"records" => history.()})
      end
    end)
  end

  defp stub_sabnzbd do
    test = self()

    Req.Test.stub(Sabnzbd, fn conn ->
      send(test, {:sabnzbd, conn.query_params})
      Req.Test.json(conn, %{"status" => true, "position" => 0})
    end)
  end

  defp in_order(responses) do
    {:ok, remaining} = Agent.start_link(fn -> responses end)

    fn ->
      Agent.get_and_update(remaining, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  defp grab(download_id, options \\ []) do
    %{
      "eventType" => "grabbed",
      "downloadId" => download_id,
      "data" => %{"downloadClient" => Keyword.get(options, :client, "SABnzbd")}
    }
  end

  defp failed(download_id) do
    %{"eventType" => "downloadFailed", "downloadId" => download_id, "data" => %{}}
  end

  defp imported do
    %{"eventType" => "downloadFolderImported", "downloadId" => "nzo-done", "data" => %{}}
  end
end
