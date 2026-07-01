defmodule Aviary.Home do
  @moduledoc """
  Computes the Continue Watching feed for the home page. Two
  filters in series:

    1. Jellyfin watch state — a show appears when the user has watch
       activity AND there's a next episode to play; movies appear
       when the user is mid-watch.
    2. `library_entries` membership — only shows the user has in
       their library pass. This is the gate the Remove-from-library
       button leans on: removing a show keeps it out of Continue
       Watching even if Jellyfin still has watch state on it.
       Movies aren't library-curated yet, so they bypass this gate.

  Watch-state reset (the X button on a Continue Watching card) and
  library removal (the link on the show detail page) are two separate
  actions with two separate effects — X clears Jellyfin state, the
  detail-page link removes the library entry. Either one is enough
  to keep a show out of CW.

  Sources merged: in-progress (resume), Jellyfin's NextUp, a locally
  derived next-up for series NextUp's index missed, recently added
  episodes, and recently watched. Dedupe picks "what to play next"
  per show (resume > NextUp/derived > latest > recent), then sorts
  the deduped list by the show's most-recent activity timestamp so
  the marquee leads with whatever the user touched last.
  """

  alias Aviary.Jellyfin

  # Used as a sort fallback so items with no parseable timestamps sort
  # last instead of crashing the comparator.
  @epoch ~U[1970-01-01 00:00:00Z]

  def continue_watching(auth) do
    # There is ONE calculation for "what should I watch next for this
    # show" — `Aviary.Catalog.continue_target/2`, the exact derivation
    # the detail page uses (most recently played, advance if done, else
    # the in-progress episode). Home does NOT rank Jellyfin's /Resume
    # against /NextUp; "resume" is not a competing source, it's just the
    # case where that one target episode carries a saved position. This
    # is why home and the detail page can never disagree about the
    # episode again — they run the same function.
    #
    # The Jellyfin endpoints below are used only to DISCOVER which shows
    # the user is actively watching (has an in-progress or recent watch,
    # or a pending next episode). The episode each show points at always
    # comes from `continue_target`.
    resume = Jellyfin.resume_items(auth)
    recent = Jellyfin.recently_watched(auth)
    next_up = Jellyfin.next_up_across_library(auth)

    episode_items =
      (resume ++ recent ++ next_up)
      |> Enum.filter(&(&1["Type"] == "Episode"))

    series_ids =
      episode_items
      |> Enum.map(& &1["SeriesId"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    series_names = series_names(episode_items)
    activity = latest_played_by_series(resume ++ recent)
    tmdb_map = Jellyfin.series_tmdb_map(series_ids, auth)
    library_set = MapSet.new(Aviary.Library.list_tmdb_ids(auth.id))

    show_cards =
      series_ids
      |> Task.async_stream(
        fn series_id -> {series_id, Aviary.Catalog.continue_target(series_id, auth)} end,
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {series_id, %{} = episode}} ->
          [show_card(series_id, episode, series_names, activity, tmdb_map)]

        _ ->
          []
      end)
      |> Enum.filter(&in_user_library?(&1, library_set))

    # Movies aren't episodic, so there's no "next" to advance to — an
    # in-progress movie (a resume position that isn't basically done) is
    # its own continue target; a finished one drops off.
    movie_cards =
      resume
      |> Enum.filter(&(&1["Type"] == "Movie"))
      |> Enum.reject(&Aviary.Catalog.basically_done?(&1["UserData"]))
      |> Enum.map(&normalize(&1, tmdb_map))
      |> Enum.reject(&is_nil/1)

    (show_cards ++ movie_cards)
    |> Enum.sort_by(& &1.sort_at, {:desc, DateTime})
  end

  defp show_card(series_id, episode, series_names, activity, tmdb_map) do
    %{
      dedupe_key: "series:#{series_id}",
      kind: :show,
      tmdb_id: Map.get(tmdb_map, series_id),
      play_item_id: episode.id,
      detail_id: series_id,
      # Series backdrop is the fallback; the home controller prefers the
      # target episode's own still (play_item_id) when it exists.
      thumbnail_item_id: series_id,
      thumbnail_kind: :backdrop,
      progress: episode_progress(episode),
      title: Map.get(series_names, series_id),
      subtitle: episode_subtitle_line(episode),
      # Order the row by the show's most recent activity, not the target
      # episode — an advanced-to "next up" episode has never been played
      # (last_played_at nil), but the show is as recent as the episode
      # the user just finished.
      sort_at: Map.get(activity, series_id) || episode.last_played_at || @epoch
    }
  end

  # series_id => first-seen SeriesName across the discovery items.
  defp series_names(episode_items) do
    Enum.reduce(episode_items, %{}, fn item, acc ->
      series_id = item["SeriesId"]
      name = item["SeriesName"] || item["Name"]

      if series_id && not Map.has_key?(acc, series_id) do
        Map.put(acc, series_id, name)
      else
        acc
      end
    end)
  end

  defp episode_progress(%{played_percentage: pct})
       when is_number(pct) and pct > 0 and pct < 100,
       do: Float.round(pct * 1.0, 1)

  defp episode_progress(_), do: nil

  defp episode_subtitle_line(%{season: s, episode: e, title: name}) do
    cond do
      is_integer(s) and is_integer(e) and is_binary(name) -> "S#{s} · E#{e} · #{name}"
      is_integer(s) and is_integer(e) -> "S#{s} · E#{e}"
      is_binary(name) -> name
      true -> nil
    end
  end

  # Shows have to be in the user's library_entries to surface.
  # Movies aren't per-user-curated yet, so they always pass.
  defp in_user_library?(%{kind: :movie}, _library_set), do: true

  defp in_user_library?(%{kind: :show, tmdb_id: tmdb_id}, library_set)
       when is_binary(tmdb_id) do
    MapSet.member?(library_set, tmdb_id)
  end

  defp in_user_library?(_, _), do: false

  # series_id => most recent LastPlayedDate across recently-played
  # episodes. Used to detect resume positions the user has watched past.
  defp latest_played_by_series(recent) do
    recent
    |> Enum.filter(&(&1["Type"] == "Episode"))
    |> Enum.group_by(& &1["SeriesId"])
    |> Map.new(fn {series_id, items} ->
      latest =
        items
        |> Enum.map(&parse_date(get_in(&1, ["UserData", "LastPlayedDate"])))
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)

      {series_id, latest}
    end)
  end

  # In-progress movie → a Continue Watching card. Movies have no "next"
  # to advance to, so an in-progress one is its own target.
  defp normalize(%{"Type" => "Movie"} = item, _tmdb_map) do
    %{
      dedupe_key: "movie:#{item["Id"]}",
      kind: :movie,
      tmdb_id: nil,
      played: get_in(item, ["UserData", "Played"]) == true,
      progress: watch_progress(item["UserData"]),
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

  defp normalize(_, _), do: nil

  # Fraction watched, for the resume bar on a Continue Watching card.
  # nil unless the item is genuinely mid-watch: a fresh next-up episode
  # reads 0% and a finished item reads ~100%, and both should render no
  # bar. Reads the SAME percentage the detail page's next-up logic uses
  # (Aviary.Catalog.played_percentage), so the bar and the resume
  # target can't disagree.
  defp watch_progress(user_data) do
    pct = Aviary.Catalog.played_percentage(user_data)
    if pct > 0 and pct < 100, do: Float.round(pct * 1.0, 1), else: nil
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
