defmodule Aviary.Search do
  @moduledoc """
  Search across TV + movies via Jellyseerr. Thin wrapper over
  `Aviary.Jellyseerr.search/1` that produces marquee-shaped result
  maps (`detail_id`, `kind`, `thumbnail_url`, `title`, …) so the
  SearchLive can hand them straight to the existing `Marquee.row`
  component. Same shape `Aviary.Discover` produces.

  Filters out items without a backdrop (the marquee card is 16:9
  and an empty/stretched tile reads as broken). Falls back to the
  poster path if there's no backdrop, since search needs to be
  inclusive — losing matches just because TMDB didn't upload a
  16:9 still is worse than a slightly off-aspect card.
  """

  alias Aviary.Jellyseerr

  def run(query) when is_binary(query) do
    case Jellyseerr.search(query) do
      {:ok, results} ->
        results
        |> Enum.map(&to_item(&1, query))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp to_item(%{"mediaType" => "tv"} = r, q), do: tv_item(r, q)
  defp to_item(%{"mediaType" => "movie"} = r, q), do: movie_item(r, q)
  defp to_item(_, _), do: nil

  defp tv_item(r, q) do
    case best_image_path(r) do
      nil ->
        nil

      path ->
        %{
          kind: :show,
          detail_id: jellyfin_id(r) || r["id"],
          title: r["name"] || r["originalName"],
          subtitle: nil,
          thumbnail_url: tmdb_image_url(path),
          rating: nil,
          kicker_q: q
        }
    end
  end

  defp movie_item(r, q) do
    case best_image_path(r) do
      nil ->
        nil

      path ->
        %{
          kind: :movie,
          detail_id: jellyfin_id(r) || r["id"],
          title: r["title"] || r["originalTitle"],
          subtitle: nil,
          thumbnail_url: tmdb_image_url(path),
          rating: nil,
          kicker_q: q
        }
    end
  end

  # Prefer the backdrop (16:9 = card aspect), fall back to the poster
  # (2:3 — slightly cropped on the card but recognizable). Some less-
  # popular titles have neither, in which case we drop the result.
  defp best_image_path(%{"backdropPath" => bp}) when is_binary(bp) and bp != "", do: bp
  defp best_image_path(%{"posterPath" => pp}) when is_binary(pp) and pp != "", do: pp
  defp best_image_path(_), do: nil

  defp tmdb_image_url("/" <> path), do: "/image/tmdb/w780/" <> path
  defp tmdb_image_url(path) when is_binary(path), do: "/image/tmdb/w780/" <> path

  defp jellyfin_id(%{"mediaInfo" => %{"jellyfinMediaId" => id}})
       when is_binary(id) and id != "",
       do: id

  defp jellyfin_id(_), do: nil
end
