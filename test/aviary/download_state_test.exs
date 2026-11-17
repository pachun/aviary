defmodule Aviary.DownloadStateTest do
  use ExUnit.Case, async: true

  alias Aviary.DownloadState

  describe "a download that failed" do
    test "reads as searching while Sonarr is still deciding what to do with it" do
      record = %{
        "status" => "completed",
        "trackedDownloadState" => "failedPending",
        "size" => 5_000,
        "sizeleft" => 0
      }

      assert DownloadState.queue_record_state(record) == :searching
    end

    test "reads as searching when the download client reports the failure" do
      record = %{"status" => "failed", "size" => 5_000, "sizeleft" => 0}

      assert DownloadState.queue_record_state(record) == :searching
    end
  end

  test "a finished download waiting to be imported reads as imported" do
    record = %{
      "status" => "completed",
      "trackedDownloadState" => "importPending",
      "size" => 5_000,
      "sizeleft" => 0
    }

    assert DownloadState.queue_record_state(record) == :imported
  end
end
