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

  @doc """
  Fetch a single show with episodes, next-up, and RT scores. Episode
  list is grouped by season and ordered so the UI can render straight
  from `episodes_by_season` without further sorting.
  """
  def get_show(id, auth) do
    case Aviary.Jellyfin.get_item(id, auth) do
      {:ok, item} ->
        episodes = Aviary.Jellyfin.list_episodes(id, auth)

        episodes_by_season = group_episodes(episodes)

        # Prefer the in-progress episode (one with a saved resume
        # position) over Jellyfin's NextUp response. NextUp's logic
        # can disagree with what the home page surfaces when there
        # are mid-watch episodes in earlier seasons — the user
        # expects "Continue Watching" on the detail page to point at
        # the same episode the home marquee does.
        next_up =
          first_in_progress(episodes_by_season) ||
            case Aviary.Jellyfin.next_up(id, auth) do
              {:ok, ep} -> to_episode(ep)
              :none -> nil
            end

        show =
          item
          |> to_show_detail()
          |> Map.put(:episodes_by_season, episodes_by_season)
          |> Map.put(:next_up, next_up)
          |> Map.put(:season_count, episodes_by_season |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length())
          |> Map.put(:rating, Aviary.RottenTomatoes.fetch(item["Name"], :tv))

        {:ok, show}

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

  # Resume from saved position when there is one. We use PlayedPercentage
  # to skip items that are basically finished (>= 95% in) — Jellyfin
  # sometimes leaves a position behind on completion, and seeking the
  # user to the last few seconds of credits isn't useful.
  #
  # We deliberately don't gate on the `Played` flag: that flag latches
  # from any past completion and stays true on subsequent rewatches, so
  # gating on it loses the resume position the moment the user starts a
  # rewatch.
  defp resume_seconds(%{"PlayedPercentage" => pct}) when is_number(pct) and pct >= 95,
    do: nil

  defp resume_seconds(%{"PlaybackPositionTicks" => ticks}) when is_integer(ticks) and ticks > 0,
    do: ticks / 10_000_000

  defp resume_seconds(_), do: nil

  defp to_show_detail(item) do
    %{
      id: item["Id"],
      title: item["Name"],
      year: show_year(item),
      status: item["Status"],
      official_rating: item["OfficialRating"],
      genre: first_genre(item["Genres"]),
      synopsis: item["Overview"],
      trailer_url: first_trailer_url(item["RemoteTrailers"])
    }
  end

  defp to_episode(item) do
    %{
      id: item["Id"],
      title: item["Name"],
      season: item["ParentIndexNumber"],
      episode: item["IndexNumber"],
      runtime_minutes: runtime_minutes(item["RunTimeTicks"]),
      resume_seconds: resume_seconds(item["UserData"]),
      last_played_at: parse_date(get_in(item, ["UserData", "LastPlayedDate"]))
    }
  end

  # Sort fallback so episodes with no parsed LastPlayedDate sort last
  # rather than crashing the DateTime comparator.
  @epoch ~U[1970-01-01 00:00:00Z]

  # Pick the most recently watched in-progress episode. The earlier
  # implementation used `Enum.find` which returned the lowest season+
  # episode order, so an old leftover position on S1E3 would win over
  # an actively-being-watched S1E4. Sorting by last_played_at fixes
  # that — the home page surfaces the same episode by recency, and
  # now the detail page agrees.
  defp first_in_progress(episodes_by_season) do
    episodes_by_season
    |> Enum.flat_map(fn {_season, eps} -> eps end)
    |> Enum.filter(& &1.resume_seconds)
    |> Enum.sort_by(&(&1.last_played_at || @epoch), {:desc, DateTime})
    |> List.first()
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  # Groups raw Jellyfin episode items by season number, sorts seasons
  # and episodes within each season. Returns a list of {season, [eps]}
  # tuples — ready for the template to iterate without further sorting.
  defp group_episodes(episodes) do
    episodes
    |> Enum.map(&to_episode/1)
    |> Enum.reject(&is_nil(&1.season))
    |> Enum.group_by(& &1.season)
    |> Enum.sort_by(fn {season, _} -> season end)
    |> Enum.map(fn {season, eps} ->
      {season, Enum.sort_by(eps, &(&1.episode || 0))}
    end)
  end

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
