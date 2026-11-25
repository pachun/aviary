defmodule AviaryWeb.DiscoverControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias AviaryWeb.API.DiscoverController

  @viewer %{id: "viewer", token: "viewer-token"}

  setup do
    Aviary.Cache.invalidate_match({:jellyseerr_discover_movies, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_get_movie, :_})
    Aviary.Cache.invalidate({:jellyfin_recently_watched, @viewer.id})
    :ets.delete_all_objects(:rotten_tomatoes_cache)
    :ok
  end

  test "movies lists every row that has something watchable, in order" do
    Req.Test.stub(Aviary.Jellyfin, &Req.Test.json(&1, %{"Items" => []}))

    Req.Test.stub(Aviary.Jellyseerr, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/api/v1/discover/movies" ->
          results =
            if conn.query_params["genre"] == "35" and conn.query_params["page"] == "1",
              do: [
                %{
                  "id" => 15,
                  "title" => "Big Laughs",
                  "releaseDate" => "2025-01-10",
                  "backdropPath" => "/15.jpg"
                }
              ],
              else: []

          Req.Test.json(conn, %{"results" => results})

        "/api/v1/movie/15" ->
          Req.Test.json(conn, %{
            "id" => 15,
            "releases" => %{
              "results" => [
                %{
                  "iso_3166_1" => "US",
                  "release_dates" => [
                    %{"type" => 4, "release_date" => "2025-04-01T00:00:00.000Z"}
                  ]
                }
              ]
            }
          })
      end
    end)

    Req.Test.stub(Aviary.RottenTomatoes, fn conn ->
      Req.Test.html(conn, ~s|{"audienceScore":{"score":"77"},"criticsScore":{"score":"81"}}|)
    end)

    conn =
      build_conn()
      |> assign(:current_user, @viewer)
      |> DiscoverController.movies(%{})

    assert json_response(conn, 200) == %{
             "rows" => [
               %{
                 "label" => "Comedy",
                 "items" => [
                   %{
                     "id" => "15",
                     "kind" => "movie",
                     "title" => "Big Laughs",
                     "image" => "/api/v1/image/tmdb/w780/15.jpg",
                     "rating" => %{"critic" => 81, "audience" => 77}
                   }
                 ]
               }
             ]
           }
  end
end
