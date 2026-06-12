defmodule Aviary.Upcoming do
  @moduledoc """
  "What of mine is dropping in the next two weeks." For each show the
  user has touched recently, looks up Jellyseerr's nextEpisodeToAir
  and surfaces it if it falls within the window. Shows the user
  hasn't started, shows between seasons with no announced date, and
  ended shows all naturally fall out — Jellyseerr's nextEpisodeToAir
  is nil for those.

  Cost: one Jellyfin /Items call per unique recently-watched series
  (to extract TMDB id from ProviderIds) plus one Jellyseerr call per
  series. Parallelized via Task.async_stream so wall-clock is
  bounded by the slowest single show, not the sum.
  """

  alias Aviary.Jellyseerr

  # Two weeks matches the show-detail calendar widget's window. Most
  # broadcast shows drop weekly, so 14 days is a full picture of
  # what's coming — anything further out is in the same "later" tier
  # mentally and doesn't need surfacing on home yet.
  @window_days 14

  @doc """
  Returns the user's upcoming releases sorted by air date ascending.

  Each release is `%{series_id, series_name, season, episode,
  air_date, kind, days_away}` where `kind` is `:continuation` or
  `:new_season`.
  """
  def releases(auth) do
    today = Date.utc_today()

    # Library entries are TMDB-keyed by definition, so we sidestep the
    # Jellyfin series-id lookup the previous implementation needed.
    # Each lookup is one Jellyseerr call + (when the show is also in
    # the user's Jellyfin library) one /Items call for the canonical
    # display name + a stable click target.
    auth.id
    |> Aviary.Library.list_tmdb_ids()
    |> Task.async_stream(&fetch_release(&1, auth, today),
      max_concurrency: 8,
      timeout: 8_000,
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
    with schedule when is_map(schedule) <- Jellyseerr.get_tv_schedule(tmdb_id),
         days when days in 0..@window_days <- Date.diff(schedule.air_date, today) do
      jellyfin = jellyfin_match(tmdb_id, auth)

      # Upcoming's job is "what's coming that I don't have yet." If
      # the scheduled episode already imported (Sonarr grabbed it
      # before Jellyseerr / TMDB updated nextEpisodeToAir to the
      # following episode), drop this entry — it's no longer
      # upcoming. The next refresh will surface the episode after
      # whenever the metadata catches up.
      if jellyfin && episode_in_library?(jellyfin.id, schedule.season, schedule.episode, auth) do
        nil
      else
        %{
          series_id: (jellyfin && jellyfin.id) || tmdb_id,
          series_name: (jellyfin && jellyfin.name) || schedule[:series_name] || "Unknown",
          season: schedule.season,
          episode: schedule.episode,
          air_date: schedule.air_date,
          kind: schedule.kind,
          days_away: days
        }
      end
    else
      _ -> nil
    end
  end

  defp episode_in_library?(series_id, season, episode, auth) do
    series_id
    |> Aviary.Jellyfin.list_episodes(auth)
    |> Enum.any?(fn ep ->
      ep["ParentIndexNumber"] == season and ep["IndexNumber"] == episode
    end)
  end

  # Returns the user's Jellyfin series record for this TMDB id when
  # the show is in the library, or nil. We look it up via the same
  # batch endpoint as Home so this is one round-trip; if it's not in
  # the library, we still surface the release using Jellyseerr's
  # series name as the display.
  defp jellyfin_match(tmdb_id, auth) do
    case Aviary.Jellyfin.list_shows(auth) do
      shows when is_list(shows) ->
        case Enum.find(shows, &(get_in(&1, ["ProviderIds", "Tmdb"]) == tmdb_id)) do
          %{"Id" => id, "Name" => name} -> %{id: id, name: name}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
