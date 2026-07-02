defmodule Aviary.Trailer do
  @moduledoc """
  Resolves a YouTube trailer URL to a directly-playable stream the tvOS
  client's AVPlayer can open.

  AVPlayer / expo-video can't play a YouTube page, and there's no YouTube
  player for react-native-tvos, so `yt-dlp -g` extracts the underlying
  media URL. Two constraints shape the choices here:

    * We ask for a single *muxed* progressive MP4 (format 22 → 720p, 18 →
      360p). `-g` can only hand back a lone URL, so a video-only DASH
      format would arrive without audio; the muxed formats keep one URL
      with both. If neither exists yt-dlp exits non-zero and we surface
      nothing rather than a silent, audioless stream.

    * The Apple TV fetches the stream itself, from a different IP than the
      aviary host that resolved it. The `android` player client's URLs
      aren't IP-locked, so the resolved URL stays playable off-box.

  Resolution runs `yt-dlp` fresh per request — the extracted URLs are
  short-lived, so caching them courts stale-link playback failures.
  """
  require Logger

  @youtube ~r{^https?://(www\.)?(youtube\.com|youtu\.be)/}i
  @format "22/18"
  @player_client "android"

  @doc """
  Resolves a YouTube URL to a playable stream URL. Returns `{:ok, url}` or
  `:error` for anything that isn't a YouTube link, a yt-dlp failure, or a
  missing `yt-dlp` binary.
  """
  def stream_url(url) when is_binary(url) do
    if Regex.match?(@youtube, url), do: resolve(url), else: :error
  end

  def stream_url(_), do: :error

  defp resolve(url) do
    case System.cmd("yt-dlp", args(url)) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.first() do
          nil -> :error
          stream -> {:ok, stream}
        end

      {output, code} ->
        Logger.warning("yt-dlp exited #{code} for #{url}: #{output}")
        :error
    end
  rescue
    error ->
      Logger.warning("yt-dlp unavailable: #{inspect(error)}")
      :error
  end

  defp args(url) do
    [
      "--extractor-args",
      "youtube:player_client=#{@player_client}",
      "-f",
      @format,
      "-g",
      url
    ]
  end
end
