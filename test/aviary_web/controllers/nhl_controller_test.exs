defmodule AviaryWeb.NhlControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias AviaryWeb.API.NhlController

  @everything_it_serves [:standings, :teams, :team, :logo, :playlist, :segment]

  describe "a server that defines its own live section" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "aviary-sections-#{System.unique_integer([:positive])}.json")

      File.write!(path, Jason.encode!(%{live: %{label: "Live", events: []}}))
      Application.put_env(:aviary, :sections_file, path)
      Aviary.Cache.invalidate({:sections, path})

      on_exit(fn ->
        File.rm(path)
        Application.delete_env(:aviary, :sections_file)
        Aviary.Cache.invalidate({:sections, path})
      end)
    end

    test "has nothing of the NHL's to serve", %{conn: conn} do
      for served <- @everything_it_serves do
        answer = NhlController.call(conn, NhlController.init(served))

        assert answer.halted
        assert json_response(answer, 404) == %{"error" => "not_found"}
      end
    end
  end

  test "a server on the NHL schedule still answers for its feeds", %{conn: conn} do
    answer = NhlController.call(conn, NhlController.init(:playlist))

    refute answer.halted
    assert answer.status == 401
  end
end
