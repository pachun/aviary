defmodule Aviary.WatchTimeEstimate do
  @moduledoc """
  Rough estimate of "minutes from clicking Watch to actually being able
  to watch this." Surfaced as a quiet line under the action button on
  pre-download (`:ready`) states.

  Conservative on purpose. Under-estimating reads as a bug ("you said
  3 minutes, it's been 8") more than over-estimating ("you said 8, ready
  in 4 — nice").

  Three components:
    - Search/grab handoff (~1 min) — indexer queries + first bytes from
      SAB/qBit
    - Download — file_size / network_speed
    - Import (~1 min) — par2 repair + extraction + Sonarr/Radarr move

  File size derived from runtime + 1080p web-dl bitrate assumption
  (~6 Mbps, which is on the heavier side of web-dl encodes). Network
  speed assumes ~50 MB/s sustained — a home gigabit fiber pipe on
  Usenet. Adjust the constants if your tank lives on a slower pipe;
  the goal is "right order of magnitude," not seconds-accurate.
  """

  # 1080p web-dl is typically 4–8 Mbps; use 6 as a mid-conservative
  # assumption. 4K would be 20+, but we don't model quality choices
  # here — pretending 1080p will over-estimate 4K and under-estimate
  # 720p, both within the "roughly" framing.
  @bitrate_mbps 6

  # 50 MB/s × 8 = 400 Mbps. Typical good-day Usenet on home gigabit.
  # On a constrained pipe (100 Mbps), bump this to 100 to stretch
  # estimates accordingly.
  @network_mbps 400

  @search_overhead_min 1
  @import_overhead_min 1

  # Floor so we never claim "0 minutes" — even a tiny episode has
  # search + import overhead to wait through.
  @minimum_min 2

  @doc """
  Estimated minutes until a freshly-clicked Watch is playable.

  Returns nil for invalid input (nil, zero, non-integer runtime) so
  callers can hide the label rather than render a nonsense estimate.
  """
  def for_runtime(runtime_minutes) when is_integer(runtime_minutes) and runtime_minutes > 0 do
    file_megabits = runtime_minutes * 60 * @bitrate_mbps
    download_seconds = file_megabits / @network_mbps
    overhead_seconds = (@search_overhead_min + @import_overhead_min) * 60
    total_minutes = ceil((download_seconds + overhead_seconds) / 60)

    max(total_minutes, @minimum_min)
  end

  def for_runtime(_), do: nil
end
