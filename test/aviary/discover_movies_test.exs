defmodule Aviary.DiscoverMoviesTest do
  use ExUnit.Case, async: false

  alias Aviary.DiscoverMovies

  @today ~D[2026-11-24]
  @viewer %{id: "viewer", token: "viewer-token"}

  setup :set_req_test_to_shared

  setup do
    Aviary.Cache.invalidate_match({:jellyseerr_discover_movies, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_get_movie, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_recommendations, :_, :_})
    Aviary.Cache.invalidate({:jellyfin_recently_watched, @viewer.id})
    :ets.delete_all_objects(:rotten_tomatoes_cache)
    :ok
  end

  describe "the newly released row" do
    test "lists movies that came out at home in the last three months, most popular first" do
      stub_jellyseerr(
        discovered: [
          movie(1, "Heart of the Beast", 317),
          movie(2, "The Odyssey", 411),
          movie(3, "Hope", 202)
        ],
        home_releases: %{1 => ~D[2026-11-03], 2 => ~D[2026-11-17], 3 => ~D[2026-06-01]}
      )

      stub_ratings(%{
        "heart_of_the_beast" => {88, 91},
        "the_odyssey" => {79, 84},
        "hope" => {90, 90}
      })

      assert titles(DiscoverMovies.fetch_row(:newly_released, @today)) == [
               "The Odyssey",
               "Heart of the Beast"
             ]
    end

    test "leaves out a movie that is only in theaters, even with a pre-order listed" do
      stub_jellyseerr(
        discovered: [movie(4, "Sunrise on the Reaping", 379), movie(5, "Guarding Stars", 167)],
        home_releases: %{5 => ~D[2026-11-18]},
        theatrical_only: [4]
      )

      stub_ratings(%{"sunrise_on_the_reaping" => {80, 95}, "guarding_stars" => {70, 75}})

      assert titles(DiscoverMovies.fetch_row(:newly_released, @today)) == ["Guarding Stars"]
    end
  end

  test "every row leaves out a movie that critics or audiences rate below 60" do
    stub_jellyseerr(
      discovered: [
        movie(6, "Crowd Pleaser", 300),
        movie(7, "Critics Darling", 250),
        movie(8, "Well Liked", 200),
        movie(9, "Unrated", 150)
      ],
      home_releases: %{
        6 => ~D[2026-11-01],
        7 => ~D[2026-11-01],
        8 => ~D[2026-11-01],
        9 => ~D[2026-11-01]
      }
    )

    stub_ratings(%{
      "crowd_pleaser" => {45, 92},
      "critics_darling" => {96, 59},
      "well_liked" => {60, 60}
    })

    assert titles(DiscoverMovies.fetch_row(:newly_released, @today)) == ["Well Liked"]
  end

  test "the best of the last year row ranks movies by their Rotten Tomatoes scores" do
    stub_jellyseerr(
      discovered: [
        movie(10, "Good Enough", 400),
        movie(11, "Masterpiece", 50),
        movie(12, "Very Good", 120)
      ],
      home_releases: %{10 => ~D[2026-03-01], 11 => ~D[2026-01-15], 12 => ~D[2026-08-09]}
    )

    stub_ratings(%{
      "good_enough" => {70, 72},
      "masterpiece" => {98, 95},
      "very_good" => {88, 85}
    })

    assert titles(DiscoverMovies.fetch_row(:best_of_the_last_year, @today)) == [
             "Masterpiece",
             "Very Good",
             "Good Enough"
           ]
  end

  describe "rows/1" do
    test "follows the two headline rows with picks for the movie you watched last" do
      stub_jellyfin_recently_watched([
        %{"Type" => "Episode", "Name" => "Pilot", "ProviderIds" => %{"Tmdb" => "999"}},
        %{"Type" => "Movie", "Name" => "Brooklyn", "ProviderIds" => %{"Tmdb" => "167073"}}
      ])

      assert [
               {"Newly released", :newly_released},
               {"Best of the last year", :best_of_the_last_year},
               {"Because you watched Brooklyn", {:because_you_watched, "167073"}}
               | genre_rows
             ] = DiscoverMovies.rows(@viewer)

      assert Enum.map(genre_rows, &elem(&1, 0)) == [
               "Action",
               "Comedy",
               "Drama",
               "Thriller",
               "Science fiction",
               "Animation"
             ]
    end

    test "goes straight to the genre rows for someone who hasn't watched a movie" do
      stub_jellyfin_recently_watched([])

      assert [
               {"Newly released", _},
               {"Best of the last year", _},
               {"Action", {:genre, _}} | _
             ] = DiscoverMovies.rows(@viewer)
    end
  end

  test "picks for the movie you watched last only include movies you can get at home" do
    stub_jellyseerr(
      recommended: %{
        "167073" => [movie(13, "Carol", 80), movie(14, "Still in Theaters", 90)]
      },
      home_releases: %{13 => ~D[2016-03-15]},
      theatrical_only: [14]
    )

    stub_ratings(%{"carol" => {94, 70}, "still_in_theaters" => {90, 90}})

    assert titles(DiscoverMovies.fetch_row({:because_you_watched, "167073"}, @today)) == [
             "Carol"
           ]
  end

  test "a genre row asks for movies in that genre you can watch at home" do
    stub_jellyseerr(
      discovered: [movie(15, "Big Laughs", 140)],
      home_releases: %{15 => ~D[2025-04-01]},
      expect_genre: "35"
    )

    stub_ratings(%{"big_laughs" => {81, 77}})

    assert [%{title: "Big Laughs", kind: :movie, rating: %{critic: 81, audience: 77}}] =
             DiscoverMovies.fetch_row({:genre, 35}, @today)
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp titles(items), do: Enum.map(items, & &1.title)

  defp movie(id, title, popularity) do
    %{
      "id" => id,
      "title" => title,
      "releaseDate" => "2026-07-15",
      "popularity" => popularity,
      "backdropPath" => "/#{id}.jpg"
    }
  end

  defp stub_jellyseerr(opts) do
    discovered = Keyword.get(opts, :discovered, [])
    recommended = Keyword.get(opts, :recommended, %{})
    home_releases = Keyword.get(opts, :home_releases, %{})
    theatrical_only = Keyword.get(opts, :theatrical_only, [])
    expected_genre = Keyword.get(opts, :expect_genre)

    Req.Test.stub(Aviary.Jellyseerr, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case String.split(conn.request_path, "/", trim: true) do
        ["api", "v1", "discover", "movies"] ->
          assert conn.query_params["watchRegion"] == "US"
          if expected_genre, do: assert(conn.query_params["genre"] == expected_genre)
          results = if conn.query_params["page"] in [nil, "1"], do: discovered, else: []
          Req.Test.json(conn, %{"results" => results})

        ["api", "v1", "movie", id, "recommendations"] ->
          Req.Test.json(conn, %{"results" => Map.get(recommended, id, [])})

        ["api", "v1", "movie", id] ->
          id = String.to_integer(id)

          release_dates =
            case Map.fetch(home_releases, id) do
              {:ok, date} ->
                [
                  %{"type" => 3, "release_date" => "2026-07-17T00:00:00.000Z"},
                  %{"type" => 4, "release_date" => Date.to_iso8601(date) <> "T00:00:00.000Z"}
                ]

              :error ->
                if id in theatrical_only,
                  do: [%{"type" => 3, "release_date" => "2026-11-20T00:00:00.000Z"}],
                  else: []
            end

          Req.Test.json(conn, %{
            "id" => id,
            "releases" => %{
              "results" => [%{"iso_3166_1" => "US", "release_dates" => release_dates}]
            }
          })
      end
    end)
  end

  defp stub_ratings(scores_by_slug) do
    Req.Test.stub(Aviary.RottenTomatoes, fn conn ->
      slug = conn.request_path |> String.split("/") |> List.last()

      case Map.fetch(scores_by_slug, slug) do
        {:ok, {critic, audience}} ->
          Req.Test.html(
            conn,
            ~s|{"audienceScore":{"score":"#{audience}"},"criticsScore":{"score":"#{critic}"}}|
          )

        :error ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp stub_jellyfin_recently_watched(items) do
    Req.Test.stub(Aviary.Jellyfin, fn conn ->
      Req.Test.json(conn, %{"Items" => items})
    end)
  end
end
