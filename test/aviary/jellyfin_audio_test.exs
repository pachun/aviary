defmodule Aviary.JellyfinAudioTest do
  use ExUnit.Case, async: true

  defp track(index, lang, channels, opts \\ []) do
    %{
      index: index,
      lang: lang,
      label: lang,
      channels: channels,
      default: Keyword.get(opts, :default, false),
      description?: Keyword.get(opts, :description?, false)
    }
  end

  test "picks English over a German default track and a Turkish 5.1 track" do
    futurama_disney_rip = [
      track(1, "deu", 2, default: true),
      track(2, "eng", 2),
      track(3, "spa", 2),
      track(10, "tur", 6)
    ]

    assert Aviary.Jellyfin.default_audio_index(futurama_disney_rip) == 2
  end

  test "picks the English track with the most channels" do
    assert Aviary.Jellyfin.default_audio_index([
             track(1, "eng", 2, default: true),
             track(2, "eng", 6)
           ]) == 2
  end

  test "falls back to channels then the default flag when nothing is English" do
    assert Aviary.Jellyfin.default_audio_index([
             track(1, "fra", 2, default: true),
             track(2, "deu", 6),
             track(3, "spa", 6, default: true)
           ]) == 3
  end

  test "skips an English audio-description track for the English dialogue track" do
    assert Aviary.Jellyfin.default_audio_index([
             track(1, "eng", 6, default: true, description?: true),
             track(2, "eng", 2)
           ]) == 2
  end

  test "returns nil for no tracks" do
    assert Aviary.Jellyfin.default_audio_index([]) == nil
  end
end
