defmodule Aviary.NhlTest do
  use ExUnit.Case, async: false

  alias Aviary.Nhl
  alias Aviary.Nhl.Schedule
  alias Aviary.Nhl.Site

  @fixtures Path.expand("../support/fixtures/nhl", __DIR__)
  @signed_playlist "https://cdn.example.test/play/abc/178.m3u8?expires=1"
  @media_playlist "https://media.example.test/auth/178.m3u8?token=media"
  @media_playlist_body """
  #EXTM3U
  #EXT-X-VERSION:3
  #EXT-X-TARGETDURATION:5
  #EXT-X-KEY:METHOD=AES-128,URI="/keys/178.key"
  #EXTINF:4.0,
  /hls/178_0.ts?token=seg0
  #EXTINF:4.0,
  /hls/178_1.ts?token=seg1
  """

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  setup do
    Aviary.Cache.invalidate_match({:nhl, :_})
    Aviary.Cache.invalidate_match({:nhl, :_, :_})
    :ok
  end

  defp stub_site(overrides) do
    pages =
      Map.merge(
        %{
          "/" => {200, fixture("schedule.html")},
          "/stream/wings.html" => {200, fixture("frame.html")},
          "/stream/check_stream.php" => {200, ~s({"url":"#{@signed_playlist}"})},
          "/play/abc/178.m3u8" => {302, "", [{"location", @media_playlist}]},
          "/auth/178.m3u8" => {200, @media_playlist_body}
        },
        overrides
      )

    test = self()

    Req.Test.stub(Nhl, fn conn ->
      {status, body, headers} =
        pages
        |> Map.get_lazy(conn.request_path, fn ->
          if String.ends_with?(conn.request_path, "-live/"),
            do: {200, fixture("team_page.html")},
            else: {404, ""}
        end)
        |> with_headers()

      send(test, {:requested, conn.request_path, conn.query_string})

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.send_resp(status, body)
    end)

    Req.Test.allow(Nhl, test, Process.whereis(Site))
  end

  defp walk_site(options \\ []) do
    {:ok, schedule} = Schedule.start_link([name: nil, refresh_on_its_own: false] ++ options)
    Schedule.refresh(schedule)
    schedule
  end

  defp with_headers({status, body}), do: {status, body, []}
  defp with_headers({status, body, headers}), do: {status, body, headers}

  describe "games/0" do
    test "keeps games and playback across midnight even when the source removes yesterday" do
      date = ~D[2026-10-24]
      {:ok, clock} = Agent.start_link(fn -> {{2026, 10, 24}, {23, 59, 0}} end)
      stub_site(%{"/" => {200, schedule_dated(date)}, "/hls/178_0.ts" => {200, "video"}})
      schedule = walk_site(local_now: fn -> Agent.get(clock, & &1) end)
      before_midnight = Nhl.games()
      assert length(before_midnight) == 5
      assert {:ok, _} = Nhl.playlist("detroit-red-wings", "wings")

      Agent.update(clock, fn _ -> {{2026, 10, 25}, {0, 2, 0}} end)
      stub_site(%{"/" => {200, "<table></table>"}, "/hls/178_0.ts" => {200, "video"}})
      Schedule.refresh(schedule)

      assert Nhl.games() == before_midnight
      assert {:ok, _} = Nhl.playlist("detroit-red-wings", "wings")

      assert {:ok, %{body: "video"}} =
               Nhl.segment(
                 "detroit-red-wings",
                 "wings",
                 "https://media.example.test/hls/178_0.ts"
               )

      Agent.update(clock, fn _ -> {{2026, 10, 25}, {6, 0, 0}} end)
      Schedule.refresh(schedule)
      assert Nhl.games() == []
      assert Nhl.playlist("detroit-red-wings", "wings") == {:error, :unavailable}
    end

    test "loads yesterday after a midnight restart with its original start date" do
      stub_site(%{"/" => {200, schedule_dated(~D[2026-10-24])}})
      walk_site(local_now: fn -> {{2026, 10, 25}, {0, 2, 0}} end)

      assert [%{starts_at: starts_at} | _] = Nhl.games()
      assert length(Nhl.games()) == 5

      assert starts_at
             |> DateTime.to_naive()
             |> NaiveDateTime.to_erl()
             |> :calendar.universal_time_to_local_time() == {{2026, 10, 24}, {18, 30, 0}}

      assert {:ok, _} = Nhl.playlist("detroit-red-wings", "wings")
    end

    test "excludes yesterday at the morning cutoff and days outside the overnight window" do
      stub_site(%{"/" => {200, schedule_dated(~D[2026-10-24])}})
      walk_site(local_now: fn -> {{2026, 10, 25}, {6, 0, 0}} end)
      assert Nhl.games() == []
      walk_site(local_now: fn -> {{2026, 10, 26}, {0, 2, 0}} end)
      assert Nhl.games() == []
    end

    test "lists today's games with their feeds" do
      stub_site(%{"/" => {200, schedule_dated(Aviary.LocalTime.today())}})
      walk_site()

      games = Nhl.games()

      assert length(games) == 5
      assert [%{id: "detroit-red-wings", time: "6:30", feeds: feeds} | _] = games

      assert feeds == [
               %{id: "rangers", label: "Rangers"},
               %{id: "wings", label: "Red Wings"},
               %{id: "wings2", label: "Backup"},
               %{id: "wings3", label: "Backup 2"}
             ]
    end

    test "reads the schedule's clock times as this evening" do
      stub_site(%{"/" => {200, schedule_dated(Aviary.LocalTime.today())}})
      walk_site()

      [%{time: "6:30", starts_at: starts_at} | _] = Nhl.games()

      {local_date, {hour, minute, _second}} =
        starts_at
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()

      assert Date.from_erl!(local_date) == Aviary.LocalTime.today()
      assert {hour, minute} == {18, 30}
    end

    test "leaves out games scheduled for another day" do
      stub_site(%{"/" => {200, schedule_dated(Date.add(Aviary.LocalTime.today(), 1))}})
      walk_site()

      assert Nhl.games() == []
    end

    test "is empty when the site is down" do
      stub_site(%{"/" => {503, "maintenance"}})
      walk_site()

      assert Nhl.games() == []
    end

    test "never asks the site on a caller's behalf" do
      stub_site(%{"/" => {200, undated_schedule()}})

      assert Nhl.games() == []
      refute_received {:requested, _, _}
    end

    test "keeps a game's feeds between walks of the schedule" do
      stub_site(%{"/" => {200, undated_schedule()}})
      schedule = walk_site()
      assert_received {:requested, "/", _}
      assert_received {:requested, "/detroit-red-wings-live/", _}

      Schedule.refresh(schedule)
      assert_received {:requested, "/", _}
      refute_received {:requested, "/detroit-red-wings-live/", _}
      assert [%{feeds: [_, _, _, _]}] = Nhl.games()
    end

    test "asks a team page again once its feeds are old enough" do
      stub_site(%{"/" => {200, undated_schedule()}})

      schedule = walk_site(feeds_every_ms: 0)
      Schedule.refresh(schedule)

      assert_received {:requested, "/detroit-red-wings-live/", _}
      assert_received {:requested, "/detroit-red-wings-live/", _}
    end

    test "keeps the feeds it had when a team page stops answering" do
      stub_site(%{"/" => {200, undated_schedule()}})

      schedule = walk_site(feeds_every_ms: 0)

      stub_site(%{"/" => {200, undated_schedule()}, "/detroit-red-wings-live/" => {503, ""}})
      Schedule.refresh(schedule)

      assert [%{feeds: [%{id: "rangers"} | _]}] = Nhl.games()
    end

    test "stops the walk at the first refusal and leaves the site alone for a while" do
      stub_site(%{
        "/" => {200, schedule_dated(Aviary.LocalTime.today())},
        "/detroit-red-wings-live/" => {403, "Forbidden"}
      })

      schedule = walk_site()

      assert_received {:requested, "/", _}
      assert_received {:requested, "/detroit-red-wings-live/", _}
      refute_received {:requested, _, _}
      assert length(Nhl.games()) == 5
      assert Enum.all?(Nhl.games(), &(&1.feeds == []))

      stub_site(%{"/" => {200, schedule_dated(Aviary.LocalTime.today())}})
      Schedule.refresh(schedule)
      refute_received {:requested, _, _}
    end

    test "still resolves a stream while holding off the site after a refusal" do
      stub_site(%{"/" => {200, undated_schedule()}})
      schedule = walk_site()

      stub_site(%{"/" => {403, "Forbidden"}})
      Schedule.refresh(schedule)

      assert {:ok, _playlist} = Nhl.playlist("detroit-red-wings", "wings")
      assert_received {:requested, "/stream/wings.html", _}
    end
  end

  describe "Aviary.Nhl.Site" do
    test "lets one request through at a time, with a pause after each" do
      pause_ms = 30
      work_ms = 10
      clock_granularity_ms = 1
      {:ok, site} = Site.start_link(name: nil, pause_ms: pause_ms)
      {:ok, log} = Agent.start_link(fn -> %{in_flight: 0, most_at_once: 0, started_at: []} end)

      perform = fn ->
        Agent.update(log, fn log ->
          in_flight = log.in_flight + 1

          %{
            log
            | in_flight: in_flight,
              most_at_once: max(log.most_at_once, in_flight),
              started_at: [System.monotonic_time(:microsecond) | log.started_at]
          }
        end)

        Process.sleep(work_ms)
        Agent.update(log, &%{&1 | in_flight: &1.in_flight - 1})
        :done
      end

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> Site.request(site, perform) end) end)
        |> Task.await_many()

      assert results == [:done, :done, :done, :done]
      %{most_at_once: 1, started_at: started_at} = Agent.get(log, & &1)

      gaps_between_starts_us =
        started_at
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [earlier, later] -> later - earlier end)

      shortest_gap_us = (work_ms + pause_ms - clock_granularity_ms) * 1_000
      assert Enum.all?(gaps_between_starts_us, &(&1 >= shortest_gap_us))
    end
  end

  describe "logo/1" do
    test "serves a team's logo from the CDN and keeps it" do
      stub_site(%{"/i/teamlogos/nhl/500/nyr.png" => {200, "PNG rangers"}})

      assert Nhl.logo("new-york-rangers") == {:ok, "PNG rangers"}
      assert_received {:requested, "/i/teamlogos/nhl/500/nyr.png", _}

      assert Nhl.logo("new-york-rangers") == {:ok, "PNG rangers"}
      refute_received {:requested, "/i/teamlogos/nhl/500/nyr.png", _}
    end

    test "serves the dark-background set when asked" do
      stub_site(%{"/i/teamlogos/nhl/500-dark/wsh.png" => {200, "PNG red capitals"}})

      assert Nhl.logo("washington-capitals", :dark) == {:ok, "PNG red capitals"}
    end

    test "is an error for a slug that isn't a team" do
      stub_site(%{})

      assert Nhl.logo("../etc/passwd") == :error
    end
  end

  describe "playlist/2" do
    setup do
      stub_site(%{"/" => {200, undated_schedule()}})
      walk_site()
      :ok
    end

    test "serves the media playlist with every path made absolute" do
      assert {:ok, playlist} = Nhl.playlist("detroit-red-wings", "wings")

      assert playlist == """
             #EXTM3U
             #EXT-X-VERSION:3
             #EXT-X-TARGETDURATION:5
             #EXT-X-KEY:METHOD=AES-128,URI="https://media.example.test/keys/178.key"
             #EXTINF:4.0,
             https://media.example.test/hls/178_0.ts?token=seg0
             #EXTINF:4.0,
             https://media.example.test/hls/178_1.ts?token=seg1
             """

      assert_received {:requested, "/stream/check_stream.php",
                       "id=178&ts=1790976342&pt=d704dccd6b0eef7c"}
    end

    test "rewrites every media url through the given function" do
      assert {:ok, playlist} =
               Nhl.playlist(
                 "detroit-red-wings",
                 "wings",
                 &("/relay?url=" <> URI.encode_www_form(&1))
               )

      assert playlist =~ ~s(URI="/relay?url=https%3A%2F%2Fmedia.example.test%2Fkeys%2F178.key")

      assert playlist =~
               "\n/relay?url=https%3A%2F%2Fmedia.example.test%2Fhls%2F178_0.ts%3Ftoken%3Dseg0\n"
    end

    test "reuses the resolved media playlist instead of looking the stream up again" do
      assert {:ok, _} = Nhl.playlist("detroit-red-wings", "wings")
      assert_received {:requested, "/stream/check_stream.php", _}

      assert {:ok, _} = Nhl.playlist("detroit-red-wings", "wings")
      refute_received {:requested, "/stream/check_stream.php", _}
      assert_received {:requested, "/auth/178.m3u8", _}
    end

    test "looks the stream up again once the media playlist stops answering" do
      expired = "https://media.example.test/auth/expired.m3u8?token=old"
      Aviary.Cache.fetch({:nhl, :media_url, "wings"}, :timer.hours(1), fn -> {:ok, expired} end)
      stub_site(%{"/" => {200, undated_schedule()}, "/auth/expired.m3u8" => {403, "denied"}})

      assert {:ok, playlist} = Nhl.playlist("detroit-red-wings", "wings")

      assert playlist =~ "https://media.example.test/hls/178_0.ts"
      assert_received {:requested, "/stream/check_stream.php", _}
    end

    test "reports a feed that has no playlist yet as not live" do
      stub_site(%{"/" => {200, undated_schedule()}, "/play/abc/178.m3u8" => {200, ""}})

      assert Nhl.playlist("detroit-red-wings", "wings") == {:error, :not_live}
    end

    test "refuses feeds the game doesn't list" do
      assert Nhl.playlist("detroit-red-wings", "../../admin") == {:error, :unavailable}
      assert Nhl.playlist("detroit-red-wings", "kraken") == {:error, :unavailable}
      refute_received {:requested, "/stream/kraken.html", _}
    end

    test "is unavailable when the lookup answers without a url" do
      stub_site(%{"/" => {200, undated_schedule()}, "/stream/check_stream.php" => {200, "{}"}})

      assert Nhl.playlist("detroit-red-wings", "wings") == {:error, :unavailable}
    end
  end

  describe "segment/3" do
    setup do
      stub_site(%{
        "/" => {200, undated_schedule()},
        "/hls/178_0.ts" => {200, "MPEGTS bytes", [{"content-type", "video/mp2t"}]}
      })

      walk_site()
      :ok
    end

    test "relays a media file from the feed's own host without a referer" do
      assert Nhl.segment(
               "detroit-red-wings",
               "wings",
               "https://media.example.test/hls/178_0.ts?token=seg0"
             ) ==
               {:ok, %{body: "MPEGTS bytes", content_type: "video/mp2t"}}
    end

    test "refuses a url on any other host" do
      assert Nhl.segment(
               "detroit-red-wings",
               "wings",
               "https://elsewhere.example.test/hls/178_0.ts"
             ) ==
               :error

      refute_received {:requested, "/hls/178_0.ts", _}
    end
  end

  defp schedule_dated(date) do
    String.replace(
      fixture("schedule.html"),
      "October 2, 2026",
      Calendar.strftime(date, "%B %-d, %Y")
    )
  end

  defp undated_schedule do
    """
    <tr class="singele_match_date ">
    <td class="matchtime">6:30</td>
    <td class="teamlogo"><a class="team" href="https://slapstreams.com/new-york-rangers-live/"><img></a></td>
    <td class="teamlogo"><a class="team" href="https://slapstreams.com/detroit-red-wings-live/"><img></a></td>
    </tr>
    """
  end
end
