defmodule Aviary.Discover do
  @moduledoc """
  Discover read-model — composes the rows the /discover page renders,
  one per major streaming service. Each row is "currently popular TV
  on this service" pulled from Jellyseerr's discover-by-network proxy
  over TMDB.

  Items expose the `thumbnail_url` field (a direct TMDB CDN URL) so
  the marquee can render them without going through aviary's image
  proxy — these shows often aren't in the user's Jellyfin library
  yet, so there's no Jellyfin id to proxy.

  Click target prefers the show's Jellyfin id from Jellyseerr's
  mediaInfo when the show IS in the library; otherwise falls back to
  the TMDB id, which routes to the existing show detail page (and
  bounces with a "show not found" flash until the not-yet-in-library
  detail flow lands).
  """

  alias Aviary.Jellyseerr

  # The seven big US streaming services. Order is the row order on
  # the page. Network ids are TMDB networks; Jellyseerr proxies these
  # 1:1 via its discover endpoint.
  @services [
    {"Apple TV+", 2552},
    {"HBO", 49},
    {"Paramount+", 4330},
    {"Disney+", 2739},
    {"Netflix", 213},
    {"Hulu", 453},
    {"Prime Video", 1024}
  ]

  @doc """
  The list of service rows to render. Returned in display order.
  Exposed publicly so DiscoverLive can render skeleton placeholders
  immediately, then stream each row in via start_async.
  """
  def services, do: @services

  @doc """
  Fetches one network's row. Used by DiscoverLive in a per-row
  start_async so the page can paint immediately with skeletons and
  fill rows independently — instead of the page blocking until all
  seven rows + 140 RT scrapes are done (the prior 15s cold-cache UX).
  """
  def fetch_row(network_id) do
    case Jellyseerr.discover_tv_network(network_id) do
      {:ok, results} ->
        results
        # The marquee card is 16:9 — items with no TMDB backdrop would
        # render an empty/stretched tile and look broken. Drop them
        # silently; popularity-sorted lists almost always have plenty
        # of valid backdrops at the top.
        |> Enum.filter(&has_backdrop?/1)
        |> Enum.map(&to_item/1)
        |> enrich_with_ratings()

      _ ->
        []
    end
  end

  # RT-only audience + critic. Items without RT data render with no
  # corner badge — better to show nothing than to mix data sources
  # behind the same audience-tomato icon.
  defp enrich_with_ratings(items) do
    items
    |> Task.async_stream(
      fn item ->
        Map.put(item, :rating, Aviary.RottenTomatoes.fetch(item.title, :tv, item.year))
      end,
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

  defp has_backdrop?(%{"backdropPath" => p}) when is_binary(p) and p != "", do: true
  defp has_backdrop?(_), do: false

  # Marquee item shape. detail_id prefers Jellyfin id when the show
  # is already owned (Jellyseerr's mediaInfo carries it) so clicks
  # land on the actual detail page. Falls back to TMDB id for
  # unowned shows — those clicks currently 404, which the discover
  # page accepts until the not-in-library flow exists.
  defp to_item(result) do
    %{
      kind: :show,
      detail_id: jellyfin_id(result) || result["id"],
      title: result["name"],
      year: tmdb_year(result["firstAirDate"]),
      subtitle: nil,
      thumbnail_url: backdrop_url(result["backdropPath"]),
      rating: nil
    }
  end

  defp tmdb_year(date) when is_binary(date) do
    case Integer.parse(String.slice(date, 0, 4)) do
      {year, _} -> year
      :error -> nil
    end
  end

  defp tmdb_year(_), do: nil

  defp jellyfin_id(%{"mediaInfo" => %{"jellyfinMediaId" => id}})
       when is_binary(id) and id != "",
       do: id

  defp jellyfin_id(_), do: nil

  # TMDB CDN backdrop, routed through aviary's disk-cached proxy
  # (`/image/tmdb/...` → AviaryWeb.ImageController.tmdb/2 →
  # Aviary.TmdbImageCache). Same-origin keeps the browser's HTTP/2
  # connection hot and avoids the per-visit DNS + TLS to
  # image.tmdb.org; subsequent fetches of the same image pay only
  # local disk IO. w780 is the size sweet spot — large enough for
  # the 320px-wide marquee card on retina without overpaying bytes.
  defp backdrop_url(nil), do: nil
  defp backdrop_url(""), do: nil
  defp backdrop_url("/" <> path), do: "/image/tmdb/w780/" <> path
  defp backdrop_url(path) when is_binary(path), do: "/image/tmdb/w780/" <> path
end
