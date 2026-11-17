defmodule Aviary.ReconcileTest do
  use ExUnit.Case, async: false

  alias Aviary.{Radarr, Reconcile, Sonarr}

  @an_hour_ago DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
  @just_now DateTime.utc_now() |> DateTime.to_iso8601()
  @hours_ago DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.to_iso8601()

  describe "a finished download Sonarr won't import" do
    test "is blocklisted and searched for again when the file is useless" do
      stub_sonarr(queue: [finished(42, ["Unable to determine if file is a sample"])])
      stub_radarr(queue: [])

      Reconcile.sweep_stuck_downloads()

      assert_received {:sonarr, :delete, "42",
                       %{
                         "blocklist" => "true",
                         "removeFromClient" => "true",
                         "skipRedownload" => "false"
                       }}
    end

    test "is dropped without a blocklist when the episode already has a file" do
      stub_sonarr(
        queue: [
          finished(42, ["Not an upgrade for existing episode file(s)"], episodeHasFile: true)
        ]
      )

      stub_radarr(queue: [])

      Reconcile.sweep_stuck_downloads()

      assert_received {:sonarr, :delete, "42",
                       %{"blocklist" => "false", "removeFromClient" => "true"}}
    end

    test "is imported when Sonarr only matched it to the series by id" do
      stub_sonarr(
        queue: [
          finished(42, [
            "Found matching series via grab history, but release was matched to series by ID"
          ])
        ],
        candidates: [clean_episode_file()]
      )

      stub_radarr(queue: [])

      Reconcile.sweep_stuck_downloads()

      assert_received {:sonarr, :command, %{"name" => "ManualImport", "files" => [file]}}
      assert file["seriesId"] == 7
      assert file["episodeIds"] == [99]
      refute_received {:sonarr, :delete, _, _}
    end

    test "is blocklisted when the id match comes with rejected files" do
      stub_sonarr(
        queue: [
          finished(42, [
            "Found matching series via grab history, but release was matched to series by ID"
          ])
        ],
        candidates: [
          Map.put(clean_episode_file(), "rejections", [%{"reason" => "Not an upgrade"}])
        ]
      )

      stub_radarr(queue: [])

      Reconcile.sweep_stuck_downloads()

      assert_received {:sonarr, :delete, "42", %{"blocklist" => "true"}}
      refute_received {:sonarr, :command, _}
    end

    test "is left alone while it has only just finished" do
      stub_sonarr(
        queue: [finished(42, ["Unable to determine if file is a sample"], added: @just_now)]
      )

      stub_radarr(queue: [])

      Reconcile.sweep_stuck_downloads()

      refute_received {:sonarr, :delete, _, _}
    end
  end

  test "a warning on a download still in flight is not stuck" do
    stalled =
      finished(42, ["The download is stalled with no connections"])
      |> Map.merge(%{"status" => "downloading", "trackedDownloadState" => "downloading"})

    stub_sonarr(queue: [stalled])
    stub_radarr(queue: [])

    Reconcile.sweep_stuck_downloads()

    refute_received {:sonarr, :delete, _, _}
  end

  describe "a finished download Radarr won't import" do
    test "is imported when Radarr only matched it to the movie by id" do
      stub_sonarr(queue: [])

      stub_radarr(
        queue: [
          finished(
            7,
            [
              "Found matching movie via grab history, but release was matched to movie by ID. Manual Import required."
            ],
            trackedDownloadState: "importBlocked",
            movie: %{"id" => 60, "title" => "The Fellowship of the Ring", "hasFile" => false}
          )
        ],
        candidates: [clean_movie_file()]
      )

      Reconcile.sweep_stuck_downloads()

      assert_received {:radarr, :command, %{"name" => "ManualImport", "files" => [file]}}
      assert file["movieId"] == 60
    end

    test "is dropped when the movie already has a file" do
      stub_sonarr(queue: [])

      stub_radarr(
        queue: [
          finished(7, ["Not an upgrade"],
            movie: %{"id" => 60, "title" => "Dune", "hasFile" => true}
          )
        ]
      )

      Reconcile.sweep_stuck_downloads()

      assert_received {:radarr, :delete, "7",
                       %{"blocklist" => "false", "removeFromClient" => "true"}}
    end

    test "is blocklisted and searched for again when the file is useless" do
      stub_sonarr(queue: [])

      stub_radarr(
        queue: [
          finished(7, ["Unable to determine if file is a sample"],
            movie: %{"id" => 60, "title" => "Dune", "hasFile" => false}
          )
        ]
      )

      Reconcile.sweep_stuck_downloads()

      assert_received {:radarr, :delete, "7",
                       %{"blocklist" => "true", "skipRedownload" => "false"}}
    end
  end

  describe "an episode whose every accepted release failed to download" do
    test "gets the most playable release Sonarr rejects" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        releases: [
          release("blocklisted.1080p.h264", rejections: ["Release is blocklisted"]),
          release("hevc.1080p",
            rejections: [
              "Custom Formats Codec: HEVC / x265 have score -10000 below Series profile minimum 0"
            ],
            customFormats: [%{"name" => "Codec: HEVC / x265"}]
          ),
          release("h264.720p",
            rejections: ["WEBDL-720p is not wanted in profile"],
            quality: quality(720)
          )
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 1
      assert_received {:sonarr, :grab, %{"guid" => "h264.720p", "indexerId" => 2}}
      refute_received {:sonarr, :grab, _}
    end

    test "settles for HEVC when no H.264 release is left" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        releases: [
          release("hevc.720p",
            rejections: ["Custom Formats Codec: HEVC / x265 have score -10000 below minimum 0"],
            customFormats: [%{"name" => "Codec: HEVC / x265"}],
            quality: quality(720)
          ),
          release("hevc.1080p",
            rejections: ["Custom Formats Codec: HEVC / x265 have score -10000 below minimum 0"],
            customFormats: [%{"name" => "Codec: HEVC / x265"}]
          )
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 1
      assert_received {:sonarr, :grab, %{"guid" => "hevc.1080p"}}
    end

    test "is left to Sonarr while a release it accepts is still on offer" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        releases: [
          release("accepted.1080p.h264", approved: true, rejections: []),
          release("h264.720p",
            rejections: ["WEBDL-720p is not wanted in profile"],
            quality: quality(720)
          )
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 0
      refute_received {:sonarr, :grab, _}
    end

    test "never gets a release that is unwatchable here" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        releases: [
          release("blocklisted", rejections: ["Release is blocklisted"]),
          release("uhd",
            rejections: ["WEBDL-2160p is not wanted in profile"],
            quality: quality(2160)
          ),
          release("banned.group",
            rejections: ["Custom Formats Banned Release Groups have score -10000 below minimum 0"],
            customFormats: [%{"name" => "Banned Release Groups"}]
          ),
          release("german",
            rejections: ["WEBDL-720p is not wanted in profile"],
            quality: quality(720),
            languages: [%{"id" => 4, "name" => "German"}]
          ),
          release("wrong.episode", rejections: ["Episode wasn't requested: 1x02"])
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 0
      refute_received {:sonarr, :grab, _}
    end

    test "is left alone while another release is downloading" do
      stub_sonarr(
        queue: [%{"id" => 5, "episodeId" => 99, "status" => "downloading"}],
        failed_downloads: [failed_download(99)],
        releases: [
          release("h264.720p",
            rejections: ["WEBDL-720p is not wanted in profile"],
            quality: quality(720)
          )
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 0
      refute_received {:sonarr, :grab, _}
    end

    test "is left alone once it has a file or is no longer monitored" do
      stub_sonarr(
        queue: [],
        failed_downloads: [
          failed_download(99, hasFile: true),
          failed_download(100, monitored: false)
        ],
        releases: [
          release("h264.720p",
            rejections: ["WEBDL-720p is not wanted in profile"],
            quality: quality(720)
          )
        ]
      )

      assert Reconcile.grab_last_resort_releases() == 0
      refute_received {:sonarr, :grab, _}
    end
  end

  describe "an episode with a grab Sonarr has not reported on yet" do
    test "is left alone while the grab is recent" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        episode_history: [%{"eventType" => "grabbed", "date" => @just_now}],
        releases: [a_720p_h264_release()]
      )

      assert Reconcile.grab_last_resort_releases() == 0
      refute_received {:sonarr, :grab, _}
    end

    test "gets another release once the grab has gone unanswered for hours" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        episode_history: [%{"eventType" => "grabbed", "date" => @hours_ago}],
        releases: [a_720p_h264_release()]
      )

      assert Reconcile.grab_last_resort_releases() == 1
    end
  end

  describe "the pass that runs every few minutes" do
    test "gets a release for an episode whose download just failed" do
      stub_sonarr(
        queue: [],
        failed_downloads: [failed_download(99)],
        releases: [a_720p_h264_release()]
      )

      assert Reconcile.grab_last_resort_releases_after_recent_failures() == 1
    end

    test "skips an episode whose last failure was hours ago" do
      stub_sonarr(
        queue: [],
        failed_downloads: [Map.put(failed_download(99), "date", @hours_ago)],
        releases: [a_720p_h264_release()]
      )

      assert Reconcile.grab_last_resort_releases_after_recent_failures() == 0
      refute_received {:sonarr, :grab, _}
    end
  end

  defp failed_download(episode_id, episode_overrides \\ []) do
    episode =
      Map.merge(
        %{"id" => episode_id, "monitored" => true, "hasFile" => false},
        Map.new(episode_overrides, fn {key, value} -> {Atom.to_string(key), value} end)
      )

    %{
      "eventType" => "downloadFailed",
      "episodeId" => episode_id,
      "episode" => episode,
      "date" => @just_now
    }
  end

  defp a_720p_h264_release do
    release("h264.720p",
      rejections: ["WEBDL-720p is not wanted in profile"],
      quality: quality(720)
    )
  end

  defp release(guid, overrides) do
    Map.merge(
      %{
        "guid" => guid,
        "indexerId" => 2,
        "title" => guid,
        "approved" => false,
        "temporarilyRejected" => false,
        "downloadAllowed" => true,
        "customFormats" => [],
        "quality" => quality(1080),
        "languages" => [%{"id" => 1, "name" => "English"}],
        "size" => 1_000_000_000
      },
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp quality(resolution) do
    %{"quality" => %{"name" => "WEBDL-#{resolution}p", "resolution" => resolution}}
  end

  defp finished(id, messages, overrides \\ []) do
    Map.merge(
      %{
        "id" => id,
        "downloadId" => "download-#{id}",
        "title" => "Some.Release.1080p",
        "status" => "completed",
        "trackedDownloadStatus" => "warning",
        "trackedDownloadState" => "importPending",
        "statusMessages" => [%{"title" => "Some.Release.1080p", "messages" => messages}],
        "added" => @an_hour_ago,
        "episodeId" => 99,
        "episodeHasFile" => false
      },
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp clean_episode_file do
    %{
      "id" => 1,
      "path" => "/usenet/Some.Release.1080p/Some.Release.1080p.mkv",
      "folderName" => "Some.Release.1080p",
      "series" => %{"id" => 7, "title" => "Some Show"},
      "episodes" => [%{"id" => 99, "seasonNumber" => 1, "episodeNumber" => 1}],
      "quality" => %{"quality" => %{"id" => 3, "name" => "WEBDL-1080p"}},
      "languages" => [%{"id" => 1, "name" => "English"}],
      "releaseGroup" => "GRP",
      "rejections" => []
    }
  end

  defp clean_movie_file do
    %{
      "id" => 1,
      "path" => "/usenet/Some.Release.1080p/Some.Release.1080p.mkv",
      "folderName" => "Some.Release.1080p",
      "movie" => %{"id" => 60, "title" => "The Fellowship of the Ring"},
      "quality" => %{"quality" => %{"id" => 7, "name" => "Bluray-1080p"}},
      "languages" => [%{"id" => 1, "name" => "English"}],
      "releaseGroup" => "GRP",
      "rejections" => []
    }
  end

  defp stub_sonarr(opts) do
    stub(Sonarr, :sonarr, opts)
  end

  defp stub_radarr(opts) do
    stub(Radarr, :radarr, opts)
  end

  defp stub(name, tag, opts) do
    test = self()
    queue = Keyword.fetch!(opts, :queue)
    candidates = Keyword.get(opts, :candidates, [])
    failed_downloads = Keyword.get(opts, :failed_downloads, [])
    releases = Keyword.get(opts, :releases, [])
    episode_history = Keyword.get(opts, :episode_history, [])

    Req.Test.stub(name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/queue"} ->
          Req.Test.json(conn, %{"records" => queue, "totalRecords" => length(queue)})

        {"GET", "/api/v3/downloadclient"} ->
          Req.Test.json(conn, [])

        {"GET", "/api/v3/manualimport"} ->
          Req.Test.json(conn, candidates)

        {"GET", "/api/v3/history"} ->
          records =
            if conn.query_params["episodeId"], do: episode_history, else: failed_downloads

          Req.Test.json(conn, %{"records" => records})

        {"GET", "/api/v3/release"} ->
          Req.Test.json(conn, releases)

        {"POST", "/api/v3/release"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {tag, :grab, Jason.decode!(body)})
          Req.Test.json(conn, %{})

        {"DELETE", "/api/v3/queue/" <> id} ->
          send(test, {tag, :delete, id, conn.query_params})
          Req.Test.json(conn, %{})

        {"POST", "/api/v3/command"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {tag, :command, Jason.decode!(body)})
          Req.Test.json(conn, %{"id" => 1, "name" => "ManualImport", "status" => "queued"})
      end
    end)
  end
end
