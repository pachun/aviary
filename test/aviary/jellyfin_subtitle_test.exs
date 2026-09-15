defmodule Aviary.JellyfinSubtitleTest do
  use ExUnit.Case, async: true

  test "strips SubStation Alpha override tags from WebVTT cues" do
    vtt =
      Enum.join(
        [
          "WEBVTT",
          "",
          "00:06:09.577 --> 00:06:11.162 region:subtitle line:90%",
          "{\\an8}<i>Go faster.</i>",
          "",
          "00:06:11.162 --> 00:06:14.332 region:subtitle line:90%",
          "{\\an8}{\\i1}Let's go!{\\i0}"
        ],
        "\n"
      )

    stripped = Aviary.Jellyfin.strip_ass_override_tags(vtt)

    refute stripped =~ "{\\"
    assert stripped =~ "00:06:09.577 --> 00:06:11.162 region:subtitle line:90%\n<i>Go faster.</i>"
    assert stripped =~ "00:06:11.162 --> 00:06:14.332 region:subtitle line:90%\nLet's go!"
  end

  test "leaves braces that are part of the dialogue alone" do
    vtt = "00:00:01.000 --> 00:00:02.000\nThe set {1, 2, 3} is finite."

    assert Aviary.Jellyfin.strip_ass_override_tags(vtt) == vtt
  end
end
