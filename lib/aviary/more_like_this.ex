defmodule Aviary.MoreLikeThis do
  @moduledoc """
  The "More like this" row on a show or movie detail page: the titles
  TMDB recommends alongside it, whether or not they are in the library
  yet.
  """

  alias Aviary.{Jellyseerr, TmdbResult}

  @row_length 20
  @rating_lookups_at_once 8
  @rating_lookup_timeout_ms 10_000

  @doc """
  The row for a show or movie, with Rotten Tomatoes ratings. Empty when
  TMDB recommends nothing or can't be reached.
  """
  def fetch(kind, tmdb_id), do: kind |> related(tmdb_id) |> with_ratings()

  @doc """
  The row without ratings, in TMDB's order of relevance.
  """
  def related(kind, tmdb_id)
      when kind in [:show, :movie] and (is_binary(tmdb_id) or is_integer(tmdb_id)) and
             tmdb_id != "" do
    case Jellyseerr.recommendations(kind, tmdb_id) do
      {:ok, results} ->
        results
        |> Enum.filter(&TmdbResult.has_backdrop?/1)
        |> Enum.take(@row_length)
        |> Enum.map(&TmdbResult.marquee_item(&1, kind))

      _ ->
        []
    end
  end

  def related(_kind, _tmdb_id), do: []

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
end
