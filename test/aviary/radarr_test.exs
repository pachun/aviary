defmodule Aviary.RadarrTest do
  use ExUnit.Case, async: false

  alias Aviary.Radarr

  @tmdb_id 20_457
  @radarr_movie_id 114

  setup do
    Aviary.Cache.invalidate(:radarr_movie_list)
    on_exit(fn -> Aviary.Cache.invalidate(:radarr_movie_list) end)
  end

  describe "movie_status/1 for a wanted movie nothing is downloading" do
    test "says when Radarr last searched and that the movie is out" do
      stub_radarr(
        movie: %{"status" => "released", "lastSearchTime" => "2026-11-23T13:45:26Z"},
        history: []
      )

      assert {:ok, status} = Radarr.movie_status(@tmdb_id)
      assert status.released
      assert status.last_searched_at == "2026-11-23T13:45:26Z"
      assert status.latest_history_event == nil
    end

    test "says a movie still in theaters isn't out" do
      stub_radarr(movie: %{"status" => "inCinemas"}, history: [])

      assert {:ok, status} = Radarr.movie_status(@tmdb_id)
      refute status.released
    end

    test "names the most recent thing Radarr did with it" do
      stub_radarr(
        movie: %{"status" => "released"},
        history: [
          %{"eventType" => "downloadFailed", "date" => "2026-11-08T10:00:00Z"},
          %{"eventType" => "grabbed", "date" => "2026-11-23T13:45:26Z"}
        ]
      )

      assert {:ok, status} = Radarr.movie_status(@tmdb_id)
      assert status.latest_history_event == "grabbed"
    end
  end

  defp stub_radarr(opts) do
    movie =
      Map.merge(
        %{
          "id" => @radarr_movie_id,
          "tmdbId" => @tmdb_id,
          "monitored" => true,
          "hasFile" => false
        },
        Keyword.fetch!(opts, :movie)
      )

    history = Keyword.fetch!(opts, :history)

    Req.Test.stub(Radarr, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/movie"} -> Req.Test.json(conn, [movie])
        {"GET", "/api/v3/queue"} -> Req.Test.json(conn, %{"records" => []})
        {"GET", "/api/v3/history/movie"} -> Req.Test.json(conn, history)
      end
    end)
  end
end
