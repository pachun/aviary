defmodule Aviary.MoreLikeThis do
  @moduledoc """
  The "More like this" row on a show or movie detail page, whether or
  not its titles are in the library yet.

  Claude chooses the titles (see `Aviary.MoreLikeThis.Picks`), TMDB
  supplies their artwork, and poorly reviewed ones are dropped. The
  finished row is kept, so only the first visit to a title waits, and
  rows for the library are filled in ahead of any visit. When Claude
  can't be asked the row is TMDB's own recommendations, which is not
  kept, so Claude is asked again next time.
  """

  import Ecto.Query
  require Logger

  alias Aviary.{Claude, Jellyseerr, Radarr, Repo, Sonarr, TmdbResult}
  alias Aviary.MoreLikeThis.{Picks, Row}

  @row_length 20
  @lowest_critic_score_shown 60
  @days_a_row_stays_current 30
  @seconds_per_day 24 * 60 * 60
  @rating_lookups_at_once 8
  @rating_lookup_timeout_ms 10_000

  @doc """
  The row for a show or movie, with Rotten Tomatoes ratings. Empty when
  nothing can be found for it.
  """
  def fetch(kind, tmdb_id)
      when kind in [:show, :movie] and (is_binary(tmdb_id) or is_integer(tmdb_id)) and
             tmdb_id != "" do
    case kept_row(kind, tmdb_id) do
      %Row{} = row ->
        unless current?(row), do: choose_again_in_background(kind, tmdb_id)
        Enum.map(row.items, &kept_item/1)

      nil ->
        case choose(kind, tmdb_id) do
          {:ok, items} -> items
          :error -> kind |> tmdb_recommendations(tmdb_id) |> finished(kind)
        end
    end
  end

  def fetch(_kind, _tmdb_id), do: []

  @doc """
  Has Claude choose the row and keeps it. `:error` when Claude can't be
  asked or none of its picks survive.
  """
  def choose(kind, tmdb_id) do
    with {:ok, listings} <- Picks.for_title(kind, tmdb_id),
         [_ | _] = items <- finished(listings, kind) do
      keep(kind, tmdb_id, items)
      {:ok, items}
    else
      _ -> :error
    end
  end

  @doc """
  Chooses a row for every show and movie in the library that has none
  yet, one at a time.
  """
  def fill_in_library do
    if Claude.configured?() do
      waiting = Enum.reject(library_titles(), fn {kind, tmdb_id} -> kept_row(kind, tmdb_id) end)

      chosen =
        Enum.count(waiting, fn {kind, tmdb_id} -> match?({:ok, _}, choose(kind, tmdb_id)) end)

      Logger.info("More like this: chose #{chosen} of #{length(waiting)} library rows")
    end

    :ok
  end

  @doc """
  TMDB's own recommendations as row items, without ratings, in its
  order of relevance.
  """
  def related(kind, tmdb_id)
      when kind in [:show, :movie] and (is_binary(tmdb_id) or is_integer(tmdb_id)) and
             tmdb_id != "" do
    kind
    |> tmdb_recommendations(tmdb_id)
    |> Enum.filter(&TmdbResult.has_backdrop?/1)
    |> Enum.take(@row_length)
    |> Enum.map(&TmdbResult.marquee_item(&1, kind))
  end

  def related(_kind, _tmdb_id), do: []

  defp tmdb_recommendations(kind, tmdb_id) do
    case Jellyseerr.recommendations(kind, tmdb_id) do
      {:ok, listings} -> listings
      _ -> []
    end
  end

  defp finished(listings, kind) do
    listings
    |> Enum.filter(&TmdbResult.has_backdrop?/1)
    |> Enum.map(&TmdbResult.marquee_item(&1, kind))
    |> with_ratings()
    |> Enum.reject(&poorly_reviewed?/1)
    |> Enum.take(@row_length)
  end

  defp poorly_reviewed?(%{rating: %{critic: critic}}) when is_integer(critic),
    do: critic < @lowest_critic_score_shown

  defp poorly_reviewed?(_item), do: false

  defp with_ratings(items) do
    items
    |> Task.async_stream(
      fn item ->
        Map.put(
          item,
          :rating,
          Aviary.RottenTomatoes.fetch(item.title, rating_type(item.kind), item.year)
        )
      end,
      max_concurrency: @rating_lookups_at_once,
      timeout: @rating_lookup_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(items)
    |> Enum.map(fn
      {{:ok, rated}, _item} -> rated
      {_, item} -> item
    end)
  end

  defp rating_type(:show), do: :tv
  defp rating_type(:movie), do: :movie

  defp kept_row(kind, tmdb_id) do
    Repo.one(
      from(row in Row,
        where: row.kind == ^to_string(kind) and row.tmdb_id == ^to_string(tmdb_id)
      )
    )
  end

  defp keep(kind, tmdb_id, items) do
    %Row{}
    |> Row.changeset(%{kind: to_string(kind), tmdb_id: to_string(tmdb_id), items: items})
    |> Repo.insert(
      on_conflict: {:replace, [:items, :updated_at]},
      conflict_target: [:kind, :tmdb_id]
    )
  end

  defp current?(%Row{updated_at: chosen_at}) do
    age_seconds = NaiveDateTime.diff(NaiveDateTime.utc_now(), chosen_at)
    age_seconds < @days_a_row_stays_current * @seconds_per_day
  end

  defp choose_again_in_background(kind, tmdb_id) do
    Task.Supervisor.start_child(Aviary.TaskSupervisor, fn -> choose(kind, tmdb_id) end)
  end

  defp kept_item(kept) do
    %{
      kind: kept_kind(kept["kind"]),
      detail_id: kept["detail_id"],
      title: kept["title"],
      year: kept["year"],
      subtitle: kept["subtitle"],
      thumbnail_url: kept["thumbnail_url"],
      rating: kept_rating(kept["rating"])
    }
  end

  defp kept_kind("movie"), do: :movie
  defp kept_kind(_), do: :show

  defp kept_rating(%{} = rating), do: %{critic: rating["critic"], audience: rating["audience"]}
  defp kept_rating(_), do: nil

  defp library_titles do
    tracked(Sonarr.all_series(), :show) ++ tracked(Radarr.all_movies(), :movie)
  end

  defp tracked({:ok, titles}, kind) do
    for %{"tmdbId" => tmdb_id} <- titles, is_integer(tmdb_id) and tmdb_id > 0, do: {kind, tmdb_id}
  end

  defp tracked(_, _kind), do: []
end
