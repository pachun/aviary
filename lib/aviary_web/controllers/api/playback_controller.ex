defmodule AviaryWeb.API.PlaybackController do
  @moduledoc """
  Playback for native clients (tvOS). `show` hands back everything the
  player needs to start an item: the HLS master URL (built against the
  public Jellyfin URL with the user's token embedded, same as the web
  player), the Intro Skipper segment, and the available audio/subtitle
  tracks. `progress` accepts periodic position reports and routes them
  through the same `Aviary.Jellyfin.report_progress/4` the LiveView
  player uses, so resume + Continue Watching stay consistent across
  clients.

  Items are addressed by their raw Jellyfin id — the same id works for
  both episodes and movies.
  """
  use AviaryWeb, :controller

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    audio = Aviary.Jellyfin.audio_streams(id, user)

    json(conn, %{
      streamUrl: Aviary.Jellyfin.hls_url(id, user),
      intro: intro(Aviary.Jellyfin.segments(id, user)),
      audioTracks: Enum.map(audio, &audio_track/1),
      defaultAudioIndex: Aviary.Jellyfin.default_audio_index(audio),
      subtitles: Enum.map(Aviary.Jellyfin.subtitle_streams(id, user), &subtitle(&1, id, user))
    })
  end

  def progress(conn, %{"id" => id, "position" => position})
      when is_number(position) do
    user = conn.assigns.current_user
    duration = conn.params["duration"]

    state = Aviary.Jellyfin.report_progress(id, position, duration, user)
    json(conn, %{status: to_string(state)})
  end

  def progress(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "position_required"})
  end

  defp intro(%{introduction: %{start: start_s, end: end_s}}),
    do: %{start: start_s, end: end_s}

  defp intro(_), do: nil

  defp audio_track(track) do
    %{
      index: track.index,
      lang: track.lang,
      label: track.label,
      default: track.default,
      description: track.description?
    }
  end

  defp subtitle(track, item_id, user) do
    %{
      index: track.index,
      lang: track.lang,
      label: track.label,
      default: track.default,
      url: Aviary.Jellyfin.subtitle_url(item_id, track.index, user)
    }
  end
end
