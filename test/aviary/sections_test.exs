defmodule Aviary.SectionsTest do
  use ExUnit.Case, async: false

  alias Aviary.{Live, Series}

  @user %{id: "viewer"}

  setup do
    path =
      Path.join(System.tmp_dir!(), "aviary-sections-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(path)
      Application.delete_env(:aviary, :sections_file)
      Aviary.Cache.invalidate({:sections, path})
    end)

    %{path: path}
  end

  describe "a server with no sections file" do
    test "calls its live section NHL and brings standings with it" do
      assert Live.label() == "NHL"
      assert Live.sports?()
    end

    test "calls its series section Daily Wire and lists those shows" do
      assert Series.label() == "Daily Wire"
      assert [%{slug: "the-ben-shapiro-show", title: "Shapiro"} | _] = Series.shows()
    end
  end

  describe "credits" do
    test "a server with no sections file credits TMDB alone" do
      assert [tmdb] = Aviary.Credits.all()
      assert tmdb =~ "TMDB"
    end

    test "a server's own credits follow TMDB's", %{path: path} do
      define(path, %{credits: ["Sintel © Blender Foundation, CC BY 3.0", 7]})

      assert [tmdb, "Sintel © Blender Foundation, CC BY 3.0"] = Aviary.Credits.all()
      assert tmdb =~ "TMDB"
    end
  end

  describe "a server that defines its own live section" do
    setup %{path: path} do
      define(path, %{
        live: %{
          label: "Live",
          events: [
            %{
              id: "launch",
              title: "Launch coverage",
              time: "Live now",
              images: ["https://media.test/still.png"],
              feeds: [%{id: "main", label: "Watch", url: "https://media.test/live.m3u8"}]
            }
          ]
        }
      })
    end

    test "names the section and offers no standings" do
      assert Live.label() == "Live"
      refute Live.sports?()
    end

    test "lists its events without giving away where the feeds are" do
      assert [
               %{
                 id: "launch",
                 title: "Launch coverage",
                 time: "Live now",
                 images: ["https://media.test/still.png"],
                 feeds: [%{id: "main", label: "Watch"} = feed]
               }
             ] = Live.events()

      refute Map.has_key?(feed, :url)
    end

    test "plays a feed straight from the address the file gives" do
      assert Live.feed("launch", "main") == {:ok, {:direct, "https://media.test/live.m3u8"}}
      assert Live.feed("launch", "other") == {:error, :unavailable}
      assert Live.feed("nothing", "main") == {:error, :unavailable}
    end
  end

  describe "a server that defines its own series section" do
    setup %{path: path} do
      define(path, %{
        series: %{
          label: "Shows",
          shows: [
            %{
              slug: "open-movies",
              title: "Open movies",
              episodes: [
                %{
                  id: "older",
                  title: "Older",
                  publishedAt: "2018-01-01T00:00:00Z",
                  duration: 600,
                  url: "https://media.test/older.mp4"
                },
                %{
                  id: "newer",
                  title: "Newer",
                  publishedAt: "2019-04-04T00:00:00Z",
                  duration: 464,
                  url: "https://media.test/newer.m3u8"
                }
              ]
            }
          ]
        }
      })
    end

    test "names the section, shows it to everyone, and lists its shows" do
      assert Series.label() == "Shows"
      assert Series.allowed?(@user)
      assert Series.shows() == [%{slug: "open-movies", title: "Open movies"}]
    end

    test "lists a show's episodes newest first with the viewer's progress" do
      assert {:ok, %{episodes: [newer, older], nextPage: nil}} =
               Series.episodes(@user, "open-movies")

      assert %{
               id: "newer",
               title: "Newer",
               durationLabel: "8 min",
               memberOnly: false,
               progress: %{watched: false}
             } = newer

      assert older.id == "older"
      assert Series.episodes(@user, "unknown") == {:error, :not_found}
    end

    test "plays an episode from the address the file gives" do
      assert {:ok,
              %{
                streamUrl: "https://media.test/newer.m3u8",
                contentType: "hls",
                progress: %{sessionId: _}
              }} =
               Series.playback(@user, "newer")

      assert {:ok, %{contentType: "progressive"}} = Series.playback(@user, "older")
      assert Series.playback(@user, "unknown") == {:error, :playback_unavailable}
    end
  end

  defp define(path, sections) do
    File.write!(path, Jason.encode!(sections))
    Application.put_env(:aviary, :sections_file, path)
    Aviary.Cache.invalidate({:sections, path})
    :ok
  end
end
