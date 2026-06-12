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

  alias Aviary.Jellyfin
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

    auth
    |> recently_watched_series()
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

  defp recently_watched_series(auth) do
    auth
    |> Jellyfin.recently_watched()
    |> Enum.filter(&(&1["Type"] == "Episode"))
    |> Enum.map(& &1["SeriesId"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp fetch_release(series_id, auth, today) do
    with {:ok, item} <- Jellyfin.get_item(series_id, auth),
         tmdb_id when not is_nil(tmdb_id) <- get_in(item, ["ProviderIds", "Tmdb"]),
         schedule when is_map(schedule) <- Jellyseerr.get_tv_schedule(tmdb_id),
         days when days in 0..@window_days <- Date.diff(schedule.air_date, today) do
      %{
        series_id: series_id,
        series_name: item["Name"],
        season: schedule.season,
        episode: schedule.episode,
        air_date: schedule.air_date,
        kind: schedule.kind,
        days_away: days
      }
    else
      _ -> nil
    end
  end
end
