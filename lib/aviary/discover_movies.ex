defmodule Aviary.DiscoverMovies do
  @moduledoc """
  Discover Movies read-model — the rows the movie side of Discover
  renders, from Jellyseerr's TMDB proxy.

  Every movie in every row can be watched at home today and is well
  liked: it has a US digital or disc release on or before today, and at
  least 60 from both Rotten Tomatoes critics and audiences. TMDB's
  watch-provider filter alone isn't enough to prove a home release — a
  movie still in theaters can list a digital pre-order — so each
  candidate's US release dates are checked too. On a server set up
  without ratings, the Rotten Tomatoes requirement is dropped rather
  than emptying every row.

  Rows: newly released at home, the best of the last year, picks for
  the movie the viewer watched last, then a handful of genres.
  """

  alias Aviary.{Jellyfin, Jellyseerr, RottenTomatoes, TmdbResult}

  @row_length 20
  @us_region "US"
  @us_home_viewing_providers [2, 3, 7, 8, 9, 10, 15, 192, 337, 350, 386, 531, 1899]
  @digital_release_type 4
  @physical_release_type 5
  @home_release_types [@digital_release_type, @physical_release_type]
  @least_score_to_feature 60
  @least_votes_to_feature 100
  @newly_released_days 90
  @newly_released_theatrical_window_days 365
  @last_year_days 365
  @genre_window_days 3 * 365
  @candidate_pages 1..3
  @lookups_at_once 8
  @lookup_timeout_ms 15_000

  @genres [
    {"Action", 28},
    {"Comedy", 35},
    {"Drama", 18},
    {"Thriller", 53},
    {"Science fiction", 878},
    {"Animation", 16}
  ]

  @doc """
  The rows to render for this viewer, as `{label, row}` in display
  order. `row` is what `fetch_row/2` takes. Cheap — it only looks up the
  viewer's last watched movie — so pages can paint labels at once and
  fill each row as it arrives.
  """
  def rows(user) do
    headline_rows() ++ because_you_watched_rows(user) ++ genre_rows()
  end

  defp headline_rows,
    do: [{"Newly released", :newly_released}, {"Best of the last year", :best_of_the_last_year}]

  defp genre_rows, do: Enum.map(@genres, fn {label, genre_id} -> {label, {:genre, genre_id}} end)

  defp because_you_watched_rows(user) do
    case last_watched_movie(user) do
      %{"Name" => title, "ProviderIds" => %{"Tmdb" => tmdb_id}} when is_binary(tmdb_id) ->
        [{"Because you watched #{title}", {:because_you_watched, tmdb_id}}]

      _ ->
        []
    end
  end

  defp last_watched_movie(user) do
    user
    |> Jellyfin.recently_watched()
    |> Enum.find(&(&1["Type"] == "Movie"))
  rescue
    _ -> nil
  end

  @doc "One row's movies as marquee items, each carrying its Rotten Tomatoes rating."
  def fetch_row(row, today \\ Date.utc_today())

  def fetch_row(:newly_released, today) do
    released_at_home_since = Date.add(today, -@newly_released_days)

    [
      primaryReleaseDateGte:
        Date.to_iso8601(Date.add(today, -@newly_released_theatrical_window_days)),
      sortBy: "popularity.desc"
    ]
    |> discovered()
    |> vetted(today)
    |> Enum.filter(&(Date.compare(&1.home_release, released_at_home_since) != :lt))
    |> Enum.sort_by(& &1.result["popularity"], :desc)
    |> to_items()
  end

  def fetch_row(:best_of_the_last_year, today) do
    [
      primaryReleaseDateGte: Date.to_iso8601(Date.add(today, -@last_year_days)),
      voteCountGte: @least_votes_to_feature,
      sortBy: "vote_average.desc"
    ]
    |> discovered()
    |> vetted(today)
    |> Enum.sort_by(&combined_score/1, :desc)
    |> to_items()
  end

  def fetch_row({:because_you_watched, tmdb_id}, today) do
    case Jellyseerr.recommendations(:movie, tmdb_id) do
      {:ok, results} -> results |> vetted(today) |> to_items()
      _ -> []
    end
  end

  def fetch_row({:genre, genre_id}, today) do
    [
      genre: genre_id,
      primaryReleaseDateGte: Date.to_iso8601(Date.add(today, -@genre_window_days)),
      voteCountGte: @least_votes_to_feature,
      sortBy: "popularity.desc"
    ]
    |> discovered()
    |> vetted(today)
    |> to_items()
  end

  defp discovered(params) do
    home_viewing_params = [
      watchRegion: @us_region,
      watchProviders: Enum.join(@us_home_viewing_providers, "|")
    ]

    @candidate_pages
    |> Enum.flat_map(fn page ->
      case Jellyseerr.discover_movies(params ++ home_viewing_params ++ [page: page]) do
        {:ok, results} -> results
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp vetted(results, today) do
    results
    |> Enum.filter(&TmdbResult.has_backdrop?/1)
    |> Task.async_stream(&with_home_release_and_rating(&1, today),
      max_concurrency: @lookups_at_once,
      timeout: @lookup_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %{} = candidate} -> [candidate]
      _ -> []
    end)
    |> Enum.filter(&well_liked?/1)
  end

  defp with_home_release_and_rating(result, today) do
    with {:ok, details} <- Jellyseerr.get_movie(result["id"]),
         %Date{} = home_release <- us_home_release(details, today) do
      %{
        result: result,
        home_release: home_release,
        rating: rating(result, details)
      }
    else
      _ -> nil
    end
  end

  defp us_home_release(details, today) do
    details
    |> get_in(["releases", "results"])
    |> List.wrap()
    |> Enum.filter(&(&1["iso_3166_1"] == @us_region))
    |> Enum.flat_map(&List.wrap(&1["release_dates"]))
    |> Enum.filter(&(&1["type"] in @home_release_types))
    |> Enum.flat_map(&release_date/1)
    |> Enum.filter(&(Date.compare(&1, today) != :gt))
    |> Enum.min(Date, fn -> nil end)
  end

  defp release_date(%{"release_date" => <<date::binary-size(10), _rest::binary>>}) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> [parsed]
      _ -> []
    end
  end

  defp release_date(_), do: []

  defp rating(result, details) do
    item = TmdbResult.marquee_item(result, :movie)
    RottenTomatoes.fetch(item.title, :movie, item.year, details["imdbId"])
  end

  defp well_liked?(%{rating: %{critic: critic, audience: audience}}),
    do: critic >= @least_score_to_feature and audience >= @least_score_to_feature

  defp well_liked?(_unrated), do: not RottenTomatoes.offered?()

  defp combined_score(%{rating: %{critic: critic, audience: audience}}), do: critic + audience
  defp combined_score(_unrated), do: 0

  defp to_items(candidates) do
    candidates
    |> Enum.take(@row_length)
    |> Enum.map(fn candidate ->
      candidate.result
      |> TmdbResult.marquee_item(:movie)
      |> Map.put(:rating, candidate.rating)
    end)
  end
end
