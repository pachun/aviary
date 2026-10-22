defmodule Aviary.ImportNudgeTest do
  use ExUnit.Case, async: false

  alias Aviary.{ImportNudge, Jellyfin}

  setup :set_req_test_to_shared

  describe "episode_landed/2" do
    test "refreshes the series when Jellyfin already lists the show" do
      stub_jellyfin(series: [%{"Id" => "series-known", "ProviderIds" => %{"Tmdb" => "42009"}}])

      ImportNudge.episode_landed("42009")

      assert_received {:jellyfin, :refreshed_series, "series-known"}
      refute_received {:jellyfin, :library_scan}
    end

    test "asks for one library scan when Jellyfin has never seen the show" do
      stub_jellyfin(series: [])

      ImportNudge.episode_landed("42009")

      assert_received {:jellyfin, :library_scan}
      refute_received {:jellyfin, :refreshed_series, _}
    end

    test "scans the library when the import carries no show id at all" do
      stub_jellyfin(series: [])

      ImportNudge.episode_landed(nil)

      assert_received {:jellyfin, :library_scan}
    end

    test "waits for a running scan to finish rather than restarting it" do
      stub_jellyfin(series: [], scan_states: in_order(["Running", "Running", "Idle"]))

      ImportNudge.episode_landed("42009", busy_scan_retry_ms: 1)

      assert_received {:jellyfin, :library_scan}
      assert_received {:jellyfin, :asked_whether_scanning}
      assert_received {:jellyfin, :asked_whether_scanning}
      assert_received {:jellyfin, :asked_whether_scanning}
    end

    test "leaves the import to Jellyfin's own scan without an API key" do
      stub_jellyfin(series: [])
      previous = Application.get_env(:aviary, :jellyfin_api_key)
      Application.put_env(:aviary, :jellyfin_api_key, nil)
      on_exit(fn -> Application.put_env(:aviary, :jellyfin_api_key, previous) end)

      ImportNudge.episode_landed("42009")

      refute_received {:jellyfin, _}
      refute_received {:jellyfin, _, _}
    end
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp stub_jellyfin(options) do
    test = self()
    series = Keyword.fetch!(options, :series)
    scan_states = Keyword.get(options, :scan_states, in_order(["Idle"]))

    Req.Test.stub(Jellyfin, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/Items"} ->
          Req.Test.json(conn, %{"Items" => series})

        {"POST", "/Items/" <> rest} ->
          send(test, {:jellyfin, :refreshed_series, String.trim_trailing(rest, "/Refresh")})
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/ScheduledTasks"} ->
          send(test, {:jellyfin, :asked_whether_scanning})
          Req.Test.json(conn, [%{"Key" => "RefreshLibrary", "State" => scan_states.()}])

        {"POST", "/Library/Refresh"} ->
          send(test, {:jellyfin, :library_scan})
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)
  end

  defp in_order(responses) do
    {:ok, remaining} = Agent.start_link(fn -> responses end)

    fn ->
      Agent.get_and_update(remaining, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end
  end
end
