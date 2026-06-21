defmodule Aviary.WatchProgress do
  @moduledoc """
  Builds the "until in your library" line shown beneath the action
  button on show / movie detail pages. The label tracks the state
  machine:

    :ready (pre-download)    → static estimate from runtime
                               ("Roughly 4 minutes until in your library")
    :searching               → "Searching for a release"
    {:downloading, _}        → live duration from queue.timeleft + import
                               buffer, refreshed each Sonarr/Radarr poll
                               ("Roughly 3 minutes until in your library")
    :imported                → "Almost in your library"
    other / no signal        → nil (caller hides the line)

  Sonarr/Radarr's `timeleft` field is parsed from its
  ".NET TimeSpan" string ("HH:MM:SS" or "DD.HH:MM:SS") into total
  seconds; an import buffer is added on top to account for par2 repair,
  unrar, and the Sonarr/Radarr move + Jellyfin scan that follow the
  download itself.
  """

  alias Aviary.WatchTimeEstimate

  # Padding added to download timeleft for post-download work: par2
  # repair, unrar, Sonarr/Radarr renames, and the Jellyfin scan that
  # makes the file actually playable. 60s is conservative for most
  # files; cuts to ~5–15s on the smallest episodes but the framing
  # rounds to "less than a minute" anyway in those cases.
  @import_buffer_seconds 60

  @doc """
  Build the label string for a given state.

    state           — one of the show/movie state-machine atoms/tuples
    runtime_minutes — integer or nil
    timeleft_sec    — integer seconds (parsed from queue.timeleft) or nil
  """
  def label(state, runtime_minutes, timeleft_sec \\ nil)

  def label(:ready, runtime_minutes, _timeleft) do
    case WatchTimeEstimate.for_runtime(runtime_minutes) do
      nil -> nil
      n -> "Roughly #{n} minutes until in your library"
    end
  end

  def label(:searching, _runtime, _timeleft), do: "Searching for a release"

  def label({:downloading, _pct}, _runtime, timeleft_sec)
      when is_integer(timeleft_sec) and timeleft_sec > 0 do
    duration_phrase(timeleft_sec + @import_buffer_seconds) <>
      " until in your library"
  end

  # No timeleft signal yet — Sonarr/Radarr hasn't published one (e.g.,
  # the queue record just appeared with 0 bytes downloaded). Stay quiet
  # rather than show a misleading "Less than a minute".
  def label({:downloading, _pct}, _runtime, _timeleft), do: nil

  def label(:imported, _runtime, _timeleft), do: "Almost in your library"

  def label(_, _, _), do: nil

  @doc """
  Parse a Sonarr/Radarr `timeleft` string (.NET TimeSpan format) into
  total seconds. Examples:
    "00:13:42"      → 822
    "1.05:30:00"    → 106200  (1 day 5h30m)
  Returns nil on nil / malformed input.
  """
  def parse_timeleft(str) when is_binary(str) do
    case Regex.run(~r/^(?:(\d+)\.)?(\d+):(\d+):(\d+)/, str) do
      [_, day_str, h_str, m_str, s_str] ->
        days = if day_str == "" or is_nil(day_str), do: 0, else: String.to_integer(day_str)
        days * 86_400 +
          String.to_integer(h_str) * 3600 +
          String.to_integer(m_str) * 60 +
          String.to_integer(s_str)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def parse_timeleft(_), do: nil

  # Friendly bucket from total seconds. Designed for the duration to
  # READ naturally regardless of magnitude — never "0 minutes," never
  # "1 minutes," never exact-seconds. Round to nearest minute (not
  # truncate) so 89s → 1 → "about a minute" and 91s → 2 → "roughly 2".
  defp duration_phrase(seconds) when seconds < 60, do: "Less than a minute"
  defp duration_phrase(seconds) when seconds <= 90, do: "About a minute"
  defp duration_phrase(seconds) when seconds < 3600 do
    "Roughly #{round(seconds / 60)} minutes"
  end

  defp duration_phrase(seconds) when seconds < 7200, do: "About an hour"
  defp duration_phrase(seconds), do: "Roughly #{round(seconds / 3600)} hours"
end
