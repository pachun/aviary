defmodule Aviary.Trailer do
  @moduledoc """
  Resolves a YouTube trailer URL to a directly-playable stream the tvOS
  client's AVPlayer can open.

  AVPlayer / expo-video can't play a YouTube page, and there's no YouTube
  player for react-native-tvos, so `yt-dlp -g` extracts the underlying
  media URL. Two constraints shape the choices here:

    * `-g` hands back a lone URL, so the stream has to carry both audio and
      video in one place. YouTube's split (DASH) video/audio can't be
      merged without downloading, so we lean on formats that are already
      one URL: the iOS player client's **HLS** variants (H.264, up to
      1080p — what AVPlayer wants), falling back to the muxed MP4 formats
      (22 → 720p, 18 → 360p) when HLS isn't offered. Muxed MP4 alone caps
      at 720p/360p, which is why HLS is preferred.

    * The Apple TV fetches the stream itself, from a different IP than the
      aviary host that resolved it. The `ios`/`android` player clients'
      URLs aren't IP-locked, so the resolved URL stays playable off-box.

  Resolution runs `yt-dlp` fresh per request — the extracted URLs are
  short-lived, so caching them courts stale-link playback failures.
  """
  require Logger

  @youtube ~r{^https?://(www\.)?(youtube\.com|youtu\.be)/}i
  @player_clients "ios,android"
  @format "b[protocol^=m3u8][height<=1080]/b[protocol^=m3u8]/22/18"

  @doc """
  Resolves a YouTube URL to a playable stream. Returns
  `{:ok, %{url: url, content_type: "hls" | "progressive"}}`, or `:error`
  for anything that isn't a YouTube link, a yt-dlp failure, or a missing
  `yt-dlp` binary.
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
          stream -> {:ok, %{url: stream, content_type: content_type(stream)}}
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

  # HLS resolves to a googlevideo manifest URL; the muxed MP4 formats
  # resolve to a plain videoplayback URL. The client needs to know which
  # so it can tell AVPlayer how to read the source.
  defp content_type(url) do
    if String.contains?(url, "m3u8") or String.contains?(url, "/manifest/hls"),
      do: "hls",
      else: "progressive"
  end

  defp args(url) do
    [
      "--extractor-args",
      "youtube:player_client=#{@player_clients}",
      "-f",
      @format,
      "-g",
      url
    ]
  end
end
