defmodule Aviary.JellyfinManifestTest do
  use ExUnit.Case, async: false

  @item "926e92bf22f6bdf5ada4fcf6672b6aa5"
  @token "tok"
  @public_jellyfin "https://watch.example.test"

  setup do
    previous_url = Application.get_env(:aviary, :jellyfin_url)
    previous_public_url = Application.get_env(:aviary, :jellyfin_public_url)
    Application.put_env(:aviary, :jellyfin_url, "http://jellyfin.internal:8096")
    Application.put_env(:aviary, :jellyfin_public_url, @public_jellyfin)

    on_exit(fn ->
      Application.put_env(:aviary, :jellyfin_url, previous_url)
      Application.put_env(:aviary, :jellyfin_public_url, previous_public_url)
    end)

    :ok
  end

  @variant ~s(#EXT-X-STREAM-INF:BANDWIDTH=7756000,CODECS="avc1.424029,mp4a.40.2",RESOLUTION=1920x1080,SUBTITLES="subs")

  test "drops the SUBTITLES group reference when no English rendition survives" do
    hebrew_only =
      Enum.join(
        [
          "#EXTM3U",
          ~s(#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Hebrew",DEFAULT=NO,AUTOSELECT=YES,URI="#{@item}/Subtitles/4/subtitles.m3u8",LANGUAGE="heb"),
          @variant,
          "main.m3u8?api_key=#{@token}"
        ],
        "\n"
      )

    rewritten = Aviary.Jellyfin.rewrite_manifest(hebrew_only, @item, @token, false)

    refute rewritten =~ "TYPE=SUBTITLES"
    refute rewritten =~ "SUBTITLES="
    assert rewritten =~ "RESOLUTION=1920x1080\n"
    assert rewritten =~ "#{@public_jellyfin}/Videos/#{@item}/main.m3u8?api_key=#{@token}"
  end

  test "keeps the SUBTITLES group when an English rendition survives" do
    with_english =
      Enum.join(
        [
          "#EXTM3U",
          ~s(#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="#{@item}/Subtitles/2/subtitles.m3u8",LANGUAGE="eng"),
          @variant,
          "main.m3u8?api_key=#{@token}"
        ],
        "\n"
      )

    rewritten = Aviary.Jellyfin.rewrite_manifest(with_english, @item, @token, false)

    assert rewritten =~ ~s(SUBTITLES="subs")
    assert rewritten =~ ~s(LANGUAGE="eng")
    assert rewritten =~ "DEFAULT=NO"
    assert rewritten =~ "/api/v1/items/#{@item}/subtitles/2/playlist.m3u8?token=#{@token}"
  end
end
