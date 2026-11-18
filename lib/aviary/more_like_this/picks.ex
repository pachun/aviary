defmodule Aviary.MoreLikeThis.Picks do
  @moduledoc """
  The titles Claude would put next to a show or movie, matched to their
  TMDB entries. Claude judges by tone, premise, craft and network, which
  TMDB's viewing-data recommendations miss for anything not widely
  watched.
  """

  alias Aviary.{Claude, Jellyseerr}

  @searches_at_once 8
  @search_timeout_ms 10_000
  @years_a_listing_may_differ_by 1

  @instructions """
  You choose the "More like this" row for a private streaming library. \
  You are given one show or movie. Name 30 other titles of the same kind \
  (shows for a show, movies for a movie) that someone who loved it would \
  most want to watch next, best match first.

  What makes a good match, in order of weight: the same tone and feel; a \
  similar premise or subject; comparable craft and ambition; the same \
  network, studio or creators when the fit is otherwise close. Only \
  include titles that were well received by critics or audiences. Leave \
  out sequels, spin-offs and other entries in the same franchise unless \
  they are the obvious next thing to watch. Never include the title \
  itself.

  If you do not recognize the title, work from its synopsis, genres, \
  network and creators. Give each pick's title exactly as it is listed \
  on TMDB and the year it first aired or was released.
  """

  @answer_shape %{
    type: "object",
    properties: %{
      picks: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{title: %{type: "string"}, year: %{type: "integer"}},
          required: ["title", "year"],
          additionalProperties: false
        }
      }
    },
    required: ["picks"],
    additionalProperties: false
  }

  @doc """
  `{:ok, tmdb_results}` in Claude's order, each in the shape
  Jellyseerr's search returns, or `:error` when the title can't be
  looked up, Claude can't be asked, or none of its picks are on TMDB.
  """
  def for_title(kind, tmdb_id) when kind in [:show, :movie] do
    with {:ok, details} <- details(kind, tmdb_id),
         {:ok, %{"picks" => picks}} when is_list(picks) <-
           Claude.answer(@instructions, Jason.encode!(described(kind, details)), @answer_shape),
         [_ | _] = listings <- listings(kind, picks, tmdb_id) do
      {:ok, listings}
    else
      _ -> :error
    end
  end

  defp details(:show, tmdb_id), do: Jellyseerr.get_tv(tmdb_id)
  defp details(:movie, tmdb_id), do: Jellyseerr.get_movie(tmdb_id)

  defp described(kind, details) do
    %{
      kind: kind,
      title: details["name"] || details["title"],
      year: year(details["firstAirDate"] || details["releaseDate"]),
      synopsis: details["overview"],
      genres: names(details["genres"]),
      networks: names(details["networks"]),
      studios: names(details["productionCompanies"]),
      creators: names(details["createdBy"]) ++ directors(details),
      keywords: names(details["keywords"])
    }
  end

  defp names(list) when is_list(list),
    do: list |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)

  defp names(_), do: []

  defp directors(%{"credits" => %{"crew" => crew}}) when is_list(crew) do
    crew |> Enum.filter(&(&1["job"] == "Director")) |> names()
  end

  defp directors(_), do: []

  defp listings(kind, picks, source_tmdb_id) do
    picks
    |> Task.async_stream(&listing(kind, &1),
      max_concurrency: @searches_at_once,
      timeout: @search_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %{} = listing} -> [listing]
      _ -> []
    end)
    |> Enum.reject(&(to_string(&1["id"]) == to_string(source_tmdb_id)))
    |> Enum.uniq_by(& &1["id"])
  end

  defp listing(kind, %{"title" => title, "year" => pick_year}) when is_binary(title) do
    case Jellyseerr.search(title) do
      {:ok, results} ->
        same_title =
          Enum.filter(results, fn result ->
            result["mediaType"] == media_type(kind) and
              comparable(result["name"] || result["title"]) == comparable(title)
          end)

        Enum.find(same_title, &from_about(&1, pick_year)) || List.first(same_title)

      _ ->
        nil
    end
  end

  defp listing(_kind, _pick), do: nil

  defp from_about(result, pick_year) when is_integer(pick_year) do
    case year(result["firstAirDate"] || result["releaseDate"]) do
      nil -> false
      listed -> abs(listed - pick_year) <= @years_a_listing_may_differ_by
    end
  end

  defp from_about(_result, _pick_year), do: false

  defp comparable(title) when is_binary(title) do
    title |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, "")
  end

  defp comparable(_), do: nil

  defp year(date) when is_binary(date) do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp year(_), do: nil

  defp media_type(:show), do: "tv"
  defp media_type(:movie), do: "movie"
end
