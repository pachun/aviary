defmodule Aviary.MoreLikeThisTest do
  use ExUnit.Case, async: false

  alias Aviary.MoreLikeThis

  setup do
    Aviary.Cache.invalidate_match({:jellyseerr_recommendations, :_, :_})
    :ok
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
