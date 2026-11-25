defmodule Aviary.DownloadStateTest do
  use ExUnit.Case, async: true

  alias Aviary.DownloadState

  describe "a download that failed" do
    test "reads as searching while Sonarr is still deciding what to do with it" do
      record = %{
        "status" => "completed",
        "trackedDownloadState" => "failedPending",
        "size" => 5_000,
        "sizeleft" => 0
      }

      assert DownloadState.queue_record_state(record) == :searching
    end

    test "reads as searching when the download client reports the failure" do
      record = %{"status" => "failed", "size" => 5_000, "sizeleft" => 0}

      assert DownloadState.queue_record_state(record) == :searching
    end
  end

  test "a finished download waiting to be imported reads as imported" do
    record = %{
      "status" => "completed",
      "trackedDownloadState" => "importPending",
      "size" => 5_000,
      "sizeleft" => 0
    }

    assert DownloadState.queue_record_state(record) == :imported
  end

  describe "a show's episode" do
    test "shows the progress of a download Sonarr has even when the episode is unmonitored" do
      status = %{
        episodes: %{
          {1, 1} => %{id: 15252, monitored: false, has_file: false, air_date: "2015-08-28"}
        },
        queue: [%{"episodeId" => 15252, "size" => 1_000, "sizeleft" => 580}]
      }

      assert DownloadState.episode_state(1, 1, status) == {:downloading, 42}
    end

    test "reads as searching while Sonarr is still setting the show up" do
      status = %{
        being_added: true,
        episodes: %{
          {1, 1} => %{id: 15252, monitored: false, has_file: false, air_date: "2015-08-28"}
        },
        queue: []
      }

      assert DownloadState.show_overall(status) == :searching
    end

    test "reads as searching before Sonarr has listed any episodes for a new show" do
      assert DownloadState.show_overall(%{being_added: true, episodes: %{}, queue: []}) ==
               :searching
    end
  end

  describe "a wanted movie with no download in flight" do
    @now ~U[2026-11-23 16:00:00Z]
    @moments_ago "2026-11-23T15:59:30Z"
    @hours_ago "2026-11-23T13:45:00Z"

    test "reads as searching before Radarr has searched for it" do
      assert DownloadState.movie_state(wanted_movie(last_searched_at: nil), @now) == :searching
    end

    test "reads as searching while Radarr's search is still fresh" do
      movie = wanted_movie(last_searched_at: @moments_ago)

      assert DownloadState.movie_state(movie, @now) == :searching
    end

    test "reads as not found once the search has come back empty" do
      movie = wanted_movie(last_searched_at: @hours_ago)

      assert DownloadState.movie_state(movie, @now) == :not_found
    end

    test "reads as unreleased when it hasn't come out for home viewing" do
      movie = wanted_movie(last_searched_at: @hours_ago, released: false)

      assert DownloadState.movie_state(movie, @now) == :unreleased
    end

    test "reads as searching while a grabbed copy is on its way to the library" do
      movie = wanted_movie(last_searched_at: @hours_ago, latest_history_event: "grabbed")

      assert DownloadState.movie_state(movie, @now) == :searching
    end
  end

  test "a downloading movie reads its progress from Radarr's queue" do
    movie = wanted_movie(queue: %{"movieId" => 114, "size" => 1_000, "sizeleft" => 580})

    assert DownloadState.movie_state(movie) == {:downloading, 42}
  end

  defp wanted_movie(overrides) do
    Map.merge(
      %{
        has_file: false,
        monitored: true,
        queue: nil,
        released: true,
        last_searched_at: nil,
        latest_history_event: nil
      },
      Map.new(overrides)
    )
  end
end
