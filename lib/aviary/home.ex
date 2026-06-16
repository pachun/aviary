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
    resume = Jellyfin.resume_items(auth)
    next_up = Jellyfin.next_up_across_library(auth)
    latest = Jellyfin.latest_episodes(auth)
    recent = Jellyfin.recently_watched(auth)

    jellyfin_next_up_set = MapSet.new(next_up, & &1["SeriesId"])

    # Jellyfin's `/Shows/NextUp` index lags UserData writes — after
    # the watch-mark UI fans out mark_played calls, NextUp may not
    # include the affected series for some time (and sometimes
    # never, when its library scanner hasn't picked up the next
    # downloaded file yet). For any series the user is actively
    # engaged with (resume position or recently played) that NextUp
    # skipped, look up the next unplayed in-library episode
    # ourselves. The synthesized item joins `all_items` so the
    # dedupe step has a fresh "what to play next" candidate, and
    # the series joins `available_series` so the caught_up gate
    # doesn't filter it.
    active_series_ids = active_series_ids(resume, recent)

    derived =
      active_series_ids
      |> Enum.reject(&MapSet.member?(jellyfin_next_up_set, &1))
      |> Task.async_stream(
        fn series_id -> {series_id, Jellyfin.next_unplayed_episode(series_id, auth)} end,
        max_concurrency: 8,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, kv} -> kv
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(fn {_, ep} -> ep == nil end)

    synthesized = Enum.map(derived, fn {_, ep} -> ep end)
    derived_series_ids = MapSet.new(derived, fn {sid, _} -> sid end)
    available_series = MapSet.union(jellyfin_next_up_set, derived_series_ids)

    # Tag every item with its source priority. Sources that point at
    # "what to play next" (resume, NextUp, our synthesized derivation)
    # outrank sources that point at "what was just played or recently
    # added" — without this, a freshly-marked-played episode would
    # win dedupe over the actual next-up episode just because its
    # LastPlayedDate is now. Resume beats NextUp so a mid-episode
    # always shows up as the resume target.
    tagged =
      Enum.map(resume, &{0, &1}) ++
        Enum.map(next_up, &{1, &1}) ++
        Enum.map(synthesized, &{1, &1}) ++
        Enum.map(latest, &{3, &1}) ++
        Enum.map(recent, &{4, &1})

    all_items = Enum.map(tagged, fn {_, item} -> item end)

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

    # Per-user library gate. After we added the Remove-from-library
    # button, "is this in my library_entries" became a real signal
    # of intent: removing a show should keep it out of Continue
    # Watching even if Jellyfin still has watch state on it. Movies
    # aren't library-curated yet, so they pass through untouched.
    library_set = MapSet.new(Aviary.Library.list_tmdb_ids(auth.id))

    tagged
    |> Enum.map(fn {priority, item} ->
      case normalize(item, tmdb_map) do
        nil -> nil
        n -> Map.put(n, :priority, priority)
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&caught_up?(&1, available_series))
    |> Enum.filter(&in_user_library?(&1, library_set))
    |> dedupe_by_key()
    |> Enum.sort_by(& &1.sort_at, {:desc, DateTime})
  end

  # Shows have to be in the user's library_entries to surface.
  # Movies aren't per-user-curated yet, so they always pass.
  defp in_user_library?(%{kind: :movie}, _library_set), do: true

  defp in_user_library?(%{kind: :show, tmdb_id: tmdb_id}, library_set)
       when is_binary(tmdb_id) do
    MapSet.member?(library_set, tmdb_id)
  end

  defp in_user_library?(_, _), do: false

  defp active_series_ids(resume, recent) do
    (resume ++ recent)
    |> Enum.filter(&(&1["Type"] == "Episode"))
    |> Enum.map(& &1["SeriesId"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp caught_up?(%{kind: :show, dedupe_key: "series:" <> series_id}, available_series) do
    not MapSet.member?(available_series, series_id)
  end

  defp caught_up?(_, _), do: false

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

  # Per dedupe_key, pick the item that best answers "what should this
  # user play next for this show?" — by source priority (resume >
  # NextUp/synthesized > latest > recent), tie-broken by recency. We
  # then stamp the winner's sort_at with the *most recent* sort_at
  # across the group, so the outer marquee ordering still reflects
  # how recently the show saw any activity — otherwise a R&M just
  # marked-watched would show E3 but get pushed down the row because
  # E3's DateCreated is older than the just-marked LastPlayedDate.
  defp dedupe_by_key(items) do
    items
    |> Enum.group_by(& &1.dedupe_key)
    |> Enum.map(fn {_key, group} ->
      winner =
        Enum.min_by(group, fn item ->
          {item.priority, -DateTime.to_unix(item.sort_at, :millisecond)}
        end)

      max_sort_at = Enum.max_by(group, & &1.sort_at, DateTime).sort_at
      %{winner | sort_at: max_sort_at}
    end)
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
