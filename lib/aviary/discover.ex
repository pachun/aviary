defmodule Aviary.Discover do
  @moduledoc """
  Discover read-model — composes the rows the /discover page renders,
  one per major streaming service, from Jellyseerr's TMDB proxy.

  A row leads with what the service is pushing right now: its shows
  with an episode in the last month or one due in the next, most
  popular first. TMDB's popularity score moves slowly and favors a
  network's deep catalog, so without that first tier HBO was Game of
  Thrones, The Sopranos and Sesame Street forever. Talk, news and
  reality shows air every week of the year, so they never count as
  news; they wait in the second tier with the rest of the all-time
  popular list, minus anything already shown. So does anything almost
  nobody on TMDB has looked at: a stray entry a contributor pinned to
  the network is not something the service is pushing. Shows made for
  little kids are left out of the row altogether.

  Items expose the `thumbnail_url` field (a direct TMDB CDN URL) so
  the marquee can render them without going through aviary's image
  proxy — these shows often aren't in the user's Jellyfin library
  yet, so there's no Jellyfin id to proxy.

  Click target prefers the show's Jellyfin id from Jellyseerr's
  mediaInfo when the show IS in the library; otherwise falls back to
  the TMDB id, which routes to the existing show detail page.
  """

  alias Aviary.Jellyseerr

  # The seven big US streaming services. Order is the row order on
  # the page. Network ids are TMDB networks; HBO's originals are split
  # between the HBO channel and HBO Max, so its row draws on both.
  @services [
    {"Apple TV+", [2552]},
    {"HBO", [49, 3186]},
    {"Paramount+", [4330]},
    {"Disney+", [2739]},
    {"Netflix", [213]},
    {"Hulu", [453]},
    {"Prime Video", [1024]}
  ]

  @row_length 20
  @popular_pages 1..2
  @recent_episode_days 30
  @upcoming_episode_days 30
  @new_show_days 90
  @never_featured_genres ["Talk", "News", "Reality"]
  @never_featured_types ["Talk Show", "News", "Reality"]
  @least_popularity_to_feature 10
  @little_kids_genre "Kids"
  @detail_lookups_at_once 8
  @detail_lookup_timeout_ms 10_000

  @doc """
  The list of service rows to render, as `{label, network_ids}`, in
  display order. Exposed so DiscoverLive can render skeleton
  placeholders immediately, then stream each row in via start_async.
  """
  def services, do: @services

  @doc """
  Fetches one service's row: ranked, trimmed to the row length and
  given Rotten Tomatoes ratings. Used by DiscoverLive in a per-row
  start_async so the page can paint immediately with skeletons and
  fill rows independently.
  """
  def fetch_row(network_ids) do
    network_ids
    |> ranked_shows(Date.utc_today())
    |> Enum.take(@row_length)
    |> Enum.map(&to_item/1)
    |> enrich_with_ratings()
  end

  @doc """
  The service's shows in row order: airing now first, then the
  all-time popular list, with no show twice. Each entry is the raw
  TMDB result from Jellyseerr.
  """
  def ranked_shows(network_ids, today) do
    network_ids
    |> candidates(today)
    |> Enum.filter(&has_backdrop?/1)
    |> Task.async_stream(&with_air_dates/1,
      max_concurrency: @detail_lookups_at_once,
      timeout: @detail_lookup_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, candidate} -> [candidate]
      _ -> []
    end)
    |> Enum.reject(&for_little_kids?/1)
    |> rank(today)
    |> Enum.map(& &1.show)
  end

  @doc """
  Orders candidates for the row: shows airing now by popularity, then
  everything else by popularity. A candidate is
  `%{show:, popularity:, type:, genres:, last_aired:, next_airs:}`.
  """
  def rank(candidates, today) do
    {airing_now, catalog} = Enum.split_with(candidates, &airing_now?(&1, today))
    most_popular_first(airing_now) ++ most_popular_first(catalog)
  end

  defp candidates(network_ids, today) do
    premiered_since = Date.add(today, -@new_show_days)

    network_ids
    |> Enum.flat_map(fn network_id ->
      popular =
        Enum.flat_map(@popular_pages, &discovered(Jellyseerr.discover_tv_network(network_id, &1)))

      premieres = discovered(Jellyseerr.discover_tv_premieres(network_id, premiered_since))
      popular ++ premieres
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  defp discovered({:ok, results}), do: results
  defp discovered(_), do: []

  defp with_air_dates(show) do
    details =
      case Jellyseerr.get_tv(show["id"]) do
        {:ok, details} -> details
        _ -> %{}
      end

    %{
      show: show,
      popularity: show["popularity"] || 0,
      type: details["type"],
      genres: genre_names(details),
      last_aired: air_date(details["lastEpisodeToAir"]),
      next_airs: air_date(details["nextEpisodeToAir"])
    }
  end

  defp air_date(%{"airDate" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp air_date(_), do: nil

  defp genre_names(details) do
    details["genres"] |> List.wrap() |> Enum.map(& &1["name"])
  end

  defp airing_now?(candidate, today) do
    featured_kind?(candidate) and noticed?(candidate) and
      has_episode_around_now?(candidate, today)
  end

  defp featured_kind?(%{type: type, genres: genres}) do
    type not in @never_featured_types and
      not Enum.any?(genres, &(&1 in @never_featured_genres))
  end

  defp noticed?(%{popularity: popularity}), do: popularity >= @least_popularity_to_feature

  defp for_little_kids?(%{genres: genres}), do: @little_kids_genre in genres

  defp has_episode_around_now?(%{last_aired: last_aired, next_airs: next_airs}, today) do
    aired_recently?(last_aired, today) or airs_soon?(next_airs, today)
  end

  defp aired_recently?(nil, _today), do: false
  defp aired_recently?(aired, today), do: Date.diff(today, aired) in 0..@recent_episode_days

  defp airs_soon?(nil, _today), do: false
  defp airs_soon?(airs, today), do: Date.diff(airs, today) in 0..@upcoming_episode_days

  defp most_popular_first(candidates), do: Enum.sort_by(candidates, & &1.popularity, :desc)

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

  # The marquee card is 16:9 — items with no TMDB backdrop would
  # render an empty/stretched tile and look broken.
  defp has_backdrop?(%{"backdropPath" => p}) when is_binary(p) and p != "", do: true
  defp has_backdrop?(_), do: false

  # Marquee item shape. detail_id prefers Jellyfin id when the show
  # is already owned (Jellyseerr's mediaInfo carries it) so clicks
  # land on the actual detail page. Falls back to TMDB id for
  # unowned shows.
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
