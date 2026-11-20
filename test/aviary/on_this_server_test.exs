defmodule Aviary.OnThisServerTest do
  use ExUnit.Case, async: false

  alias Aviary.OnThisServer

  @shows [%{"Id" => "show-1", "Name" => "Sherlock Holmes", "ProductionYear" => 1954}]
  @movies [
    %{"Id" => "movie-2", "Name" => "Sintel", "ProductionYear" => 2010},
    %{"Id" => "movie-1", "Name" => "Big Buck Bunny", "ProductionYear" => 2008}
  ]

  describe "all_there_is?/0" do
    test "is false on a server that can add titles" do
      refute OnThisServer.all_there_is?()
    end

    test "is true on a server set up with nothing to add titles with" do
      for setting <- [:sonarr_url, :radarr_url] do
        address = Application.get_env(:aviary, setting)
        Application.delete_env(:aviary, setting)
        on_exit(fn -> Application.put_env(:aviary, setting, address) end)
      end

      assert OnThisServer.all_there_is?()
    end
  end

  describe "rows/2" do
    test "lists every show and movie on the server by title" do
      assert [{"Shows on this server", [show]}, {"Movies on this server", movies}] =
               OnThisServer.rows(@shows, @movies)

      assert show == %{
               kind: :show,
               detail_id: "show-1",
               title: "Sherlock Holmes",
               year: 1954,
               subtitle: nil,
               thumbnail_url: "/image/show-1?kind=backdrop",
               rating: nil
             }

      assert Enum.map(movies, & &1.title) == ["Big Buck Bunny", "Sintel"]
    end

    test "leaves out a kind the server has none of" do
      assert [{"Movies on this server", _}] = OnThisServer.rows([], @movies)
    end
  end

  describe "search/3" do
    test "finds titles containing the query, whatever its case" do
      assert ["Big Buck Bunny"] =
               @shows |> OnThisServer.search(@movies, " bunny ") |> Enum.map(& &1.title)
    end

    test "finds nothing for a title that isn't on the server" do
      assert [] = OnThisServer.search(@shows, @movies, "inception")
    end
  end
end
