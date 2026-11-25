defmodule Aviary.OnThisServer do
  @moduledoc """
  What Discover and search offer on a server that can't add titles:
  everything already on it, whoever brought it in, so each member of the
  household can find what the others have. A server that can add browses
  the streaming services and searches TMDB instead (`Aviary.Discover`,
  `Aviary.Search`).

  Items have the marquee shape those modules produce.
  """

  alias Aviary.{Jellyfin, Radarr, Sonarr}

  @shows_label "Shows on this server"
  @movies_label "Movies on this server"

  @doc "Whether this is all the server offers, because it has nothing to add titles with."
  def all_there_is?, do: not (Sonarr.configured?() or Radarr.configured?())

  @doc "Discover's rows as `{label, items}`, leaving out a kind the server has none of."
  def rows(user), do: rows(Jellyfin.list_shows(user), Jellyfin.list_movies(user))

  @doc "Discover Movies' rows: just the movies on the server."
  def movie_rows(user), do: rows([], Jellyfin.list_movies(user))

  def rows(shows, movies) do
    Enum.reject(
      [
        {@shows_label, items(shows, :show)},
        {@movies_label, items(movies, :movie)}
      ],
      fn {_label, items} -> items == [] end
    )
  end

  @doc "The titles on the server whose name contains the query, shows first."
  def search(user, query),
    do: search(Jellyfin.list_shows(user), Jellyfin.list_movies(user), query)

  def search(shows, movies, query) do
    wanted = String.downcase(String.trim(query))

    Enum.filter(items(shows, :show) ++ items(movies, :movie), fn item ->
      String.contains?(String.downcase(item.title), wanted)
    end)
  end

  defp items(listed, kind) do
    listed
    |> Enum.map(&item(&1, kind))
    |> Enum.sort_by(&String.downcase(&1.title))
  end

  defp item(listed, kind) do
    %{
      kind: kind,
      detail_id: listed["Id"],
      title: listed["Name"],
      year: listed["ProductionYear"],
      subtitle: nil,
      thumbnail_url: "/image/#{listed["Id"]}?kind=backdrop",
      rating: nil
    }
  end
end
