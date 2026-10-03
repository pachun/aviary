defmodule Aviary.NhlTest do
  use ExUnit.Case, async: false

  alias Aviary.Nhl

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

    Req.Test.stub(Nhl, fn conn ->
      {status, body, headers} =
        pages
        |> Map.get_lazy(conn.request_path, fn ->
          if String.ends_with?(conn.request_path, "-live/"),
            do: {200, fixture("team_page.html")},
            else: {404, ""}
        end)
        |> with_headers()

      send(self(), {:requested, conn.request_path, conn.query_string})

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp with_headers({status, body}), do: {status, body, []}
  defp with_headers({status, body, headers}), do: {status, body, headers}

  describe "games/0" do
    test "lists today's games with their feeds" do
      stub_site(%{"/" => {200, schedule_dated(Aviary.LocalTime.today())}})

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

    test "leaves out games scheduled for another day" do
      stub_site(%{"/" => {200, schedule_dated(Date.add(Aviary.LocalTime.today(), 1))}})

      assert Nhl.games() == []
    end

    test "is empty when the site is down" do
      stub_site(%{"/" => {503, "maintenance"}})

      assert Nhl.games() == []
    end

    test "leaves the site alone for a while after it bans us" do
      stub_site(%{"/" => {403, "Forbidden"}})
      assert Nhl.games() == []
      assert_received {:requested, "/", _}

      Aviary.Cache.invalidate({:nhl, :games})
      stub_site(%{"/" => {200, undated_schedule()}})
      assert Nhl.games() == []
      refute_received {:requested, "/", _}
    end

    test "serves the cached schedule without asking the site again" do
      stub_site(%{"/" => {200, undated_schedule()}})
      assert [%{id: "detroit-red-wings"}] = Nhl.games()
      assert_received {:requested, "/", _}

      assert [%{id: "detroit-red-wings"}] = Nhl.games()
      refute_received {:requested, "/", _}
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
