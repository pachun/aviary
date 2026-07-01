defmodule Aviary.DownloadState do
  @moduledoc """
  Single source of truth for turning a Sonarr/Radarr download-queue
  record into a UI state. Shared by the web detail LiveView and the
  native-client status API so both report the same truth about what a
  download is doing — no drift between surfaces.

  States:
    :playable            file present, ready to watch
    :searching           monitored, no queue record yet
    {:downloading, pct}  actively transferring (pct 0..100)
    :imported            downloaded, importing / awaiting library scan
    :stuck               needs manual intervention in Sonarr/Radarr
    :ready               nothing in flight (not monitored / not added)
  """

  # Maps a raw queue record to a state. The warning check comes first: a
  # record can be `importPending` with `trackedDownloadStatus: "warning"`
  # and a non-empty statusMessages list — Sonarr/Radarr's signal for "I
  # can't finish this import without help." Without distinguishing it,
  # the UI sits on "Importing…" forever.
  def queue_record_state(%{
        "trackedDownloadStatus" => "warning",
        "statusMessages" => [_ | _]
      }),
      do: :stuck

  def queue_record_state(%{"trackedDownloadState" => state})
      when state in ["importPending", "importing", "importBlocked", "imported"],
      do: :imported

  def queue_record_state(%{"size" => size, "sizeleft" => 0})
      when is_number(size) and size > 0,
      do: :imported

  # Never report 100% while bytes are still in flight — rounding hits
  # 100 in the last fraction of a percent, and "100%" reads as "ready
  # to watch" when it isn't yet. Roll into :imported at the top of the
  # bar instead, so the label goes …98% → 99% → Importing → Play.
  def queue_record_state(%{"size" => size, "sizeleft" => left})
      when is_number(size) and is_number(left) and size > 0 and left > 0 do
    case round((size - left) / size * 100) do
      pct when pct >= 100 -> :imported
      pct -> {:downloading, pct}
    end
  end

  def queue_record_state(_), do: {:downloading, 0}

  @doc """
  State for one episode of a show, given a `series_status` snapshot
  (`%{episodes: %{{s,e} => %{id, monitored, has_file}}, queue: [...]}`)
  or nil.
  """
  def episode_state(_s, _e, nil), do: :ready

  def episode_state(s, e, status) do
    case Map.get(status.episodes, {s, e}) do
      %{has_file: true} -> :imported
      %{id: id, monitored: true} -> queue_state(status.queue, id)
      _ -> :ready
    end
  end

  @doc """
  Show-level state — mirrors the first episode of the first season, the
  one the user would start watching from.
  """
  def show_overall(nil), do: :ready

  def show_overall(status) do
    case first_episode_key(status) do
      {s, e} -> episode_state(s, e, status)
      nil -> :ready
    end
  end

  @doc """
  State for a movie, given a `movie_status` snapshot
  (`%{has_file, monitored, queue: [...]}`) or nil.
  """
  def movie_state(nil), do: :ready
  def movie_state(%{has_file: true}), do: :playable

  def movie_state(%{monitored: monitored, queue: queue}) do
    case queue do
      [record | _] -> queue_record_state(record)
      _ -> if monitored, do: :searching, else: :ready
    end
  end

  @doc """
  Seconds-until-done for the queue record matching `download_id`
  (episodeId for Sonarr, movieId for Radarr), or nil. Feeds the
  "until watchable" estimate through `Aviary.WatchProgress`.
  """
  def timeleft_seconds(nil, _download_id), do: nil

  def timeleft_seconds(queue, download_id) do
    case find_record(queue, download_id) do
      nil -> nil
      record -> Aviary.WatchProgress.parse_timeleft(record["timeleft"])
    end
  end

  @doc "First {season, episode} key in a series status, lowest season/episode."
  def first_episode_key(nil), do: nil

  def first_episode_key(status) do
    status.episodes
    |> Map.keys()
    |> Enum.filter(fn {s, _e} -> is_integer(s) and s > 0 end)
    |> Enum.sort()
    |> List.first()
  end

  @doc """
  Per-episode overlay states, keyed "season:episode", for episodes
  genuinely in flight. Excludes episodes that already have a file and
  aren't being re-grabbed — the client draws no overlay on those.
  """
  def episode_overlays(nil), do: %{}

  def episode_overlays(status) do
    for {{s, e}, meta} <- status.episodes,
        state = overlay_state(meta, status.queue),
        not is_nil(state),
        into: %{} do
      {"#{s}:#{e}", serialize(state)}
    end
  end

  defp overlay_state(%{id: id, has_file: has_file, monitored: monitored}, queue) do
    case find_record(queue, id) do
      nil -> if not has_file and monitored, do: :searching, else: nil
      record -> queue_record_state(record)
    end
  end

  @doc """
  Flattens a state to the JSON the native client renders:
  `%{kind: "downloading", percent: 42}` or `%{kind: "searching"}`.
  """
  def serialize({:downloading, pct}), do: %{kind: "downloading", percent: pct}
  def serialize(state) when is_atom(state), do: %{kind: to_string(state)}

  # A monitored episode with no queue record is still being searched
  # for; that's :searching, not "in queue."
  defp queue_state(queue, id) do
    case find_record(queue, id) do
      nil -> :searching
      record -> queue_record_state(record)
    end
  end

  defp find_record(queue, id) do
    Enum.find(queue, &(&1["episodeId"] == id or &1["movieId"] == id))
  end
end
