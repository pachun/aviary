defmodule Aviary.Catalog do
  @moduledoc """
  The catalog read model — list_shows/1, list_movies/1, and
  get_movie/2 are the only things the UI talks to. Every function takes
  the current user's auth context (an `%{id, token, ...}` map from
  Aviary.Auth) so reads are scoped to that user — UserData (resume
  position, played state) is per-user.
  """

  def list_shows(auth) do
    Aviary.Jellyfin.list_shows(auth)
    |> Enum.map(&to_show/1)
    |> enrich_with_ratings(:tv)
    |> Enum.sort_by(&sort_key/1)
  end

  def list_movies(auth) do
    Aviary.Jellyfin.list_movies(auth)
    |> Enum.map(&to_movie/1)
    |> enrich_with_ratings(:movie)
    |> Enum.sort_by(&sort_key/1)
  end

  def get_movie(id, auth) do
    case Aviary.Jellyfin.get_item(id, auth) do
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

  defp first_genre([genre | _]) when is_binary(genre), do: genre
  defp first_genre(_), do: nil

  defp resume_seconds(%{"PlaybackPositionTicks" => ticks, "Played" => true})
       when is_integer(ticks),
       do: nil

  defp resume_seconds(%{"PlaybackPositionTicks" => ticks}) when is_integer(ticks) and ticks > 0,
    do: ticks / 10_000_000

  defp resume_seconds(_), do: nil

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

  defp sort_key(%{title: title}) do
    title
    |> String.replace_prefix("The ", "")
    |> String.replace_prefix("A ", "")
    |> String.replace_prefix("An ", "")
    |> String.downcase()
  end
end
