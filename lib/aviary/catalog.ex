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
      id: item["Id"],
      title: item["Name"],
      year: show_year(item)
    }
  end

  defp to_movie(item) do
    %{
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
