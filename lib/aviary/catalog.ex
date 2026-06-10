defmodule Aviary.Catalog do
  @moduledoc """
  The catalog read model — list_shows/0 and list_movies/0 are the only
  things the UI talks to. Internally they hit Jellyfin via
  Aviary.Jellyfin and normalize each item to a small shape:

      %{
        id: String.t(),
        title: String.t(),
        year: integer() | {integer(), integer() | nil}
      }

  Year is an integer for movies, a `{start, finish}` tuple for shows
  (finish is nil for ongoing series). Poster URLs aren't on the item;
  the view builds them as `/image/:id` paths through aviary's own
  proxy controller, which avoids leaking the Jellyfin URL + API key
  to the browser and works in deployed environments where the
  container reaches Jellyfin over host.docker.internal but the
  browser can't.
  """

  def list_shows do
    Aviary.Jellyfin.list_shows()
    |> Enum.map(&to_show/1)
    |> enrich_with_ratings(:tv)
    |> Enum.sort_by(&sort_key/1)
  end

  def list_movies do
    Aviary.Jellyfin.list_movies()
    |> Enum.map(&to_movie/1)
    |> enrich_with_ratings(:movie)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Fetch a single movie with the fuller shape the detail page renders —
  title, year, runtime, MPAA rating, synopsis, trailer URL, RT scores.
  Returns `{:ok, movie}` or `:error` if the item doesn't exist.
  """
  def get_movie(id) do
    case Aviary.Jellyfin.get_item(id) do
      {:ok, item} ->
        movie =
          item
          |> to_movie_detail()
          |> Map.put(:rating, Aviary.RottenTomatoes.fetch(item["Name"], :movie))

        {:ok, movie}

      :error ->
        :error
    end
  end

  defp to_movie_detail(item) do
    %{
      id: item["Id"],
      title: item["Name"],
      year: item["ProductionYear"],
      runtime_minutes: runtime_minutes(item["RunTimeTicks"]),
      official_rating: item["OfficialRating"],
      genre: first_genre(item["Genres"]),
      synopsis: item["Overview"],
      trailer_url: first_trailer_url(item["RemoteTrailers"]),
      resume_seconds: resume_seconds(item["UserData"])
    }
  end

  # Returns seconds to resume from, or nil if there's no in-progress
  # playback worth resuming from. Jellyfin keeps a saved position even
  # after the item is fully watched (Played=true); we treat that as
  # "start over from the beginning" rather than offering a stale
  # resume point.
  defp resume_seconds(%{"PlaybackPositionTicks" => ticks, "Played" => true})
       when is_integer(ticks),
       do: nil

  defp resume_seconds(%{"PlaybackPositionTicks" => ticks}) when is_integer(ticks) and ticks > 0,
    do: ticks / 10_000_000

  defp resume_seconds(_), do: nil

  # First genre only — keeps the metadata line tight. Jellyfin returns
  # Genres as a list of strings ordered by primary classification.
  defp first_genre([genre | _]) when is_binary(genre), do: genre
  defp first_genre(_), do: nil

  # Jellyfin runtime is in 100ns ticks (1 minute = 600M ticks).
  defp runtime_minutes(nil), do: nil
  defp runtime_minutes(ticks) when is_integer(ticks), do: div(ticks, 600_000_000)
  defp runtime_minutes(_), do: nil

  defp first_trailer_url(trailers) when is_list(trailers) do
    case trailers do
      [%{"Url" => url} | _] -> url
      _ -> nil
    end
  end

  defp first_trailer_url(_), do: nil

  # Fan out RT lookups across items. Cache hits return instantly; cache
  # misses do an HTTP fetch, so concurrency keeps page load under
  # control on first-render-after-restart. Failures (item not on RT,
  # network blip) just leave the rating slot nil.
  defp enrich_with_ratings(items, type) do
    items
    |> Task.async_stream(
      fn item -> Map.put(item, :rating, Aviary.RottenTomatoes.fetch(item.title, type)) end,
      max_concurrency: 8,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, item} -> item
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp to_show(item) do
    %{
      type: :show,
      id: item["Id"],
      title: item["Name"],
      year: show_year(item)
    }
  end

  defp to_movie(item) do
    %{
      type: :movie,
      id: item["Id"],
      title: item["Name"],
      year: item["ProductionYear"]
    }
  end

  # Year-range for a show. Continuing shows get {start, nil}; ended
  # shows extract the year from the EndDate ISO8601 string.
  defp show_year(item) do
    start = item["ProductionYear"]

    case item["Status"] do
      "Continuing" ->
        {start, nil}

      "Ended" ->
        finish =
          case item["EndDate"] do
            nil -> nil
            date -> date |> String.slice(0, 4) |> String.to_integer()
          end

        {start, finish}

      _ ->
        {start, nil}
    end
  end

  # Sort by title with leading article stripped so "The Wire" lives
  # under W. Matches how print catalogs and library indices order.
  defp sort_key(%{title: title}) do
    title
    |> String.replace_prefix("The ", "")
    |> String.replace_prefix("A ", "")
    |> String.replace_prefix("An ", "")
    |> String.downcase()
  end
end
