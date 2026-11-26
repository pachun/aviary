defmodule Aviary.SeriesFollowupTest do
  use ExUnit.Case, async: false

  alias Aviary.{SeriesFollowup, Sonarr}

  @moduletag :capture_log

  @tmdb_id "60622"
  @sonarr_series_id 7
  @chosen_episode_id 101
  @next_episode_id 102

  setup :set_req_test_to_shared
  setup :fresh_sonarr_caches

  test "searches for the rest of the show while the chosen episode is still downloading" do
    stub_sonarr(chosen_episode_has_file: false)

    SeriesFollowup.queue_the_rest(@tmdb_id)

    assert_receive {:sonarr, :search, [@next_episode_id]}, 1_000
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp fresh_sonarr_caches(_context) do
    Aviary.Cache.invalidate(:sonarr_series_list)
    :ok
  end

  defp stub_sonarr(chosen_episode_has_file: chosen_episode_has_file) do
    test = self()

    series = %{
      "id" => @sonarr_series_id,
      "tmdbId" => String.to_integer(@tmdb_id),
      "monitored" => false,
      "seriesType" => "standard",
      "genres" => ["Drama"]
    }

    Req.Test.stub(Sonarr, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/series"} ->
          Req.Test.json(conn, [series])

        {"GET", "/api/v3/series/7"} ->
          Req.Test.json(conn, series)

        {"PUT", "/api/v3/series/7"} ->
          Req.Test.json(conn, %{series | "monitored" => true})

        {"GET", "/api/v3/episode"} ->
          Req.Test.json(conn, [
            episode(@chosen_episode_id, 1, monitored: true, has_file: chosen_episode_has_file),
            episode(@next_episode_id, 2, monitored: true, has_file: false)
          ])

        {"PUT", "/api/v3/episode/monitor"} ->
          Req.Test.json(conn, [])

        {"POST", "/api/v3/command"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"name" => "EpisodeSearch", "episodeIds" => episode_ids} = Jason.decode!(body)
          send(test, {:sonarr, :search, episode_ids})
          Req.Test.json(conn, %{"id" => 1, "status" => "queued"})
      end
    end)
  end

  defp episode(id, number, monitored: monitored, has_file: has_file) do
    %{
      "id" => id,
      "seasonNumber" => 1,
      "episodeNumber" => number,
      "monitored" => monitored,
      "hasFile" => has_file,
      "airDate" => "2014-04-15"
    }
  end
end
