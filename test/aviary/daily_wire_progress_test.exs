defmodule Aviary.DailyWire.ProgressTest do
  use ExUnit.Case, async: false
  alias Aviary.DailyWire.Progress

  setup do
    Aviary.Repo.delete_all(Progress)
    :ok
  end

  test "progress survives a fresh playback session and stays isolated by user and episode" do
    started = Progress.start("owner", "episode")
    assert started.resumeSeconds == 0
    assert {:ok, saved} = Progress.save("owner", "episode", report(started, 120, 600, 1))
    assert saved.label == "Resume · 8 min left"
    assert Progress.start("owner", "episode").resumeSeconds == 120
    assert Progress.start("other", "episode").resumeSeconds == 0
    assert Progress.start("owner", "different").resumeSeconds == 0

    assert [%{progress: %{resumeSeconds: 120.0}}] =
             Progress.for_episodes("owner", [%{id: "episode"}])
  end

  test "delayed reports cannot rewind a newer report or a newer device session" do
    first = Progress.start("owner", "episode")
    assert {:ok, _} = Progress.save("owner", "episode", report(first, 120, 600, 2))

    assert {:ok, %{resumeSeconds: 120.0}} =
             Progress.save("owner", "episode", report(first, 60, 600, 1))

    second = Progress.start("owner", "episode")
    assert {:ok, _} = Progress.save("owner", "episode", report(second, 240, 600, 1))

    assert {:error, :stale_progress} =
             Progress.save("owner", "episode", report(first, 180, 600, 3))

    assert Progress.start("owner", "episode").resumeSeconds == 240
  end

  test "seeking backward intentionally saves the new position" do
    started = Progress.start("owner", "episode")
    assert {:ok, _} = Progress.save("owner", "episode", report(started, 300, 600, 1))

    assert {:ok, %{resumeSeconds: 60.0}} =
             Progress.save("owner", "episode", report(started, 60, 600, 2))
  end

  test "completion marks watched and replay starts at the beginning" do
    started = Progress.start("owner", "episode")

    assert {:ok, %{watched: true, resumeSeconds: 0}} =
             Progress.save("owner", "episode", report(started, 590, 600, 1))

    replay = Progress.start("owner", "episode")
    assert replay.watched
    assert replay.resumeSeconds == 0

    assert {:ok, %{watched: false, resumeSeconds: 30.0}} =
             Progress.save("owner", "episode", report(replay, 30, 600, 1))

    assert {:ok, %{watched: true}} =
             Progress.save(
               "owner",
               "episode",
               Map.put(report(replay, 500, 600, 2), "ended", true)
             )
  end

  test "invalid reports and another user's session cannot change progress" do
    started = Progress.start("owner", "episode")

    for {position, duration} <- [{-1, 600}, {10, 0}, {601, 600}, {10, nil}, {"10", 600}] do
      assert {:error, :invalid_progress} =
               Progress.save("owner", "episode", report(started, position, duration, 1))
    end

    assert {:error, :stale_progress} =
             Progress.save("other", "episode", report(started, 120, 600, 1))

    assert {:error, :forbidden} =
             Aviary.DailyWire.save_progress(
               %{id: "unauthorized"},
               "episode",
               report(started, 120, 600, 1)
             )

    assert Progress.start("owner", "episode").resumeSeconds == 0
  end

  defp report(started, position, duration, sequence) do
    %{
      "sessionId" => started.sessionId,
      "sequence" => sequence,
      "position" => position,
      "duration" => duration
    }
  end
end
