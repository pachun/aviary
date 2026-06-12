defmodule Aviary.Home do
  @moduledoc """
  Computes the Continue Watching feed for the home page. Merges three
  Jellyfin streams — in-progress items, NextUp episodes, and recently
  added episodes — into a single ordered list where the most-recent
  event (started watching, finished an episode, new episode aired)
  determines position. Each unique show appears once; movies appear
  once.
  """

  alias Aviary.Jellyfin

  # Used as a sort fallback so items with no parseable timestamps sort
  # last instead of crashing the comparator.
  @epoch ~U[1970-01-01 00:00:00Z]

  def continue_watching(auth) do
    resume = Jellyfin.resume_items(auth)
    next_up = Jellyfin.next_up_across_library(auth)
    latest = Jellyfin.latest_episodes(auth)
    recent = Jellyfin.recently_watched(auth)

    all_items = next_up ++ resume ++ latest ++ recent

    # NextUp's whole job is "what should the user watch next on this
    # show" — a show NOT in this set means the user is caught up on
    # it. Use that as the filter: an episode item is only surfaced if
    # its series has something to watch next.
    available_series = MapSet.new(next_up, & &1["SeriesId"])

    # Series → TMDB id map. One batch Jellyfin call covers every
    # unique series that came through any of the four sources, so
    # downstream filtering by library membership is just a MapSet
    # check, not N round-trips.
    series_ids =
      all_items
      |> Enum.filter(&(&1["Type"] == "Episode"))
      |> Enum.map(& &1["SeriesId"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    tmdb_map = Jellyfin.series_tmdb_map(series_ids, auth)
    library = MapSet.new(Aviary.Library.list_tmdb_ids(auth.id))

    all_items
    |> Enum.map(&normalize(&1, tmdb_map))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&caught_up?(&1, available_series))
    |> Enum.filter(&in_library?(&1, library))
    |> dedupe_by_key()
    |> Enum.sort_by(& &1.sort_at, {:desc, DateTime})
  end

  defp caught_up?(%{kind: :show, dedupe_key: "series:" <> series_id}, available_series) do
    not MapSet.member?(available_series, series_id)
  end

  defp caught_up?(_, _), do: false

  # Library gating: a show is surfaced only if the user has it in
  # their library_entries. Movies don't go through library entries
  # (yet) — they always pass through. Discover-flow library shows
  # without a known TMDB id (rare, but possible if ProviderIds.Tmdb
  # is missing) get dropped — without a TMDB id we can't reliably
  # link them to library entries or Sonarr/Jellyseerr downstream.
  defp in_library?(%{kind: :movie}, _library), do: true
  defp in_library?(%{kind: :show, tmdb_id: nil}, _library), do: false

  defp in_library?(%{kind: :show, tmdb_id: tmdb_id}, library) do
    MapSet.member?(library, tmdb_id)
  end

  # Collapses raw Jellyfin items into a uniform shape the home marquee
  # can render without further branching. `dedupe_key` makes the same
  # show appear once even when it's surfaced by multiple endpoints.
  defp normalize(%{"Type" => "Movie"} = item, _tmdb_map) do
    %{
      dedupe_key: "movie:#{item["Id"]}",
      kind: :movie,
      tmdb_id: nil,
      play_item_id: item["Id"],
      detail_id: item["Id"],
      thumbnail_item_id: item["Id"],
      thumbnail_kind: :backdrop,
      title: item["Name"],
      subtitle: nil,
      sort_at:
        parse_date(get_in(item, ["UserData", "LastPlayedDate"])) ||
          parse_date(item["DateCreated"]) ||
          @epoch
    }
  end

  defp normalize(%{"Type" => "Episode"} = item, tmdb_map) do
    series_id = item["SeriesId"]
    if is_nil(series_id), do: nil, else: do_episode(item, series_id, tmdb_map)
  end

  defp normalize(_, _), do: nil

  defp do_episode(item, series_id, tmdb_map) do
    %{
      dedupe_key: "series:#{series_id}",
      kind: :show,
      tmdb_id: Map.get(tmdb_map, series_id),
      play_item_id: item["Id"],
      detail_id: series_id,
      thumbnail_item_id: item["Id"],
      thumbnail_kind: :primary,
      title: item["SeriesName"] || item["Name"],
      subtitle: episode_subtitle(item),
      sort_at:
        parse_date(get_in(item, ["UserData", "LastPlayedDate"])) ||
          parse_date(item["DateCreated"]) ||
          parse_date(item["PremiereDate"]) ||
          @epoch
    }
  end

  defp episode_subtitle(item) do
    s = item["ParentIndexNumber"]
    e = item["IndexNumber"]
    name = item["Name"]

    cond do
      is_integer(s) and is_integer(e) and is_binary(name) -> "S#{s} · E#{e} · #{name}"
      is_integer(s) and is_integer(e) -> "S#{s} · E#{e}"
      is_binary(name) -> name
      true -> nil
    end
  end

  # When the same show is surfaced by both Resume and NextUp/Latest,
  # the one with the most recent sort_at wins. We sort by sort_at desc
  # first, then take the first occurrence of each dedupe_key.
  defp dedupe_by_key(items) do
    items
    |> Enum.sort_by(& &1.sort_at, {:desc, DateTime})
    |> Enum.uniq_by(& &1.dedupe_key)
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
