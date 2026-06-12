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

    # NextUp's whole job is "what should the user watch next on this
    # show" — a show NOT in this set means the user is caught up on
    # it. Use that as the filter: an episode item is only surfaced if
    # its series has something to watch next. Without this, a show
    # whose last available episode the user just finished keeps
    # showing up in Continue Watching (with a misleading "Continue
    # S X E Y" tile that just replays the finished episode from start)
    # until the next episode lands.
    available_series = MapSet.new(next_up, & &1["SeriesId"])

    # Four sources, each catching a different case. Mid-watch shows
    # come through Resume; caught-up shows come through Recent (the
    # actually-most-recently-watched episode, which Resume misses
    # because ticks=0 once Played auto-flips). NextUp + Latest cover
    # shows with new episodes the user hasn't started. The sort_at
    # dedupe picks the right tile per show without per-source
    # branching.
    (next_up ++ resume ++ latest ++ recent)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&caught_up?(&1, available_series))
    |> dedupe_by_key()
    |> Enum.sort_by(& &1.sort_at, {:desc, DateTime})
  end

  defp caught_up?(%{kind: :show, dedupe_key: "series:" <> series_id}, available_series) do
    not MapSet.member?(available_series, series_id)
  end

  defp caught_up?(_, _), do: false

  # Collapses raw Jellyfin items into a uniform shape the home marquee
  # can render without further branching. `dedupe_key` makes the same
  # show appear once even when it's surfaced by multiple endpoints.
  defp normalize(%{"Type" => "Movie"} = item) do
    %{
      dedupe_key: "movie:#{item["Id"]}",
      kind: :movie,
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

  defp normalize(%{"Type" => "Episode"} = item) do
    series_id = item["SeriesId"]
    if is_nil(series_id), do: nil, else: do_episode(item, series_id)
  end

  defp normalize(_), do: nil

  defp do_episode(item, series_id) do
    %{
      dedupe_key: "series:#{series_id}",
      kind: :show,
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
