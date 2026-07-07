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
    record_engagement(id, user)
    audio = Aviary.Jellyfin.audio_streams(id, user)

    json(conn, %{
      streamUrl: "/api/v1/items/#{id}/hls.m3u8",
      intro: intro(Aviary.Jellyfin.segments(id, user)),
      audioTracks: Enum.map(audio, &audio_track/1),
      defaultAudioIndex: Aviary.Jellyfin.default_audio_index(audio),
      subtitles: Enum.map(Aviary.Jellyfin.subtitle_streams(id, user), &subtitle(&1, id, user)),
      # The manifest's DEFAULT flag can't turn subtitles on for tvOS
      # AVPlayer (it drives legible selection off device accessibility
      # settings, not the playlist), so the native client applies the
      # saved default by selecting the subtitle track itself on load.
      subtitleDefault: Aviary.Preferences.subtitles_default?(user.id)
    })
  end

  # Playing a title is an engagement signal — it belongs in the user's
  # library so Continue Watching and the Shows / Movies tabs surface it,
  # the same thing the web detail page does on its Watch button. Native
  # playback was the only play path not recording this, so a user who
  # only ever watches through the tvOS client never built a library.
  # Fire-and-forget: playback must not wait on the lookup.
  defp record_engagement(item_id, user) do
    Task.start(fn -> add_to_library(item_id, user) end)
  end

  defp add_to_library(item_id, user) do
    case Aviary.Jellyfin.get_item(item_id, user) do
      {:ok, %{"Type" => "Movie", "ProviderIds" => %{"Tmdb" => tmdb}}}
      when is_binary(tmdb) and tmdb != "" ->
        Aviary.Library.add(user.id, tmdb)

      {:ok, %{"Type" => "Episode", "SeriesId" => series_id}}
      when is_binary(series_id) ->
        case Map.get(Aviary.Jellyfin.series_tmdb_map([series_id], user), series_id) do
          tmdb when is_binary(tmdb) and tmdb != "" -> Aviary.Library.add(user.id, tmdb)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  def manifest(conn, %{"id" => id}) do
    user = conn.assigns.current_user
    subtitles_on = Aviary.Preferences.subtitles_default?(user.id)

    case Aviary.Jellyfin.hls_manifest(id, user, subtitles_on) do
      {:ok, playlist} ->
        conn
        |> put_resp_content_type("application/vnd.apple.mpegurl")
        |> send_resp(200, playlist)

      :error ->
        conn |> put_status(:bad_gateway) |> json(%{error: "manifest_unavailable"})
    end
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
