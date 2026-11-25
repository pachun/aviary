defmodule Aviary.CatalogTest do
  use ExUnit.Case, async: false

  alias Aviary.Catalog

  @viewer %{id: "catalog-viewer", token: "viewer-token"}

  setup do
    Aviary.Cache.invalidate({:jellyfin_list_movies, @viewer.id})
    Aviary.Cache.invalidate_match({:jellyseerr_get_movie, :_})
    Req.Test.stub(Aviary.Jellyfin, &Req.Test.json(&1, %{"Items" => []}))
    Req.Test.stub(Aviary.RottenTomatoes, &Plug.Conn.send_resp(&1, 404, ""))
    :ok
  end

  describe "a movie that isn't on the server yet" do
    test "carries its US age rating" do
      stub_movie(
        us: [
          %{"type" => 1, "certification" => ""},
          %{"type" => 3, "certification" => "PG-13"},
          %{"type" => 4, "certification" => ""}
        ],
        elsewhere: [%{"type" => 3, "certification" => "12A"}]
      )

      assert {:ok, %{official_rating: "PG-13"}} = Catalog.get_movie("1101383", @viewer)
    end

    test "goes without one when no US release gives an age rating" do
      stub_movie(us: [%{"type" => 3, "certification" => ""}], elsewhere: [])

      assert {:ok, %{official_rating: nil}} = Catalog.get_movie("1101383", @viewer)
    end
  end

  defp stub_movie(release_dates) do
    Req.Test.stub(Aviary.Jellyseerr, fn conn ->
      Req.Test.json(conn, %{
        "id" => 1_101_383,
        "title" => "The End of Oak Street",
        "releaseDate" => "2026-08-14",
        "releases" => %{
          "results" => [
            %{"iso_3166_1" => "GB", "release_dates" => Keyword.fetch!(release_dates, :elsewhere)},
            %{"iso_3166_1" => "US", "release_dates" => Keyword.fetch!(release_dates, :us)}
          ]
        }
      })
    end)
  end
end
