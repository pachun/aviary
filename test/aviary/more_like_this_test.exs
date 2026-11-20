defmodule Aviary.MoreLikeThisTest do
  use ExUnit.Case, async: false

  alias Aviary.MoreLikeThis

  setup :set_req_test_to_shared

  setup do
    Aviary.Cache.invalidate_match({:jellyseerr_recommendations, :_, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_get_tv, :_})
    Aviary.Repo.delete_all(Aviary.MoreLikeThis.Row)
    :ets.delete_all_objects(:rotten_tomatoes_cache)
    :ok
  end

  describe "the row Claude chooses" do
    test "lists Claude's picks in its order, with TMDB's artwork" do
      stub_claude_picks([%{title: "Ted Lasso", year: 2020}, %{title: "Shrinking", year: 2023}])
      stub_tmdb(stick(), [ted_lasso(), shrinking()])
      stub_unrated()

      assert [
               %{kind: :show, detail_id: 97546, title: "Ted Lasso", year: 2020},
               %{
                 kind: :show,
                 detail_id: 136_315,
                 title: "Shrinking",
                 thumbnail_url: "/image/tmdb/w780/s.jpg"
               }
             ] = MoreLikeThis.fetch(:show, 248_830)
    end

    test "tells Claude what the title is about" do
      test_process = self()

      Req.Test.stub(Aviary.Claude, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_process, {:asked, Jason.decode!(body)})
        Req.Test.json(conn, claude_answer([%{title: "Ted Lasso", year: 2020}]))
      end)

      stub_tmdb(stick(), [ted_lasso()])
      stub_unrated()

      MoreLikeThis.fetch(:show, 248_830)

      assert_received {:asked, %{"messages" => [%{"content" => question}]}}

      assert %{
               "kind" => "show",
               "title" => "Stick",
               "year" => 2025,
               "synopsis" => "A washed-up golfer mentors a teenage phenom.",
               "genres" => ["Comedy"],
               "networks" => ["Apple TV"]
             } = Jason.decode!(question)
    end

    test "leaves out a pick the critics panned" do
      stub_claude_picks([%{title: "Ted Lasso", year: 2020}, %{title: "Shrinking", year: 2023}])
      stub_tmdb(stick(), [ted_lasso(), shrinking()])
      stub_critic_scores(%{"ted_lasso" => 90, "shrinking" => 41})

      assert [%{title: "Ted Lasso", rating: %{critic: 90}}] = MoreLikeThis.fetch(:show, 248_830)
    end

    test "picks the listing from the year Claude named when titles repeat" do
      remake = %{ted_lasso() | "id" => 1, "firstAirDate" => "1988-01-01"}

      stub_claude_picks([%{title: "Ted Lasso", year: 2020}])
      stub_tmdb(stick(), [remake, ted_lasso()])
      stub_unrated()

      assert [%{detail_id: 97546}] = MoreLikeThis.fetch(:show, 248_830)
    end

    test "never lists the title itself" do
      stub_claude_picks([%{title: "Stick", year: 2025}, %{title: "Ted Lasso", year: 2020}])
      stub_tmdb(stick(), [Map.put(stick(), "mediaType", "tv"), ted_lasso()])
      stub_unrated()

      assert [%{title: "Ted Lasso"}] = MoreLikeThis.fetch(:show, 248_830)
    end

    test "asks Claude once and keeps the row for later visits" do
      test_process = self()

      Req.Test.stub(Aviary.Claude, fn conn ->
        send(test_process, :asked_claude)
        Req.Test.json(conn, claude_answer([%{title: "Ted Lasso", year: 2020}]))
      end)

      stub_tmdb(stick(), [ted_lasso()])
      stub_critic_scores(%{"ted_lasso" => 90})

      first_visit = MoreLikeThis.fetch(:show, 248_830)
      later_visit = MoreLikeThis.fetch(:show, "248830")

      assert later_visit == first_visit

      assert [%{kind: :show, title: "Ted Lasso", rating: %{critic: 90, audience: 90}}] =
               later_visit

      assert_received :asked_claude
      refute_received :asked_claude
    end

    test "falls back to TMDB's recommendations when Claude can't be asked" do
      Req.Test.stub(Aviary.Claude, &Plug.Conn.send_resp(&1, 529, ""))
      stub_tmdb(stick(), [], recommended: [shrinking()])
      stub_unrated()

      assert [%{title: "Shrinking"}] = MoreLikeThis.fetch(:show, 248_830)
      assert Aviary.Repo.aggregate(Aviary.MoreLikeThis.Row, :count) == 0
    end
  end

  defp stick do
    %{
      "id" => 248_830,
      "name" => "Stick",
      "firstAirDate" => "2025-06-03",
      "overview" => "A washed-up golfer mentors a teenage phenom.",
      "genres" => [%{"name" => "Comedy"}],
      "networks" => [%{"name" => "Apple TV"}],
      "backdropPath" => "/k.jpg"
    }
  end

  defp ted_lasso do
    %{
      "id" => 97546,
      "mediaType" => "tv",
      "name" => "Ted Lasso",
      "firstAirDate" => "2020-08-14",
      "backdropPath" => "/t.jpg"
    }
  end

  defp shrinking do
    %{
      "id" => 136_315,
      "mediaType" => "tv",
      "name" => "Shrinking",
      "firstAirDate" => "2023-01-26",
      "backdropPath" => "/s.jpg"
    }
  end

  defp stub_claude_picks(picks) do
    Req.Test.stub(Aviary.Claude, &Req.Test.json(&1, claude_answer(picks)))
  end

  defp claude_answer(picks) do
    %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => Jason.encode!(%{picks: picks})}]
    }
  end

  defp stub_tmdb(source, listings, options \\ []) do
    Req.Test.stub(Aviary.Jellyseerr, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.path_info do
        ["api", "v1", "tv", _tmdb_id] ->
          Req.Test.json(conn, source)

        ["api", "v1", "tv", _tmdb_id, "recommendations"] ->
          Req.Test.json(conn, %{"results" => Keyword.get(options, :recommended, [])})

        ["api", "v1", "search"] ->
          searched_for = conn.query_params["query"]

          Req.Test.json(conn, %{"results" => Enum.filter(listings, &(&1["name"] == searched_for))})
      end
    end)
  end

  defp stub_unrated do
    Req.Test.stub(Aviary.RottenTomatoes, &Plug.Conn.send_resp(&1, 404, ""))
  end

  defp stub_critic_scores(scores) do
    Req.Test.stub(Aviary.RottenTomatoes, fn conn ->
      case scores[List.last(conn.path_info)] do
        nil ->
          Plug.Conn.send_resp(conn, 404, "")

        score ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s|{"audienceScore":{"score":"#{score}"},"criticsScore":{"score":"#{score}"}}|
          )
      end
    end)
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  test "is empty on a server that can't add titles" do
    for setting <- [:sonarr_url, :radarr_url] do
      address = Application.get_env(:aviary, setting)
      Application.delete_env(:aviary, setting)
      on_exit(fn -> Application.put_env(:aviary, setting, address) end)
    end

    assert Aviary.MoreLikeThis.fetch(:movie, "45745") == []
  end

  test "lists what TMDB recommends alongside a show, in its order" do
    stub_recommendations("/api/v1/tv/95396/recommendations", [
      %{
        "id" => 91962,
        "name" => "Emergence",
        "firstAirDate" => "2019-09-24",
        "backdropPath" => "/e.jpg"
      },
      %{
        "id" => 63639,
        "name" => "The Expanse",
        "firstAirDate" => "2015-12-14",
        "backdropPath" => "/x.jpg"
      }
    ])

    assert [
             %{
               kind: :show,
               detail_id: 91962,
               title: "Emergence",
               year: 2019,
               thumbnail_url: "/image/tmdb/w780/e.jpg"
             },
             %{kind: :show, detail_id: 63639, title: "The Expanse", year: 2015}
           ] = MoreLikeThis.related(:show, "95396")
  end

  test "lists what TMDB recommends alongside a movie" do
    stub_recommendations("/api/v1/movie/603/recommendations", [
      %{
        "id" => 604,
        "title" => "The Matrix Reloaded",
        "releaseDate" => "2003-05-15",
        "backdropPath" => "/r.jpg"
      }
    ])

    assert [%{kind: :movie, detail_id: 604, title: "The Matrix Reloaded", year: 2003}] =
             MoreLikeThis.related(:movie, 603)
  end

  test "opens a title already in the library by its Jellyfin id" do
    stub_recommendations("/api/v1/tv/95396/recommendations", [
      %{
        "id" => 63639,
        "name" => "The Expanse",
        "backdropPath" => "/x.jpg",
        "mediaInfo" => %{"jellyfinMediaId" => "abc123"}
      }
    ])

    assert [%{detail_id: "abc123"}] = MoreLikeThis.related(:show, "95396")
  end

  test "leaves out a title with no artwork to show" do
    stub_recommendations("/api/v1/tv/95396/recommendations", [
      %{"id" => 1, "name" => "No Art", "backdropPath" => nil},
      %{"id" => 2, "name" => "Has Art", "backdropPath" => "/a.jpg"}
    ])

    assert [%{title: "Has Art"}] = MoreLikeThis.related(:show, "95396")
  end

  test "is empty when TMDB can't be reached or the title has no TMDB id" do
    Req.Test.stub(Aviary.Jellyseerr, &Plug.Conn.send_resp(&1, 502, ""))

    assert MoreLikeThis.related(:show, "95396") == []
    assert MoreLikeThis.related(:show, nil) == []
  end

  defp stub_recommendations(path, results) do
    Req.Test.stub(Aviary.Jellyseerr, fn %{request_path: ^path} = conn ->
      Req.Test.json(conn, %{"page" => 1, "results" => results})
    end)
  end
end
