defmodule Aviary.TmdbResult do
  @moduledoc """
  Turns one result from Jellyseerr's TMDB proxy (a discover, search or
  recommendations entry) into the item shape the marquee rows render.
  """

  @doc """
  The marquee item for a result. `detail_id` is the Jellyfin id when
  the title is already in the library, so the card opens the real
  detail page, and the TMDB id otherwise.
  """
  def marquee_item(result, kind) when kind in [:show, :movie] do
    %{
      kind: kind,
      detail_id: jellyfin_id(result) || result["id"],
      title: result["name"] || result["title"],
      year: year(result["firstAirDate"] || result["releaseDate"]),
      subtitle: nil,
      thumbnail_url: backdrop_url(result["backdropPath"]),
      rating: nil
    }
  end

  def has_backdrop?(%{"backdropPath" => path}) when is_binary(path) and path != "", do: true
  def has_backdrop?(_), do: false

  defp year(date) when is_binary(date) do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp year(_), do: nil

  defp jellyfin_id(%{"mediaInfo" => %{"jellyfinMediaId" => id}})
       when is_binary(id) and id != "",
       do: id

  defp jellyfin_id(_), do: nil

  defp backdrop_url("/" <> path), do: "/image/tmdb/w780/" <> path
  defp backdrop_url(path) when is_binary(path) and path != "", do: "/image/tmdb/w780/" <> path
  defp backdrop_url(_), do: nil
end
