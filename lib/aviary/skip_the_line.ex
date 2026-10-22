defmodule Aviary.SkipTheLine do
  @moduledoc """
  Puts the episode someone is waiting to watch at the front of the
  download line. Sonarr hands every grab to SABnzbd at the same
  priority, so a show's first episode otherwise waits behind whatever
  the household already had queued: Black Mirror's first episode once
  sat four minutes behind another show's back catalog before its
  eighteen-second download began.

  Sonarr takes a few seconds to settle on a release, so this watches
  the episode's history for the grab and promotes it the moment it
  appears. A grab that fails gets replaced by another, which is
  promoted in turn, until the episode has a file or the watch runs
  out. Only SABnzbd downloads are promoted; a torrent grab is left in
  its client's order.
  """
  require Logger

  alias Aviary.{Sabnzbd, Sonarr}

  @poll_every_ms 2_000
  @watch_for_ms :timer.minutes(10)

  @doc """
  Watches, in the background, for Sonarr to grab this episode and moves
  the grab to the front of SABnzbd's queue. Returns the watcher's pid.
  """
  def for_episode(tmdb_id, season, episode, options \\ []) do
    poll_every_ms = Keyword.get(options, :poll_every_ms, @poll_every_ms)
    watch_for_ms = Keyword.get(options, :watch_for_ms, @watch_for_ms)
    give_up_at = now() + watch_for_ms

    {:ok, pid} =
      Task.start(fn ->
        watch(%{
          tmdb_id: tmdb_id,
          season: season,
          episode: episode,
          episode_id: nil,
          promoted: MapSet.new(),
          poll_every_ms: poll_every_ms,
          give_up_at: give_up_at
        })
      end)

    pid
  end

  defp watch(%{give_up_at: give_up_at} = state) do
    cond do
      now() > give_up_at ->
        Logger.info("skip_the_line: stopped watching #{describe(state)}; nothing more to promote")

      state.episode_id == nil ->
        state |> Map.put(:episode_id, episode_id(state)) |> wait_then_watch()

      true ->
        case Sonarr.episode_history(state.episode_id) do
          {:ok, [%{"eventType" => "downloadFolderImported"} | _]} ->
            Logger.info("skip_the_line: #{describe(state)} is in; done")

          {:ok, history} ->
            history |> latest_grab() |> promote(state) |> wait_then_watch()

          :error ->
            wait_then_watch(state)
        end
    end
  end

  defp wait_then_watch(state) do
    Process.sleep(state.poll_every_ms)
    watch(state)
  end

  defp episode_id(%{tmdb_id: tmdb_id, season: season, episode: episode}) do
    case Sonarr.series_status(tmdb_id) do
      {:ok, %{episodes: episodes}} -> get_in(episodes, [{season, episode}, :id])
      _ -> nil
    end
  end

  defp latest_grab(history) do
    Enum.find(history, &(&1["eventType"] == "grabbed"))
  end

  defp promote(nil, state), do: state

  defp promote(%{"downloadId" => download_id} = grab, state) when is_binary(download_id) do
    cond do
      MapSet.member?(state.promoted, download_id) ->
        state

      get_in(grab, ["data", "downloadClient"]) != "SABnzbd" ->
        Logger.info(
          "skip_the_line: #{describe(state)} went to #{downloader(grab)}; leaving its order alone"
        )

        remember(state, download_id)

      Sabnzbd.move_to_front(download_id) == :ok ->
        Logger.info("skip_the_line: moved #{describe(state)} to the front of SABnzbd's queue")
        remember(state, download_id)

      true ->
        state
    end
  end

  defp promote(_grab_without_download_id, state), do: state

  defp remember(state, download_id) do
    %{state | promoted: MapSet.put(state.promoted, download_id)}
  end

  defp downloader(grab), do: get_in(grab, ["data", "downloadClient"]) || "an unknown client"

  defp describe(%{tmdb_id: tmdb_id, season: season, episode: episode}),
    do: "S#{season}E#{episode} of tmdb #{tmdb_id}"

  defp now, do: System.monotonic_time(:millisecond)
end
