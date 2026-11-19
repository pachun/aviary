defmodule Aviary.Sections do
  @moduledoc """
  Sections a server can define for itself in a JSON file: a list of
  live events, and a set of series with their episodes. Named by
  `SECTIONS_FILE`. A server without the file gets its live events from
  the NHL schedule and its series from Daily Wire.

      {
        "live": {
          "label": "Live",
          "events": [
            {"id": "launch", "title": "Launch coverage", "time": "Live now",
             "images": ["https://…/still.png"],
             "feeds": [{"id": "main", "label": "Watch", "url": "https://…/live.m3u8"}]}
          ]
        },
        "series": {
          "label": "Shows",
          "shows": [
            {"slug": "open-movies", "title": "Open movies",
             "episodes": [{"id": "spring", "title": "Spring", "description": "…",
                           "image": "https://…/spring.jpg", "publishedAt": "2019-04-04T00:00:00Z",
                           "duration": 464, "url": "https://…/spring.mp4"}]}
          ]
        }
      }
  """

  require Logger

  @reread_after_ms :timer.minutes(1)

  @doc "The file's `live` section, or `nil` when the server defines none."
  def live, do: section("live")

  @doc "The file's `series` section, or `nil` when the server defines none."
  def series, do: section("series")

  defp section(name) do
    case defined() do
      %{^name => %{} = section} -> section
      _ -> nil
    end
  end

  defp defined do
    case Application.get_env(:aviary, :sections_file) do
      path when is_binary(path) and path != "" ->
        Aviary.Cache.fetch({:sections, path}, @reread_after_ms, fn -> read(path) end)

      _ ->
        %{}
    end
  end

  defp read(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = defined} <- Jason.decode(contents) do
      defined
    else
      {:error, :enoent} ->
        %{}

      problem ->
        Logger.warning("sections file #{path} can't be used: #{inspect(problem)}")
        %{}
    end
  end
end
