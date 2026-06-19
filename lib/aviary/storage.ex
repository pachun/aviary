defmodule Aviary.Storage do
  @moduledoc """
  Per-user storage breakdown for the Settings page. Pulls all movies
  + all episodes from Jellyfin with file sizes, joins against
  library_entries to attribute each item to the household members
  who opted into it, and rolls up to per-user totals.

  Item attribution: an item that's in multiple users' libraries is
  attributed in full to EACH of them — the stacked bar's sum can
  exceed the actual tank usage by the size of any duplicated
  attribution. That's intentional: the bar shows "what each user
  has on their plate," not "who claimed it first." A more
  conservative `first-adder-only` rollup would be a single change
  to `attribute_item/3`.

  Tank capacity (post-RAIDZ1 usable bytes) comes from the
  `TANK_BYTES` env var if set — depot writes it via
  `zfs list -H -p -o avail,used tank` and passes through aviary's
  compose. Unset means the Settings bar shows household-share scale
  (sum of all users) instead of `% of tank`.
  """

  alias Aviary.{Jellyfin, Library, Repo}
  import Ecto.Query

  @doc """
  Returns a list of per-user breakdowns, sorted by descending total
  bytes (heaviest user first). Each entry:

      %{
        user_id:      "32-char jellyfin user id",
        username:     "nick",
        movie_count:  12,
        show_count:   6,
        episode_count: 84,
        bytes:        222_000_000_000
      }
  """
  def breakdown_per_user(auth) do
    movies = Jellyfin.list_movies_with_sizes(auth)
    episodes = Jellyfin.list_all_episodes_with_sizes(auth)
    users = Jellyfin.list_users(auth)

    # tmdb_id (string) → size in bytes
    movie_sizes_by_tmdb = sizes_by_tmdb(movies)

    # series jellyfin id → total bytes (all episodes), episode count
    {series_bytes, series_episode_count} = roll_up_episodes(episodes)

    # series tmdb id → {bytes, episode_count}. Walk Jellyfin's series
    # list once to bridge SeriesId → TMDB id.
    series_stats_by_tmdb =
      Jellyfin.list_shows(auth)
      |> Enum.reduce(%{}, fn series, acc ->
        case get_in(series, ["ProviderIds", "Tmdb"]) do
          nil ->
            acc

          tmdb ->
            jf_id = series["Id"]
            bytes = Map.get(series_bytes, jf_id, 0)
            episode_count = Map.get(series_episode_count, jf_id, 0)
            Map.put(acc, tmdb, {bytes, episode_count})
        end
      end)

    # All users who have ANY library entry (the "household").
    user_ids = list_user_ids_with_entries()
    user_name_by_id = Map.new(users, fn u -> {u["Id"], u["Name"]} end)

    user_ids
    |> Enum.map(fn user_id ->
      tmdb_ids = Library.list_tmdb_ids(user_id)
      stats = roll_up_for_user(tmdb_ids, movie_sizes_by_tmdb, series_stats_by_tmdb)

      Map.merge(stats, %{
        user_id: user_id,
        username: Map.get(user_name_by_id, user_id, "Unknown")
      })
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
  end

  @doc """
  Aggregate across the per-user breakdown — used by the Total row in
  the table. bytes_movies / bytes_shows are tracked separately because
  the table breaks them out row-by-row.
  """
  def totals(breakdown) do
    Enum.reduce(
      breakdown,
      %{
        movie_count: 0,
        show_count: 0,
        episode_count: 0,
        bytes: 0,
        bytes_movies: 0,
        bytes_shows: 0
      },
      fn entry, acc ->
        %{
          movie_count: acc.movie_count + entry.movie_count,
          show_count: acc.show_count + entry.show_count,
          episode_count: acc.episode_count + entry.episode_count,
          bytes: acc.bytes + entry.bytes,
          bytes_movies: acc.bytes_movies + entry.bytes_movies,
          bytes_shows: acc.bytes_shows + entry.bytes_shows
        }
      end
    )
  end

  @doc """
  Tank capacity in bytes (post-RAIDZ1 usable, from depot's
  `zfs list` output). Nil if `TANK_BYTES` env var isn't set —
  caller falls back to household-share scaling for the bar.
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
  precision: "42 GB", "1.2 TB", "—" for zero. Used by the stats
  table + legend.
  """
  def humanize_bytes(0), do: "—"
  def humanize_bytes(nil), do: "—"

  def humanize_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 ** 4 -> "#{format_float(bytes / 1024 ** 4)} TB"
      bytes >= 1024 ** 3 -> "#{format_float(bytes / 1024 ** 3)} GB"
      bytes >= 1024 ** 2 -> "#{format_float(bytes / 1024 ** 2)} MB"
      true -> "#{bytes} B"
    end
  end

  defp format_float(n) when n >= 100, do: "#{round(n)}"
  defp format_float(n), do: :erlang.float_to_binary(n, decimals: 1)

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
  # versions of the same media), but we only care about the primary.
  defp item_size(%{"MediaSources" => [%{"Size" => size} | _]}) when is_integer(size), do: size
  defp item_size(_), do: nil

  defp list_user_ids_with_entries do
    from(e in Library.Entry,
      distinct: true,
      select: e.jellyfin_user_id
    )
    |> Repo.all()
  end

  defp roll_up_for_user(tmdb_ids, movie_sizes_by_tmdb, series_stats_by_tmdb) do
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
            # tmdb_id in library_entries but no matching Jellyfin item
            # yet (e.g., still downloading) — nothing to count.
            acc
        end
      end
    )
  end
end
