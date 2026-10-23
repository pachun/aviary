defmodule Aviary.DiscoverTest do
  use ExUnit.Case, async: false

  alias Aviary.Discover

  @today ~D[2026-10-22]

  setup :set_req_test_to_shared

  setup do
    Aviary.Cache.invalidate_match({:jellyseerr_discover_tv_network, :_, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_discover_tv_premieres, :_, :_})
    Aviary.Cache.invalidate_match({:jellyseerr_get_tv, :_})
    :ok
  end

  describe "rank/2" do
    test "leads with shows that aired an episode recently, most popular first" do
      ranked =
        Discover.rank(
          [
            candidate("Game of Thrones", 210, last_aired: ~D[2019-05-19]),
            candidate("Lanterns", 92, last_aired: ~D[2026-10-19]),
            candidate("The Sopranos", 145, last_aired: ~D[2007-06-10]),
            candidate("House of the Dragon", 126, last_aired: ~D[2026-09-30])
          ],
          @today
        )

      assert titles(ranked) == [
               "House of the Dragon",
               "Lanterns",
               "Game of Thrones",
               "The Sopranos"
             ]
    end

    test "counts a season starting within the month as airing now" do
      ranked =
        Discover.rank(
          [
            candidate("Reacher", 344, last_aired: ~D[2025-03-27]),
            candidate("Harry Potter", 13, next_airs: ~D[2026-11-15])
          ],
          @today
        )

      assert titles(ranked) == ["Harry Potter", "Reacher"]
    end

    test "treats a season that ended months ago as catalog" do
      ranked =
        Discover.rank(
          [
            candidate("The Bear", 999, last_aired: ~D[2026-06-25]),
            candidate("Only Murders in the Building", 52, last_aired: ~D[2026-10-14])
          ],
          @today
        )

      assert titles(ranked) == ["Only Murders in the Building", "The Bear"]
    end

    test "leaves a far-off premiere in the catalog tier" do
      ranked =
        Discover.rank(
          [
            candidate("The Land", 3, next_airs: ~D[2027-02-15]),
            candidate("King of the Hill", 116)
          ],
          @today
        )

      assert titles(ranked) == ["King of the Hill", "The Land"]
    end
  end

  describe "ranked_shows/2" do
    test "draws on every network and this season's premieres without repeats" do
      stub_jellyseerr(
        popular: %{
          {49, 1} => [show(1, "Game of Thrones", 210), show(2, "Sesame Street", 140)],
          {49, 2} => [show(3, "Oz", 55)],
          {3186, 1} => [show(2, "Sesame Street", 145), show(4, "Hacks", 62)],
          {3186, 2} => []
        },
        premieres: %{49 => [show(5, "Lanterns", 92)], 3186 => []},
        details: %{5 => %{"lastEpisodeToAir" => %{"airDate" => "2026-10-19"}}}
      )

      ranked = Discover.ranked_shows([49, 3186], @today)

      assert Enum.map(ranked, & &1["name"]) == [
               "Lanterns",
               "Game of Thrones",
               "Sesame Street",
               "Hacks",
               "Oz"
             ]
    end

    test "skips shows without a backdrop" do
      stub_jellyseerr(
        popular: %{
          {7, 1} => [show(8, "Nameless", 50) |> Map.put("backdropPath", nil)],
          {7, 2} => []
        },
        premieres: %{7 => []},
        details: %{}
      )

      assert Discover.ranked_shows([7], @today) == []
    end
  end

  defp candidate(name, popularity, dates \\ []) do
    %{
      show: show(name, name, popularity),
      popularity: popularity,
      last_aired: dates[:last_aired],
      next_airs: dates[:next_airs]
    }
  end

  defp show(id, name, popularity) do
    %{"id" => id, "name" => name, "popularity" => popularity, "backdropPath" => "/#{id}.jpg"}
  end

  defp titles(ranked), do: Enum.map(ranked, & &1.show["name"])

  defp stub_jellyseerr(popular: popular, premieres: premieres, details: details) do
    Req.Test.stub(Aviary.Jellyseerr, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.path_info do
        ["api", "v1", "discover", "tv", "network", network_id] ->
          page = String.to_integer(conn.query_params["page"])
          key = {String.to_integer(network_id), page}
          Req.Test.json(conn, %{"results" => Map.fetch!(popular, key)})

        ["api", "v1", "discover", "tv"] ->
          network_id = String.to_integer(conn.query_params["network"])
          Req.Test.json(conn, %{"results" => Map.fetch!(premieres, network_id)})

        ["api", "v1", "tv", tmdb_id] ->
          Req.Test.json(conn, Map.get(details, String.to_integer(tmdb_id), %{}))
      end
    end)
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)
end
