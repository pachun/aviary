defmodule Aviary.DailyWireTest do
  use ExUnit.Case, async: false

  alias Aviary.DailyWire
  alias Aviary.DailyWire.Credentials

  setup do
    directory =
      Path.join(System.tmp_dir!(), "aviary-daily-wire-#{System.unique_integer([:positive])}")

    Aviary.Repo.delete_all(Aviary.DailyWire.Progress)
    File.mkdir_p!(directory)
    path = Path.join(directory, "tokens.json")
    previous_path = Application.get_env(:aviary, :daily_wire_token_file)
    previous_options = Application.get_env(:aviary, :daily_wire_req_options)
    Application.put_env(:aviary, :daily_wire_token_file, path)
    Application.put_env(:aviary, :daily_wire_req_options, plug: {Req.Test, DailyWire})
    Aviary.Cache.invalidate_match({:daily_wire, :episodes, :_})

    on_exit(fn ->
      Application.put_env(:aviary, :daily_wire_token_file, previous_path)
      Application.put_env(:aviary, :daily_wire_req_options, previous_options || [])
      Aviary.Cache.invalidate_match({:daily_wire, :episodes, :_})
      File.rm_rf!(directory)
    end)

    tokens = %{
      "access_token" => "current-access",
      "refresh_token" => "current-refresh",
      "expires_at" => System.system_time(:second) + 172_800,
      "allowed_user_ids" => ["owner"]
    }

    File.write!(path, Jason.encode!(tokens))
    %{path: path, tokens: tokens, user: %{id: "owner"}}
  end

  test "only the connected account can browse or play", %{user: user} do
    assert DailyWire.allowed?(user)
    refute DailyWire.allowed?(%{id: "someone-else"})

    assert {:error, :forbidden} =
             DailyWire.episodes(%{id: "someone-else"}, "the-ben-shapiro-show")

    assert {:error, :forbidden} = DailyWire.playback(%{id: "someone-else"}, "episode")
  end

  test "missing or malformed credentials leave Daily Wire disconnected", %{path: path, user: user} do
    File.write!(path, "not json")
    refute DailyWire.allowed?(user)
    assert {:error, :not_connected} = Credentials.access_token()
    File.rm!(path)
    refute DailyWire.allowed?(user)
  end

  test "a valid access token needs no login request" do
    assert {:ok, "current-access"} = Credentials.access_token()
  end

  test "concurrent requests renew once and persist rotated credentials privately", %{
    path: path,
    tokens: tokens
  } do
    File.write!(path, Jason.encode!(%{tokens | "expires_at" => 0}))
    parent = self()

    Req.Test.stub(DailyWire, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == "current-refresh"
      send(parent, :renewed)

      Req.Test.json(conn, %{
        access_token: "renewed-access",
        refresh_token: "rotated-refresh",
        expires_in: 2_592_000
      })
    end)

    Req.Test.allow(DailyWire, self(), Process.whereis(Credentials))
    results = Task.async_stream(1..5, fn _ -> Credentials.access_token() end) |> Enum.to_list()
    assert Enum.all?(results, &(&1 == {:ok, {:ok, "renewed-access"}}))
    assert_received :renewed
    refute_received :renewed
    saved = path |> File.read!() |> Jason.decode!()
    assert saved["refresh_token"] == "rotated-refresh"
    assert saved["allowed_user_ids"] == ["owner"]
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "renewal retains the refresh token when Daily Wire does not rotate it", %{
    path: path,
    tokens: tokens
  } do
    File.write!(path, Jason.encode!(%{tokens | "expires_at" => 0}))
    Req.Test.stub(DailyWire, &Req.Test.json(&1, %{access_token: "new", expires_in: 2_592_000}))
    Req.Test.allow(DailyWire, self(), Process.whereis(Credentials))
    assert {:ok, "new"} = Credentials.access_token()
    assert Jason.decode!(File.read!(path))["refresh_token"] == "current-refresh"
  end

  test "revocation reports reconnect without destroying the stored credentials", %{
    path: path,
    tokens: tokens
  } do
    File.write!(path, Jason.encode!(%{tokens | "expires_at" => 0}))
    original = File.read!(path)

    Req.Test.stub(
      DailyWire,
      &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_grant"}))
    )

    Req.Test.allow(DailyWire, self(), Process.whereis(Credentials))
    assert {:error, :reconnect} = Credentials.access_token()
    assert File.read!(path) == original
  end

  test "catalog includes member episodes and a signed next page", %{user: user} do
    Req.Test.stub(DailyWire, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer current-access"]

      case conn.request_path do
        "/middleware/v3/getUserInfo" ->
          Req.Test.json(conn, %{accessLevel: "ALL_ACCESS"})

        "/middleware/v4/getShowPage" ->
          Req.Test.json(conn, %{
            show: %{seasons: [%{id: "latest", name: "2026"}, %{id: "old", name: "2021"}]}
          })

        "/middleware/v4/getPaginatedEpisodes" ->
          query = URI.decode_query(conn.query_string)
          clip = %{episode() | "slug" => "episode-memberblock"}

          case query["pageNumber"] do
            "1" ->
              assert query["showSeasonId"] == "latest"
              assert query["orderBy"] == "published_at_desc"
              assert query["showOffset"] == "0"

              Req.Test.json(conn, %{
                componentItems: [%{showEpisode: clip}, %{showEpisode: episode()}],
                nextPageUrl: "/middleware/v4/getPaginatedEpisodes?pageNumber=2"
              })

            "2" ->
              Req.Test.json(conn, %{
                componentItems: [
                  %{showEpisode: clip},
                  %{showEpisode: %{episode() | "slug" => "older"}}
                ]
              })
          end
      end
    end)

    assert {:ok, %{episodes: [episode], nextPage: cursor}} =
             DailyWire.episodes(user, "the-ben-shapiro-show")

    assert episode.id == "member-episode"
    assert episode.dateLabel == "Fri Oct 23, 2026"
    assert episode.durationLabel == "8 min"
    assert episode.memberOnly
    assert is_binary(cursor)

    assert {:ok, %{episodes: [%{id: "older"}], nextPage: nil}} =
             DailyWire.episodes(user, "the-ben-shapiro-show", cursor)

    assert {:error, :invalid_page} = DailyWire.episodes(user, "sunday-special", cursor)

    assert {:error, :invalid_page} =
             DailyWire.episodes(user, "the-ben-shapiro-show", "https://attacker.test")
  end

  test "Sunday Special selects the newest season and orders episodes by date", %{user: user} do
    Req.Test.stub(DailyWire, fn conn ->
      case conn.request_path do
        "/middleware/v3/getUserInfo" ->
          Req.Test.json(conn, %{accessLevel: "ALL_ACCESS"})

        "/middleware/v4/getShowPage" ->
          Req.Test.json(conn, %{
            show: %{
              seasons: [
                %{id: "old", name: "2021"},
                %{id: "latest", name: "2024"}
              ]
            }
          })

        "/middleware/v4/getPaginatedEpisodes" ->
          query = URI.decode_query(conn.query_string)
          assert query["showSeasonId"] == "latest"
          assert query["orderBy"] == "published_at_desc"

          Req.Test.json(conn, %{
            componentItems: [
              %{
                showEpisode: %{
                  episode()
                  | "slug" => "older",
                    "publishedAt" => "2024-10-19T18:00:00Z"
                }
              },
              %{
                showEpisode: %{
                  episode()
                  | "slug" => "newer",
                    "publishedAt" => "2024-12-21T18:00:00Z",
                    "duration" => 3240.5
                }
              }
            ]
          })
      end
    end)

    assert {:ok, %{episodes: [newer, older]}} = DailyWire.episodes(user, "sunday-special")
    assert newer.id == "newer"
    assert older.id == "older"
    assert newer.dateLabel == "Sat Dec 21, 2024"
    assert newer.durationLabel == "54 min"
  end

  test "playback exposes only the signed media URL, never account credentials", %{user: user} do
    Req.Test.stub(DailyWire, fn conn ->
      Req.Test.json(conn, %{
        show: %{slug: "the-ben-shapiro-show"},
        title: "Member episode",
        playbackPolicy: "SIGNED",
        secureVideoURL: "",
        videoURL: "https://stream.mux.com/member.m3u8?token=media-only"
      })
    end)

    assert {:ok, %{streamUrl: url, contentType: "hls"} = playback} =
             DailyWire.playback(user, "member-episode")

    assert url == "https://stream.mux.com/member.m3u8?token=media-only"
    refute Jason.encode!(playback) =~ "current-access"
    refute Jason.encode!(playback) =~ "current-refresh"
  end

  test "browser and API playback share durable resume state", %{user: user} do
    Req.Test.stub(DailyWire, fn conn ->
      Req.Test.json(conn, %{
        show: %{slug: "the-ben-shapiro-show"},
        title: "Member episode",
        playbackPolicy: "SIGNED",
        videoURL: "https://stream.mux.com/member.m3u8"
      })
    end)

    assert {:ok, playback} = DailyWire.playback(user, "member-episode")

    params = %{
      "slug" => "member-episode",
      "sessionId" => playback.progress.sessionId,
      "sequence" => 1,
      "position" => 120,
      "duration" => 600
    }

    conn = Phoenix.ConnTest.build_conn() |> Plug.Conn.assign(:current_user, user)
    response = AviaryWeb.API.DailyWireController.progress(conn, params)
    assert Jason.decode!(response.resp_body)["resumeSeconds"] == 120
    assert {:ok, resumed} = DailyWire.playback(user, "member-episode")
    assert resumed.progress.resumeSeconds == 120
    assert resumed.progress.sessionId != playback.progress.sessionId

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_user: user, episode_index: %{}}
    }

    {:noreply, socket} =
      AviaryWeb.DailyWireLive.handle_async(:playback, {:ok, {:ok, resumed}}, socket)

    assert socket.assigns.watching.resume_seconds == 120
    final_report = %{params | "sessionId" => resumed.progress.sessionId, "position" => 180}

    {:noreply, closed} =
      AviaryWeb.DailyWireLive.handle_event("close_player", final_report, socket)

    assert closed.assigns.watching == nil
    assert {:ok, next} = DailyWire.playback(user, "member-episode")
    assert next.progress.resumeSeconds == 180
  end

  test "playback rejects other shows and DRM content", %{user: user} do
    Req.Test.stub(
      DailyWire,
      &Req.Test.json(&1, %{
        show: %{slug: "another-show"},
        playbackPolicy: "SIGNED",
        videoURL: "https://stream.mux.com/other.m3u8"
      })
    )

    assert {:error, :playback_unavailable} = DailyWire.playback(user, "other")

    Req.Test.stub(
      DailyWire,
      &Req.Test.json(&1, %{
        show: %{slug: "sunday-special"},
        playbackPolicy: "DRM",
        videoURL: "https://stream.mux.com/drm.m3u8"
      })
    )

    assert {:error, :playback_unavailable} = DailyWire.playback(user, "drm")
  end

  defp episode do
    %{
      "slug" => "member-episode",
      "title" => "Member episode",
      "status" => "PUBLISHED",
      "isPaidVideo" => true,
      "hasFreeAndPaidVideo" => false,
      "publishedAt" => "2026-10-23T18:00:00Z",
      "duration" => 480,
      "images" => %{"thumbnail" => %{"land" => "https://images.example/episode.jpg"}}
    }
  end
end
