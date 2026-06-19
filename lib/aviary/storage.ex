defmodule Aviary.Storage do
  @moduledoc """
  Household storage breakdown for the Settings page. Pulls all movies
  + all episodes from Jellyfin with file sizes, joins against
  library_entries, and computes two views:

    - **per_user** — each household member's slice. An item in N
      libraries gets `size / N` charged to each subscriber, so the
      bar's sum equals actual tank usage rather than over-counting
      shared content.
    - **aggregate** — household-wide counts and sizes with shared
      items deduped (movies / shows / episodes each counted once).
      Drives the Total row of the stats table.

  Tank capacity (post-RAIDZ1 usable bytes) comes from `TANK_BYTES`
  in the container env; depot writes that on every `depot aviary`
  via `zfs list -H -p -o avail,used tank`. Unset → the Settings bar
  falls back to household-share scaling.
  """

  alias Aviary.{Jellyfin, Library}

  @doc """
  Returns a map:

      %{
        per_user: [%{user_id, username, movie_count, show_count,
                     episode_count, bytes, bytes_movies, bytes_shows}],
        aggregate: %{movie_count, show_count, episode_count,
                     bytes, bytes_movies, bytes_shows},
        tank_bytes: nil | integer
      }
  """
  def stats(auth) do
    movies = Jellyfin.list_movies_with_sizes(auth)
    episodes = Jellyfin.list_all_episodes_with_sizes(auth)
    users = Jellyfin.list_users(auth)

    movie_sizes_by_tmdb = sizes_by_tmdb(movies)
    {series_bytes_by_jf_id, series_eps_by_jf_id} = roll_up_episodes(episodes)

    # series TMDB id → {bytes, episode_count}
    series_stats_by_tmdb =
      Jellyfin.list_shows(auth)
      |> Enum.reduce(%{}, fn series, acc ->
        case get_in(series, ["ProviderIds", "Tmdb"]) do
          nil ->
            acc

          tmdb ->
            jf_id = series["Id"]
            bytes = Map.get(series_bytes_by_jf_id, jf_id, 0)
            episode_count = Map.get(series_eps_by_jf_id, jf_id, 0)
            Map.put(acc, tmdb, {bytes, episode_count})
        end
      end)

    subscriber_counts = Library.subscriber_counts()

    per_user =
      users
      |> Enum.map(fn user ->
        user_id = user["Id"]
        tmdb_ids = Library.list_tmdb_ids(user_id)

        stats =
          roll_up_for_user(
            tmdb_ids,
            movie_sizes_by_tmdb,
            series_stats_by_tmdb,
            subscriber_counts
          )

        Map.merge(stats, %{user_id: user_id, username: user["Name"]})
      end)
      |> Enum.sort_by(& &1.bytes, :desc)

    aggregate = aggregate_household(movie_sizes_by_tmdb, series_stats_by_tmdb)

    %{
      per_user: per_user,
      aggregate: aggregate,
      tank_bytes: tank_bytes()
    }
  end

  @doc """
  Tank capacity in bytes (post-RAIDZ1 usable). Nil if `TANK_BYTES`
  env var isn't set — caller falls back to household-share scaling
  for the bar.
  """
  def tank_bytes do
    case System.get_env("TANK_BYTES") do
      nil -> nil
      "" -> nil
      v -> String.to_integer(v)
    end
  end

  @doc """
  Format a byte count as a short human string with one decimal of
  precision. "—" for zero / nil so the table can render an em dash
  for empty cells without callers branching.
  """
  def humanize_bytes(0), do: "—"
  def humanize_bytes(nil), do: "—"

  def humanize_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1024 ** 4 -> "#{format_float(bytes / 1024 ** 4)} TB"
      bytes >= 1024 ** 3 -> "#{format_float(bytes / 1024 ** 3)} GB"
      bytes >= 1024 ** 2 -> "#{format_float(bytes / 1024 ** 2)} MB"
      true -> "#{round(bytes)} B"
    end
  end

  defp format_float(n) when n >= 100, do: "#{round(n)}"
  defp format_float(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  # ============================================================
  # Internals
  # ============================================================

  defp sizes_by_tmdb(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      tmdb = get_in(item, ["ProviderIds", "Tmdb"])
      size = item_size(item)

      cond do
        is_nil(tmdb) -> acc
        is_nil(size) -> acc
        true -> Map.put(acc, tmdb, size)
      end
    end)
  end

  defp roll_up_episodes(episodes) do
    Enum.reduce(episodes, {%{}, %{}}, fn ep, {bytes_acc, count_acc} ->
      series_id = ep["SeriesId"]
      size = item_size(ep) || 0

      new_bytes = Map.update(bytes_acc, series_id, size, &(&1 + size))
      new_count = Map.update(count_acc, series_id, 1, &(&1 + 1))

      {new_bytes, new_count}
    end)
  end

  # First MediaSource's Size — Jellyfin returns an array (multiple
  # versions of the same media); we only care about the primary.
  defp item_size(%{"MediaSources" => [%{"Size" => size} | _]}) when is_integer(size), do: size
  defp item_size(_), do: nil

  # Each item's size divided by the count of users who have it. A
  # 30 GB show in 3 libraries charges 10 GB to each. Item not in
  # subscriber_counts (shouldn't happen) → divide by 1 to avoid
  # zero-divide. Per-user counts (movie_count, etc.) stay 1 per
  # opt-in — they describe "what's in YOUR library," not a shared
  # quantity.
  defp roll_up_for_user(tmdb_ids, movie_sizes_by_tmdb, series_stats_by_tmdb, subscriber_counts) do
    Enum.reduce(
      tmdb_ids,
      %{
        movie_count: 0,
        show_count: 0,
        episode_count: 0,
        bytes: 0,
        bytes_movies: 0,
        bytes_shows: 0
      },
      fn tmdb_id, acc ->
        subscribers = max(Map.get(subscriber_counts, tmdb_id, 1), 1)

        cond do
          size = Map.get(movie_sizes_by_tmdb, tmdb_id) ->
            share = size / subscribers

            %{
              acc
              | movie_count: acc.movie_count + 1,
                bytes: acc.bytes + share,
                bytes_movies: acc.bytes_movies + share
            }

          stats = Map.get(series_stats_by_tmdb, tmdb_id) ->
            {bytes, episode_count} = stats
            share = bytes / subscribers

            %{
              acc
              | show_count: acc.show_count + 1,
                episode_count: acc.episode_count + episode_count,
                bytes: acc.bytes + share,
                bytes_shows: acc.bytes_shows + share
            }

          true ->
            # tmdb_id in library_entries but no matching Jellyfin item
            # yet (e.g., still downloading) — nothing to count.
            acc
        end
      end
    )
  end

  # Walk the household's distinct TMDB ids — every item that AT LEAST
  # ONE user has — and sum sizes / counts. Each item contributes once.
  # Sum of per_user bytes equals aggregate.bytes by construction
  # (the 1/N shares add back up to N/N = 1 of each item).
  defp aggregate_household(movie_sizes_by_tmdb, series_stats_by_tmdb) do
    Library.distinct_tmdb_ids()
    |> Enum.reduce(
      %{
        movie_count: 0,
        show_count: 0,
        episode_count: 0,
        bytes: 0,
        bytes_movies: 0,
        bytes_shows: 0
      },
      fn tmdb_id, acc ->
        cond do
          size = Map.get(movie_sizes_by_tmdb, tmdb_id) ->
            %{
              acc
              | movie_count: acc.movie_count + 1,
                bytes: acc.bytes + size,
                bytes_movies: acc.bytes_movies + size
            }

          stats = Map.get(series_stats_by_tmdb, tmdb_id) ->
            {bytes, episode_count} = stats

            %{
              acc
              | show_count: acc.show_count + 1,
                episode_count: acc.episode_count + episode_count,
                bytes: acc.bytes + bytes,
                bytes_shows: acc.bytes_shows + bytes
            }

          true ->
            acc
        end
      end
    )
  end
end
