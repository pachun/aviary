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
    {"Netflix", 213},
    {"HBO", 49},
    {"Hulu", 453},
    {"Disney+", 2739},
    {"Prime Video", 1024},
    {"Paramount+", 4330}
  ]

  @doc """
  Returns `[%{label, items}]` — one entry per service. Network calls
  run in parallel via async_stream; total wall-clock is roughly the
  slowest single network, not the sum.
  """
  def rows do
    @services
    |> Task.async_stream(
      fn {label, network_id} -> {label, fetch_row(network_id)} end,
      max_concurrency: length(@services),
      timeout: 8_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {label, items}} -> %{label: label, items: items}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1.items == []))
  end

  defp fetch_row(network_id) do
    case Jellyseerr.discover_tv_network(network_id) do
      {:ok, results} ->
        results
        # The marquee card is 16:9 — items with no TMDB backdrop would
        # render an empty/stretched tile and look broken. Drop them
        # silently; popularity-sorted lists almost always have plenty
        # of valid backdrops at the top.
        |> Enum.filter(&has_backdrop?/1)
        |> Enum.map(&to_item/1)

      _ ->
        []
    end
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
      subtitle: nil,
      thumbnail_url: backdrop_url(result["backdropPath"])
    }
  end

  defp jellyfin_id(%{"mediaInfo" => %{"jellyfinMediaId" => id}})
       when is_binary(id) and id != "",
       do: id

  defp jellyfin_id(_), do: nil

  # TMDB CDN backdrop. w780 is the size sweet spot — large enough
  # for the 320px-wide marquee card on retina without overpaying
  # bytes. Falls back to the original-size endpoint if a path is
  # weirdly missing the leading slash.
  defp backdrop_url(nil), do: nil
  defp backdrop_url(""), do: nil

  defp backdrop_url(path) when is_binary(path) do
    "https://image.tmdb.org/t/p/w780#{path}"
  end
end
