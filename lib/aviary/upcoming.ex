defmodule Aviary.Upcoming do
  @moduledoc """
  "What of mine is dropping in the next two weeks." Per-user, gated
  on `library_entries` — a household member who never engaged with
  the show another member downloaded shouldn't see its upcoming
  episodes. `library_entries` auto-populates from any engagement
  signal (Play, watch-mark, Sonarr trigger, plus a self-heal pass
  in `Aviary.Home.continue_watching/1` for actively-watched series).

  Derives the next upcoming episode directly from TMDB's per-season
  episode list (via Jellyseerr) — not from the `nextEpisodeToAir`
  convenience pointer, which lags TMDB's actual per-episode air
  dates by hours to days.

  Surfaces an entry whenever the next-not-already-downloaded
  episode has an air date in the next two weeks, independent of
  whether the user has caught up on the rest of the show. The
  "next episode coming" is series-level information; the user's
  watch state is orthogonal.

  Exception: **season premieres ride the feed regardless of how
  far out they are**, until the file actually downloads. The
  user wanted explicit "this big thing is coming" telemetry that
  beats the 14-day rule of thumb. Implemented in `surface?/2` —
  E1 of any season is always surfaced; other episodes still
  apply the window.
  """

  alias Aviary.Jellyseerr

  @window_days 14

  @doc """
  Returns the user's upcoming releases sorted by air date ascending.
  """
  def releases(auth) do
    today = Aviary.LocalTime.today()

    auth.id
    |> Aviary.Library.list_tmdb_ids()
    |> Task.async_stream(&fetch_release(&1, auth, today),
      max_concurrency: 8,
      timeout: 12_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, release} -> release
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.air_date, Date)
  end

  defp fetch_release(tmdb_id, auth, today) do
    with {:ok, body} <- Jellyseerr.get_tv(tmdb_id),
         seasons when is_list(seasons) <- body["seasons"] do
      jellyfin = jellyfin_match_with_episodes(tmdb_id, auth)

      # Two-season window: the current/latest season (most likely
      # source of mid-season upcoming episodes) plus the next-announced
      # season (catches new-season premieres). For shows with only one
      # season in TMDB's record, Enum.take simply trims to whatever's
      # there.
      candidates =
        seasons
        |> Enum.filter(&((&1["seasonNumber"] || 0) > 0))
        |> Enum.sort_by(& &1["seasonNumber"], :desc)
        |> Enum.take(2)

      case find_next_upcoming(tmdb_id, candidates, jellyfin, today) do
        nil -> nil
        episode -> build_release(episode, jellyfin, body, today)
      end
    else
      _ -> nil
    end
  end

  # Walks candidate seasons (most recent first), returning the first
  # episode whose air date sits in the window AND isn't already
  # downloaded. find_value short-circuits the moment any season
  # yields a hit — most shows resolve in one Jellyseerr call.
  defp find_next_upcoming(tmdb_id, seasons, jellyfin, today) do
    Enum.find_value(seasons, fn season ->
      case Jellyseerr.get_tv_season(tmdb_id, season["seasonNumber"]) do
        {:ok, season_data} ->
          find_upcoming_in_episodes(season_data["episodes"] || [], jellyfin, today)

        _ ->
          nil
      end
    end)
  end

  defp find_upcoming_in_episodes(episodes, jellyfin, today) do
    episodes
    |> Enum.map(&Map.put(&1, :parsed_date, parse_iso_date(&1["airDate"])))
    |> Enum.filter(&future?(&1, today))
    |> Enum.sort_by(& &1.parsed_date, Date)
    |> Enum.find(fn ep ->
      not episode_in_library?(jellyfin, ep["seasonNumber"], ep["episodeNumber"]) and
        surface?(ep, today)
    end)
  end

  defp future?(%{parsed_date: nil}, _today), do: false

  defp future?(%{parsed_date: date}, today), do: Date.diff(date, today) >= 0

  # Season premieres (E1 of any season) ride the feed for as long
  # as the date is known and the file isn't downloaded yet — the
  # user explicitly wants the "save the date" signal regardless of
  # how far out it is. Mid-season continuation episodes still ride
  # the 14-day window because at any greater distance the user
  # doesn't care.
  defp surface?(%{"episodeNumber" => 1}, _today), do: true

  defp surface?(%{parsed_date: date}, today) do
    Date.diff(date, today) <= @window_days
  end

  defp build_release(episode, jellyfin, body, today) do
    %{
      # Prefer the Jellyfin id when the show's in the library so the
      # link lands on the existing show detail page; otherwise the
      # TMDB id routes through the discover-show loader.
      series_id: (jellyfin && jellyfin.id) || to_string(episode["showId"]),
      series_name: (jellyfin && jellyfin.name) || body["name"] || "Unknown",
      poster_url: poster_url(jellyfin, body["posterPath"]),
      season: episode["seasonNumber"],
      episode: episode["episodeNumber"],
      air_date: episode.parsed_date,
      # episodeNumber == 1 ⇒ flag as new season for the row's
      # "NEW SEASON" annotation. Simple heuristic; misclassifies brand-
      # new-series premieres as "new season" rather than "series
      # premiere," which is close enough.
      kind: if(episode["episodeNumber"] == 1, do: :new_season, else: :continuation),
      days_away: Date.diff(episode.parsed_date, today)
    }
  end

  # In-library shows serve their poster from Jellyfin by id; shows not in
  # the library have no Jellyfin item, so they fall back to the TMDB
  # poster path through the same disk-cached proxy the Discover grid uses.
  # Nil when neither source has artwork.
  defp poster_url(%{id: id}, _tmdb_path), do: "/image/#{id}"
  defp poster_url(nil, "/" <> path), do: "/image/tmdb/w500/#{path}"

  defp poster_url(nil, path) when is_binary(path) and path != "",
    do: "/image/tmdb/w500/#{path}"

  defp poster_url(nil, _), do: nil

  # Fetches the series record AND its episodes in one call per show.
  # Caching the episode list this way means we don't refetch on every
  # in-library check.
  defp jellyfin_match_with_episodes(tmdb_id, auth) do
    case Aviary.Jellyfin.list_shows(auth) do
      shows when is_list(shows) ->
        case Enum.find(shows, &(get_in(&1, ["ProviderIds", "Tmdb"]) == tmdb_id)) do
          %{"Id" => id, "Name" => name} ->
            %{id: id, name: name, episodes: Aviary.Jellyfin.list_episodes(id, auth)}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp episode_in_library?(nil, _season, _episode), do: false

  defp episode_in_library?(%{episodes: episodes}, season, episode_num) do
    Enum.any?(episodes, fn ep ->
      ep["ParentIndexNumber"] == season and ep["IndexNumber"] == episode_num
    end)
  end

  defp parse_iso_date(s) when is_binary(s) and s != "" do
    case Date.from_iso8601(s) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_iso_date(_), do: nil
end
