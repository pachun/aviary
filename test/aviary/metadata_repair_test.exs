defmodule Aviary.MetadataRepairTest do
  use ExUnit.Case, async: false

  alias Aviary.{Jellyfin, MetadataRepair}

  setup :set_req_test_to_shared

  @auth %{id: :server, token: "jellyfin-test-key"}

  describe "repair_episode/3" do
    test "refetches everything for an episode whose lookup left no provider ids" do
      stub_jellyfin()
      episode = %{"Id" => "ep-bare", "ProviderIds" => %{}, "ImageTags" => %{}}

      assert :ok = MetadataRepair.repair_episode("series-1", episode, @auth)

      assert_received {:jellyfin, :refreshed, "ep-bare", params}
      assert params["ReplaceAllMetadata"] == "true"
      assert params["MetadataRefreshMode"] == "FullRefresh"
      assert params["ReplaceAllImages"] == "true"
    end

    test "refetches only the still for an episode that has ids but no image" do
      stub_jellyfin()
      episode = %{"Id" => "ep-no-still", "ProviderIds" => %{"Tvdb" => "1"}, "ImageTags" => %{}}

      assert :ok = MetadataRepair.repair_episode("series-1", episode, @auth)

      assert_received {:jellyfin, :refreshed, "ep-no-still", params}
      assert params["ReplaceAllMetadata"] == "false"
      assert params["ImageRefreshMode"] == "FullRefresh"
      assert params["ReplaceAllImages"] == "true"
    end
  end

  describe "bare_episode?/1" do
    test "an episode with provider ids and a still is fine" do
      refute MetadataRepair.bare_episode?(%{
               "Id" => "ok",
               "ProviderIds" => %{"Tvdb" => "1"},
               "ImageTags" => %{"Primary" => "abc"}
             })
    end

    test "an episode nobody asked provider ids for is unknown, not bare" do
      refute MetadataRepair.bare_episode?(%{"Id" => "unasked", "Name" => "Pilot"})
    end

    test "null provider ids count as none" do
      assert MetadataRepair.bare_episode?(%{"Id" => "x", "ProviderIds" => nil})
    end
  end

  describe "episodes_listed/2" do
    test "sends each bare episode back to Jellyfin once a day" do
      stub_jellyfin()
      id = unique("ep")

      listing = [
        %{"Id" => id, "ProviderIds" => %{}, "ImageTags" => %{}},
        %{
          "Id" => unique("fine"),
          "ProviderIds" => %{"Tvdb" => "2"},
          "ImageTags" => %{"Primary" => "t"}
        }
      ]

      MetadataRepair.episodes_listed("series-2", listing)
      assert_receive {:jellyfin, :refreshed, ^id, _}, 1_000

      MetadataRepair.episodes_listed("series-2", listing)
      refute_receive {:jellyfin, :refreshed, ^id, _}, 200
      await_repairs()
    end

    test "does nothing without a Jellyfin API key" do
      stub_jellyfin()
      previous = Application.get_env(:aviary, :jellyfin_api_key)
      Application.put_env(:aviary, :jellyfin_api_key, nil)
      on_exit(fn -> Application.put_env(:aviary, :jellyfin_api_key, previous) end)

      MetadataRepair.episodes_listed("series-3", [%{"Id" => unique("ep"), "ProviderIds" => %{}}])

      refute_receive {:jellyfin, _, _, _}, 200
    end
  end

  describe "identify_series/2" do
    test "applies the candidate with the exact title and rebuilds the series" do
      stub_jellyfin(
        candidates: [
          %{"Name" => "Grey's Anatomy: B-Team", "ProviderIds" => %{"Tmdb" => "79897"}},
          %{"Name" => "grey's anatomy", "ProviderIds" => %{"Tmdb" => "1416"}}
        ]
      )

      series = %{
        "Id" => "series-greys",
        "Type" => "Series",
        "Name" => "Grey's Anatomy",
        "ProviderIds" => %{}
      }

      assert :identified = MetadataRepair.identify_series(series, @auth)

      assert_received {:jellyfin, :searched, "Grey's Anatomy"}
      assert_received {:jellyfin, :identified, "series-greys", %{"Tmdb" => "1416"}}

      assert_received {:jellyfin, :refreshed, "series-greys",
                       %{"ReplaceAllMetadata" => "true", "Recursive" => "true"}}
    end

    test "leaves a series alone when nothing matches its title exactly" do
      stub_jellyfin(
        candidates: [%{"Name" => "Community Squad", "ProviderIds" => %{"Tmdb" => "219066"}}]
      )

      series = %{
        "Id" => "series-community",
        "Type" => "Series",
        "Name" => "Community",
        "ProviderIds" => %{}
      }

      assert :no_match = MetadataRepair.identify_series(series, @auth)

      refute_received {:jellyfin, :identified, _, _}
      refute_received {:jellyfin, :refreshed, _, _}
    end
  end

  describe "through Jellyfin reads" do
    test "listing a series' episodes asks for provider ids and repairs the bare ones" do
      id = unique("ep")
      stub_jellyfin(episodes: [%{"Id" => id, "ProviderIds" => %{}, "ImageTags" => %{}}])

      assert [%{"Id" => ^id}] =
               Jellyfin.list_episodes(unique("series"), %{id: "user", token: "t"})

      assert_received {:jellyfin, :listed_episodes, fields}
      assert fields =~ "ProviderIds"
      assert_receive {:jellyfin, :refreshed, ^id, _}, 1_000
      await_repairs()
    end

    test "listing shows identifies the ones Jellyfin never matched" do
      id = unique("series")

      stub_jellyfin(
        series: [%{"Id" => id, "Type" => "Series", "Name" => "New Girl", "ProviderIds" => %{}}],
        candidates: [%{"Name" => "New Girl", "ProviderIds" => %{"Tmdb" => "1420"}}]
      )

      Jellyfin.list_shows(%{id: unique("user"), token: "t"})

      assert_receive {:jellyfin, :identified, ^id, %{"Tmdb" => "1420"}}, 1_000
      await_repairs()
    end
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp unique(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  # The stub belongs to this test process; a repair still running after
  # the test ends would find no stub and crash Req.Test's ownership.
  defp await_repairs do
    case Task.Supervisor.children(Aviary.TaskSupervisor) do
      [] ->
        :ok

      repairs ->
        Enum.each(repairs, fn pid ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
          after
            1_000 -> :ok
          end
        end)

        await_repairs()
    end
  end

  defp stub_jellyfin(options \\ []) do
    test = self()
    candidates = Keyword.get(options, :candidates, [])
    episodes = Keyword.get(options, :episodes, [])
    series = Keyword.get(options, :series, [])

    Req.Test.stub(Jellyfin, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/Items/RemoteSearch/Series"} ->
          send(test, {:jellyfin, :searched, read_json(conn)["SearchInfo"]["Name"]})
          Req.Test.json(conn, candidates)

        {"POST", "/Items/RemoteSearch/Apply/" <> id} ->
          send(test, {:jellyfin, :identified, id, read_json(conn)["ProviderIds"]})
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/Items/" <> rest} ->
          send(
            test,
            {:jellyfin, :refreshed, String.trim_trailing(rest, "/Refresh"), conn.query_params}
          )

          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/Shows/" <> _} ->
          send(test, {:jellyfin, :listed_episodes, conn.query_params["Fields"]})
          Req.Test.json(conn, %{"Items" => episodes})

        {"GET", "/Items"} ->
          Req.Test.json(conn, %{"Items" => series})
      end
    end)
  end

  defp read_json(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end
end
