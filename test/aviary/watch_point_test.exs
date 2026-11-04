defmodule Aviary.WatchPointTest do
  use ExUnit.Case, async: true

  @user %{id: "0123456789abcdef0123456789abcdef", token: "watch-point-token"}

  setup do
    test_process = self()

    Req.Test.stub(Aviary.Jellyfin, fn conn ->
      send(test_process, {:jellyfin, conn.method, conn.request_path})
      Req.Test.json(conn, %{})
    end)

    :ok
  end

  defp episode(id), do: %{id: id}

  defp show(tmdb_id \\ nil) do
    %{
      tmdb_id: tmdb_id,
      episodes_by_season: [
        {1, [episode("s1e1"), episode("s1e2"), episode("tmdb-s1e3")]},
        {2, [episode("s2e1")]}
      ]
    }
  end

  test "episodes through the chosen one become watched and later ones unwatched" do
    assert :ok = Aviary.WatchPoint.set(show(), "s1e2", @user)

    assert_received {:jellyfin, "POST", "/UserPlayedItems/s1e1"}
    assert_received {:jellyfin, "POST", "/UserPlayedItems/s1e2"}
    assert_received {:jellyfin, "DELETE", "/UserPlayedItems/s2e1"}
  end

  test "episodes Jellyfin does not have are left alone" do
    assert :ok = Aviary.WatchPoint.set(show(), "s2e1", @user)

    refute_received {:jellyfin, _, "/UserPlayedItems/tmdb-s1e3"}
  end

  test "an episode the show does not contain changes nothing" do
    assert :error = Aviary.WatchPoint.set(show(), "missing", @user)

    refute_received {:jellyfin, _, _}
  end

  test "setting a watch point adds the show to the user's library" do
    tmdb_id = "watch-point-#{System.unique_integer([:positive])}"

    assert :ok = Aviary.WatchPoint.set(show(tmdb_id), "s1e1", @user)

    assert Aviary.Library.member?(@user.id, tmdb_id)
  end
end
