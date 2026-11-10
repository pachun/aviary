defmodule Aviary.ReconcileTest do
  use ExUnit.Case, async: false

  alias Aviary.{Radarr, Reconcile, Sonarr}

  @an_hour_ago DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()
  @just_now DateTime.utc_now() |> DateTime.to_iso8601()

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

    Req.Test.stub(name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/queue"} ->
          Req.Test.json(conn, %{"records" => queue, "totalRecords" => length(queue)})

        {"GET", "/api/v3/downloadclient"} ->
          Req.Test.json(conn, [])

        {"GET", "/api/v3/manualimport"} ->
          Req.Test.json(conn, candidates)

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
