defmodule AviaryWeb.ShowsDetailLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid
  alias AviaryWeb.Components.ReleaseCalendar
  alias AviaryWeb.Components.VideoPlayer

  # Sonarr poll cadence. 5s feels fast enough that a button press →
  # download-progress transition reads as "the page reacted to my
  # click," and slow enough that a household of users browsing
  # multiple show pages doesn't hammer Sonarr's API. The polling
  # process is bounded — it dies when the LV unmounts.
  @sonarr_poll_ms 5_000

  def mount(%{"id" => id} = params, _session, socket) do
    case Aviary.Catalog.get_show(id, socket.assigns.current_user) do
      {:ok, show} ->
        # If we landed here from /search, record the query as a
        # committed search — that click-through is the signal that
        # turns "you've got mai" debounce noise into "you've got
        # mail." See Aviary.RecentSearches for the why.
        Aviary.RecentSearches.record_if_from_search(
          socket.assigns.current_user.id,
          params
        )

        socket =
          socket
          |> assign(
            page_title: "#{show.title} · Aviary",
            show: show,
            playing_item: nil,
            playing_segments: nil,
            playing_subtitles: [],
            playing_audio_index: nil,
            kicker: kicker(params["from"], params["q"]),
            sonarr_status: nil,
            collapsed_seasons: initial_collapsed_seasons(show),
            imported_stuck_since: nil,
            in_library: in_library?(show, socket.assigns.current_user)
          )
          |> fetch_sonarr_status()
          |> schedule_sonarr_poll()

        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Show not found")
         |> push_navigate(to: ~p"/library?type=shows")}
    end
  end

  def handle_info(:poll_sonarr, socket) do
    {:noreply,
     socket
     |> fetch_sonarr_status()
     |> refresh_show_if_imported()
     |> schedule_sonarr_poll()}
  end

  def handle_info(:reconcile_watch_point, socket) do
    case Aviary.Catalog.get_show(socket.assigns.show.id, socket.assigns.current_user) do
      {:ok, refreshed} -> {:noreply, assign(socket, :show, refreshed)}
      _ -> {:noreply, socket}
    end
  end

  # Side-effects that piggyback on the Sonarr poll to keep the chip
  # feeling live:
  #
  #   * Any episode currently :downloading → kick Sonarr to refresh
  #     its qBit download progress now. Sonarr's own
  #     RefreshMonitoredDownloads scheduled task fires every ~90 s,
  #     so without this nudge the percentage chip updates in big
  #     chunks and gets stuck on the last-reported value for up to
  #     90 s after qBit finishes.
  #
  #   * Any episode :imported (Sonarr has the file, Jellyfin doesn't
  #     yet) → ask Jellyfin to scan the series folder via
  #     /Library/Media/Updated. Without it the chip can sit on
  #     "Importing…" for hours waiting on Jellyfin's scheduled scan.
  #     Path comes from Sonarr (it owns the on-disk layout); the
  #     scan endpoint expects the path Sonarr/Jellyfin agree on.
  #     Discover shows skip the scan because we have no path to
  #     hand to Jellyfin until Sonarr resolves the series, but
  #     Sonarr-side already does refresh them.
  #
  # Both side-effects are throttled per-show via the cache so a
  # multi-second poll cadence doesn't pile up requests on Sonarr or
  # Jellyfin. The throttle uses a TTL'd cache entry as a poor
  # man's "did we already do this in the last N seconds" check.
  #
  # When :imported is detected we also invalidate our own
  # list_episodes cache so the same-tick get_show re-fetch goes to
  # Jellyfin instead of returning the stale pre-scan view.
  defp refresh_show_if_imported(socket) do
    show = socket.assigns.show
    status = socket.assigns.sonarr_status
    user = socket.assigns.current_user

    states =
      show.episodes_by_season
      |> Enum.flat_map(fn {_, eps} -> eps end)
      |> Enum.map(fn ep -> episode_state(show, ep, status) end)

    has_downloading? =
      Enum.any?(states, fn
        {:downloading, _} -> true
        _ -> false
      end)

    has_imported? = Enum.any?(states, &(&1 == :imported))

    if has_downloading? do
      throttle({:sonarr_dl_refresh, show.id}, 5_000, fn ->
        Aviary.Sonarr.refresh_monitored_downloads()
      end)
    end

    if has_imported? do
      # Library-wide refresh, throttled globally — depot's compose
      # files mount the shows directory at different paths inside
      # Sonarr's and Jellyfin's containers (Sonarr: /shows,
      # Jellyfin: /media/shows), so a path-targeted scan needs
      # translation we don't currently do. The library-wide scan
      # works regardless and Jellyfin dedupes concurrent triggers.
      # 5s throttle matches our Sonarr poll cadence — while a chip is
      # in "Importing…" we want Jellyfin re-scanning continuously,
      # not stuck behind a 15s lull.
      throttle(:jellyfin_library_refresh, 5_000, fn ->
        Aviary.Jellyfin.refresh_library(user)
      end)

      socket = auto_escalate_if_stuck(socket, show, user)

      Aviary.Cache.invalidate({:jellyfin_list_episodes, show.id, user.id})

      case Aviary.Catalog.get_show(show.id, user) do
        {:ok, refreshed} -> assign(socket, :show, refreshed)
        _ -> socket
      end
    else
      # No episode is :imported anymore — clear the stuck stamp so
      # if it re-enters the state later, the 2-minute clock starts
      # from zero rather than counting from a previous incident.
      assign(socket, :imported_stuck_since, nil)
    end
  end

  # The light /Library/Refresh fires every 15s while any episode is
  # `:imported`. That usually unsticks things within a poll or two.
  # If it hasn't — i.e. the show has been in :imported state for
  # more than 2 minutes — Jellyfin's scanner has likely cached a
  # "skip this series" decision that only a full refresh + replace
  # metadata can dislodge. We fire that here, throttled to once per
  # 10 minutes per series so it doesn't run unboundedly in pathological
  # cases where even the heavy refresh can't fix the underlying
  # problem (corrupt file, codec Jellyfin can't probe, etc.).
  #
  # The user never sees this happen — the chip continues to say
  # "Importing…" while the auto-retry runs in the background. If
  # the retry works, the chip flips to "Play" on the next poll. If
  # it doesn't, well, we tried; future poll cycles keep trying at
  # the 10-min cadence.
  @stuck_threshold_ms 120_000
  defp auto_escalate_if_stuck(socket, show, user) do
    now = System.monotonic_time(:millisecond)
    stuck_since = socket.assigns[:imported_stuck_since]

    cond do
      is_nil(stuck_since) ->
        # First time seeing :imported this session — start the clock.
        assign(socket, :imported_stuck_since, now)

      now - stuck_since >= @stuck_threshold_ms ->
        # show.id is a Jellyfin series id only for library shows;
        # discover shows have a TMDB id there, which Jellyfin would
        # reject. The library-wide /Library/Refresh upstream of this
        # function still runs for both cases.
        if show.source == :library do
          throttle({:jellyfin_full_refresh, show.id}, 600_000, fn ->
            Aviary.Jellyfin.full_refresh_series(show.id, user)
          end)
        end

        socket

      true ->
        socket
    end
  end

  # Run `fun` at most once per `cooldown_ms` for the given key.
  # Implemented on top of `Aviary.Cache.fetch/3`: a cache hit (entry
  # still fresh) means "we already ran this recently, skip"; a miss
  # means "cooldown elapsed, run again and stamp the entry."
  defp throttle(key, cooldown_ms, fun) do
    Aviary.Cache.fetch(key, cooldown_ms, fn ->
      fun.()
      :stamped
    end)

    :ok
  end

  defp fetch_sonarr_status(socket) do
    status =
      case Aviary.Sonarr.series_status(socket.assigns.show.tmdb_id) do
        {:ok, status} -> status
        _ -> nil
      end

    assign(socket, :sonarr_status, status)
  end

  defp schedule_sonarr_poll(socket) do
    if connected?(socket) do
      Process.send_after(self(), :poll_sonarr, @sonarr_poll_ms)
    end

    socket
  end

  # Whether THIS user has the show in their library_entries — gates
  # the "Remove from library" vs "Add to library" affordance. Discover-
  # source shows (not yet in Jellyfin at all) skip this entirely; the
  # existing Watch flow handles them.
  defp in_library?(%{source: :library, tmdb_id: tmdb_id}, user) when is_binary(tmdb_id) do
    Aviary.Library.member?(user.id, tmdb_id)
  end

  defp in_library?(_, _), do: false

  defp kicker("home", _), do: %{label: "Home", path: "/home"}
  defp kicker("discover", _), do: %{label: "Discover", path: "/discover"}
  defp kicker("library_movies", _), do: %{label: "Library", path: "/library?type=movies"}

  defp kicker("search", q) when is_binary(q) and q != "",
    do: %{label: "Search", path: "/search?q=" <> URI.encode_www_form(q)}

  defp kicker("search", _), do: %{label: "Search", path: "/search"}
  defp kicker(_, _), do: %{label: "Library", path: "/library?type=shows"}

  # Three handlers, one routing rule: an episode id with the `tmdb-`
  # prefix means "not in Jellyfin's library yet" and routes to
  # Sonarr; anything else is a Jellyfin id and routes to playback.
  # Works uniformly across discover shows (everything `tmdb-`) and
  # library shows (mix of Jellyfin ids and `tmdb-` ids for episodes
  # not yet downloaded).

  # Each handler shares the same shape: an episode id that's a real
  # Jellyfin id routes to playback, a `tmdb-` id routes to Sonarr
  # IF the episode isn't already being worked on. Already-in-progress
  # episodes no-op so a click on a downloading or searching chip
  # doesn't fire a duplicate Sonarr command (and doesn't spam another
  # "grabbing…" flash for work already in flight).

  def handle_event("play", _, socket) do
    if in_progress?(show_state(socket.assigns.show, socket.assigns.sonarr_status)) do
      {:noreply, socket}
    else
      case pick_continue_episode(socket.assigns.show) do
        nil -> trigger_sonarr(socket, :show, nil, nil)
        %{id: "tmdb-" <> _} -> trigger_sonarr(socket, :show, nil, nil)
        ep -> {:noreply, start_playing(socket, ep)}
      end
    end
  end

  # Moves the show's watch mark to the clicked episode. The mark is a
  # SINGLE POINT on the timeline: everything before (and the click) is
  # Played, everything after is unplayed. We fan out mark_played for
  # 1..click and mark_unplayed for click+1..end — the latter matters
  # when the user is moving the mark BACKWARD (an earlier test left
  # E5 played; clicking E2 now should make E3+ unplayed so NextUp and
  # Continue Watching reflect "caught up through E2"). TMDB-only
  # entries (not-yet-downloaded episodes) are skipped — Jellyfin has
  # nothing to mark for them.
  def handle_event("toggle_season", %{"season" => season}, socket) do
    season = String.to_integer(season)
    collapsed = socket.assigns.collapsed_seasons

    next =
      if MapSet.member?(collapsed, season),
        do: MapSet.delete(collapsed, season),
        else: MapSet.put(collapsed, season)

    {:noreply, assign(socket, :collapsed_seasons, next)}
  end

  def handle_event("set_watch_point", %{"id" => episode_id}, socket) do
    show = socket.assigns.show
    user = socket.assigns.current_user

    flat = Enum.flat_map(show.episodes_by_season, fn {_, eps} -> eps end)

    case Enum.find_index(flat, &(&1.id == episode_id)) do
      nil ->
        {:noreply, socket}

      idx ->
        # Watch-mark is an engagement signal — ensure the show is in
        # library_entries so Upcoming surfaces its drops. (Play and
        # Sonarr-trigger already do this; without this call, marking
        # via the marker column would never register.)
        if show.tmdb_id, do: Aviary.Library.add(user.id, show.tmdb_id)

        not_tmdb? = &(not String.starts_with?(to_string(&1.id), "tmdb-"))

        {prior, future} = Enum.split(flat, idx + 1)
        to_mark = Enum.filter(prior, not_tmdb?)
        to_unmark = Enum.filter(future, not_tmdb?)

        # Optimistic UI: snap the in-memory show so the marker
        # moves on the next render — N×Jellyfin RTT + a full
        # get_show round-trip was the source of the perceived
        # lag. The actual writes run in a background task; when
        # they settle, the live view reconciles against canonical
        # Jellyfin state.
        pid = self()

        Task.start(fn ->
          (Enum.map(to_mark, &{:played, &1}) ++ Enum.map(to_unmark, &{:unplayed, &1}))
          |> Task.async_stream(
            fn
              {:played, ep} -> Aviary.Jellyfin.mark_played(ep.id, user)
              {:unplayed, ep} -> Aviary.Jellyfin.mark_unplayed(ep.id, user)
            end,
            max_concurrency: 5,
            timeout: 5_000,
            on_timeout: :kill_task
          )
          |> Stream.run()

          send(pid, :reconcile_watch_point)
        end)

        {:noreply, assign(socket, :show, apply_optimistic_watch_point(show, flat, idx))}
    end
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    case find_episode(socket.assigns.show, episode_id) do
      nil ->
        {:noreply, socket}

      %{id: "tmdb-" <> _} = ep ->
        if in_progress?(episode_state(socket.assigns.show, ep, socket.assigns.sonarr_status)) do
          {:noreply, socket}
        else
          trigger_sonarr(socket, :episode, ep.season, ep.episode)
        end

      ep ->
        {:noreply, start_playing(socket, ep)}
    end
  end

  def handle_event("close_player", _, socket) do
    # Refresh nav_visibility because playing something for the first
    # time added a library_entries row + flipped Jellyfin's Continue
    # Watching state; without this the user closes the player and
    # sees the same "no Library / no Home tab" nav they started with
    # until they manually navigate to trigger a fresh mount.
    {:noreply,
     socket
     |> assign(:playing_item, nil)
     |> assign(:playing_segments, nil)
     |> assign(:playing_subtitles, [])
     |> assign(:playing_audio_index, nil)
     |> Aviary.Nav.refresh_visibility()}
  end

  # Per-user library curation. "Remove" is reversible and doesn't
  # touch files — it just deletes the library_entries row, which gates
  # the Library page and the Upcoming feed for this user. The same
  # show stays in Jellyfin / Sonarr / qBit untouched, so a later add
  # for this user or a fresh add for another household member is a
  # single DB insert with no download step.
  def handle_event("remove_from_library", _, socket) do
    user = socket.assigns.current_user
    show = socket.assigns.show

    if show.tmdb_id do
      Aviary.Library.remove(user.id, show.tmdb_id, "show")
    end

    # Landing destination after a remove. Staying on the now-orphaned
    # detail page would force the user to navigate away themselves
    # and read a banner like "removed from library" against the same
    # poster they just removed. Better: drop them where the next
    # action lives.
    #
    #   - any shows still in library      → /library?type=shows
    #   - no shows, but movies in library → /library?type=movies
    #   - neither                         → /discover
    #
    # Catalog.list_shows / list_movies are filtered by library_entries,
    # so they see the post-remove state on this call.
    destination =
      cond do
        Aviary.Catalog.list_shows(user) != [] -> ~p"/library?type=shows"
        Aviary.Catalog.list_movies(user) != [] -> ~p"/library?type=movies"
        true -> ~p"/discover"
      end

    {:noreply,
     socket
     |> put_flash(:info, "#{show.title} removed from your library.")
     |> push_navigate(to: destination)}
  end

  def handle_event("add_to_library", _, socket) do
    user = socket.assigns.current_user
    show = socket.assigns.show

    if show.tmdb_id do
      Aviary.Library.add(user.id, show.tmdb_id)
    end

    {:noreply,
     socket
     |> assign(:in_library, true)
     |> Aviary.Nav.refresh_visibility()
     |> put_flash(:info, "#{show.title} added to your library.")}
  end

  def handle_event("report_progress", %{"position" => position} = payload, socket) do
    item = socket.assigns.playing_item

    if item do
      user = socket.assigns.current_user
      duration = payload["duration"]

      # Past 95% of the runtime = effectively done. mark_played
      # (canonical endpoint + position zero) is what makes
      # Jellyfin's NextUp move on to the next episode; without it
      # Resume keeps E5 looking in-progress and Continue Watching
      # surfaces E5 instead of E6.
      if is_number(duration) and duration > 0 and position / duration >= 0.95 do
        Aviary.Jellyfin.mark_played(item.id, user)
        {:noreply, update(socket, :show, &update_episode_progress(&1, item.id, 0.0))}
      else
        position_ticks = trunc(position * 10_000_000)
        Aviary.Jellyfin.save_position(item.id, position_ticks, user)

        # Mirror the in-memory resume_seconds on the corresponding
        # episode so the Continue button label stays accurate after
        # closing.
        {:noreply, update(socket, :show, &update_episode_progress(&1, item.id, position))}
      end
    else
      {:noreply, socket}
    end
  end

  # One small chip used by both episode rows and the season header.
  # Three visual states share the same geometry (so the layout never
  # shifts as a chip transitions):
  #   ready/playable → filled oxblood, the editorial Play affordance
  #   queued         → muted oxblood pill saying "Queued"
  #   downloading    → progress-fill chip with a transient inner bar
  #                    that grows left→right; the text reads the %
  # Inert states render as <span> (not <button>) so the parent button
  # remains the only click target — same hit area as the row.
  attr :state, :any, required: true
  attr :label, :string, required: true

  # Every chip variant uses these shared dimensions so the right
  # edge of every episode row aligns vertically through every state
  # transition (▶ Play → ↓ → Searching… → 42% → Importing… → ▶ Play
  # all stay the same pixel width). w-28 is wide enough for
  # "Importing…" / "Searching…" at 0.7rem tracked uppercase without
  # wrapping. text-center centers the shorter labels (Play, ↓, 42%).
  @chip_base "inline-block w-28 text-center font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium px-3 py-1.5 rounded-sm shrink-0"

  defp action_chip(assigns) do
    assigns = assign(assigns, :chip_base, @chip_base)

    ~H"""
    <%= case @state do %>
      <% {:downloading, pct} -> %>
        <span class={[@chip_base, "relative overflow-hidden text-white bg-oxblood/20 tabular-nums"]}>
          <span
            class="absolute inset-y-0 left-0 bg-oxblood transition-all duration-700 ease-out"
            style={"width: #{pct}%"}
          >
          </span>
          <span class="relative">{pct}%</span>
        </span>
      <% :searching -> %>
        <span class={[@chip_base, "bg-oxblood/40 text-white/80"]}>Searching…</span>
      <% :queued -> %>
        <span class={[@chip_base, "bg-oxblood/40 text-white/80"]}>Queued</span>
      <% :imported -> %>
        <span class={[@chip_base, "bg-oxblood/40 text-white/80"]}>Importing…</span>
      <% :stuck -> %>
        <%!--
          Visually neutral (no oxblood) so it reads as "halted, waiting
          on you" rather than "aviary is doing something." Sonarr's
          flagged the queue record with a warning the user has to
          resolve — typically "Not an upgrade for existing episode
          file(s)" or similar. Aviary can't unstick it on its own.
        --%>
        <span class={[@chip_base, "bg-rule text-muted"]}>Blocked</span>
      <% :ready -> %>
        <%!--
          Not in the tank yet. The label here is a typographic down
          arrow (↓, U+2193) rather than the "▶ Play" wording of the
          :playable case — the action this triggers is "start a
          download," not "press play." [letter-spacing:0] kills the
          chip_base tracking — the arrow glyph shouldn't carry the
          uppercase-tracked rhythm; it'd look distended.
        --%>
        <span
          aria-label="Download"
          class={[@chip_base, "bg-oxblood text-white transition-opacity opacity-90 group-hover:opacity-100 [letter-spacing:0]"]}
        >
          ↓
        </span>
      <% _ -> %>
        <span class={[@chip_base, "bg-oxblood text-white transition-opacity opacity-90 group-hover:opacity-100"]}>
          {@label}
        </span>
    <% end %>
    """
  end

  # Top-of-page primary action button. Bigger sibling of action_chip
  # with the same state machine, but reserves the existing morphing
  # label (Resume/Continue/Play/Watch/Caught up/etc.) for the
  # ready/playable case so the editorial language in the label still
  # lives in `action_label/1`.
  attr :show, :map, required: true
  attr :status, :any, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp top_action_button(assigns) do
    state = show_state(assigns.show, assigns.status)
    assigns = assign(assigns, :state, state)

    ~H"""
    <%= case @state do %>
      <% {:downloading, pct} -> %>
        <div class="relative overflow-hidden inline-block bg-oxblood/20 text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm tabular-nums">
          <span
            class="absolute inset-y-0 left-0 bg-oxblood transition-all duration-700 ease-out"
            style={"width: #{pct}%"}
          >
          </span>
          <span class="relative">{pct}%</span>
        </div>
      <% :searching -> %>
        <div class="inline-block bg-oxblood/40 text-white/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Searching…
        </div>
      <% :queued -> %>
        <div class="inline-block bg-oxblood/40 text-white/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Queued
        </div>
      <% :imported -> %>
        <div class="inline-block bg-oxblood/40 text-white/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Importing…
        </div>
      <% :stuck -> %>
        <%!-- See action_chip :stuck for rationale on the neutral palette. --%>
        <div class="inline-block bg-rule text-muted font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Blocked
        </div>
      <% _ -> %>
        <button
          type="button"
          phx-click="play"
          disabled={@disabled}
          class="bg-oxblood text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 disabled:opacity-40 disabled:cursor-not-allowed focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
        >
          {@label}
        </button>
    <% end %>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :mark, watch_mark(assigns.show))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_visibility={@nav_visibility}
      current_section={String.downcase(@kicker.label)}
      mobile_title={@show.title}
      mobile_back_to={@kicker.path}
      mobile_back_label={@kicker.label}
    >
      <article>
        <div class={[
          "grid grid-cols-1 md:grid-cols-[260px_1fr] gap-8 pt-4"
        ]}>
          <%!--
            Poster (hidden on mobile, matches movie detail). poster_url
            is set by Catalog.get_show — for library shows it's the
            aviary image proxy; for discover shows it's the TMDB CDN.
            Same field, same render, source abstracted away.
          --%>
          <div class="hidden md:block">
            <img
              src={@show.poster_url}
              alt={@show.title}
              class="w-full aspect-[2/3] object-cover rounded-sm bg-rule"
            />
          </div>

          <div class="flex flex-col gap-4">
            <div class={[
              "grid grid-cols-1 gap-4 lg:gap-6 lg:items-start",
              upper_right_present?(@show) && "lg:grid-cols-[1fr_360px]"
            ]}>
              <div class="flex flex-col gap-4">
                <.link
                  navigate={@kicker.path}
                  class="w-fit font-sans text-xs tracking-[0.18em] uppercase font-medium px-5 py-2 rounded-sm border border-oxblood text-oxblood transition-colors hover:bg-oxblood/5 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                >
                  ← {@kicker.label}
                </.link>

                <h1
                  data-mobile-top-bar-trigger
                  class="font-heading text-ink tracking-tight leading-[1.1]"
                  style="font-size: clamp(1.5rem, 2.5vw + 0.25rem, 2.5rem); font-variation-settings: 'opsz' 36;"
                >
                  {@show.title}
                </h1>

                <div class="font-sans text-[0.8rem] tracking-[0.14em] uppercase text-muted">
                  {metadata_line(@show)}
                </div>

                <CatalogGrid.rotten_tomatoes
                  :if={@show.rating}
                  rating={@show.rating}
                  center={false}
                />

                <div class="space-y-2">
                  <.top_action_button
                    show={@show}
                    status={@sonarr_status}
                    label={action_label(@show)}
                    disabled={action_disabled?(@show)}
                  />
                  <%!--
                    Live "until in your library" line. Tracks the same
                    state machine as the button itself; in the
                    downloading state it shows live timeleft from
                    Sonarr's queue (first-episode-of-first-season,
                    since that's what determines when the show
                    becomes watchable). See Aviary.WatchProgress.
                  --%>
                  <p
                    :if={
                      label =
                        Aviary.WatchProgress.label(
                          show_state(@show, @sonarr_status),
                          @show.runtime_minutes,
                          show_timeleft_seconds(@show, @sonarr_status)
                        )
                    }
                    class="font-display italic text-muted text-xs"
                  >
                    {label}
                  </p>
                </div>

                <%!--
                  Per-user library curation, only meaningful for shows
                  Jellyfin already has files for. The Remove button
                  uses data-confirm for the small-but-real chance of
                  an accidental click; the Add path is non-destructive
                  so it just fires. Both are no-ops on Jellyfin and
                  Sonarr — files stay, and re-adds are instant because
                  there's no download step.
                --%>
                <%!--
                  Outlined-pill treatment so it actually reads as a
                  click target — earlier it was bare uppercase text
                  with an underline-on-hover and didn't look
                  interactive. Same scale + structure as the back
                  button (border + uppercase tracking) but smaller
                  padding so it doesn't compete with the page's
                  primary CTAs. Add and Remove share the rest pose
                  (neutral ink outline) and only diverge on hover:
                  Add brightens toward oxblood (engagement, the
                  invited direction), Remove brightens to ink
                  (neutral — destructive but not alarming).
                --%>
                <div :if={@show.source == :library and @show.tmdb_id} class="mt-1">
                  <button
                    :if={@in_library}
                    type="button"
                    phx-click="remove_from_library"
                    data-confirm={"Remove #{@show.title} from your library?"}
                    class="w-fit font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium px-3 py-1.5 rounded-sm border border-ink/30 text-ink/80 hover:border-ink hover:text-ink hover:bg-ink/5 cursor-pointer transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink/30 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    Remove from library
                  </button>
                  <button
                    :if={not @in_library}
                    type="button"
                    phx-click="add_to_library"
                    class="w-fit font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium px-3 py-1.5 rounded-sm border border-ink/30 text-ink/80 hover:border-oxblood hover:text-oxblood hover:bg-oxblood/5 cursor-pointer transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    Add to library
                  </button>
                </div>
              </div>

              <%!--
                Upper-right slot: release calendar takes priority over
                trailer for in-rotation shows ("we're invested, the
                trailer is no longer interesting"). Falls back to
                trailer when no schedule is known — ended shows,
                between-seasons-with-no-premiere-announced, or any
                Jellyseerr lookup failure.
              --%>
              <%!--
                Calendar only renders for library shows with a known
                next-episode air date. Discover shows always get the
                trailer instead — the calendar's framing ("when's the
                next episode I can play") only makes sense once the
                show is downloaded. For library shows without a
                schedule (ended, between seasons, no Jellyseerr data),
                fall through to trailer too.
              --%>
              <div
                :if={@show.source == :library and @show.schedule != :none}
                class="w-full"
              >
                <ReleaseCalendar.widget schedule={@show.schedule} />
              </div>

              <div
                :if={
                  (@show.source == :discover or
                     (@show.source == :library and @show.schedule == :none)) and
                    trailer_embeddable?(@show.trailer_url)
                }
                class="aspect-video w-full bg-rule rounded-sm overflow-hidden"
              >
                <iframe
                  src={trailer_embed_url(@show.trailer_url)}
                  class="w-full h-full"
                  allow="encrypted-media; picture-in-picture; fullscreen"
                  allowfullscreen
                  loading="lazy"
                  title={"#{@show.title} trailer"}
                >
                </iframe>
              </div>
            </div>

            <p
              :if={@show.synopsis && @show.synopsis != ""}
              class="font-display text-ink/85 text-base md:text-lg leading-relaxed pt-1"
              style="font-variation-settings: 'opsz' 14;"
            >
              {@show.synopsis}
            </p>
          </div>
        </div>

        <%!--
          Episodes list. Grouped by season, headers in small-caps,
          rows are minimal: episode number, title, runtime. Click a
          row → opens the player for that episode.
        --%>
        <section :if={has_episodes?(@show)} class="mt-12 md:mt-14">
          <div :for={{season, episodes} <- @show.episodes_by_season} class="mb-10 last:mb-0">
            <%!--
              Season header doubles as a collapse toggle and carries
              its own Play affordance — the intermediate scope between
              "play this episode" and "watch the whole show." When
              collapsed, the header still shows the marginalia ribbon
              so the user can see at a glance which seasons sit before
              their watch point.
            --%>
            <%!--
              Marginalia ribbon (border-l-2 + offset) only renders when
              the show is in THIS user's library — it visualizes how
              far they've watched, and watch state is per-user-library
              (removing the show from a user's library nukes their
              watch state). Note this gates on @in_library, NOT on
              @show.source: a show can sit on the Jellyfin server
              (source: :library) without any given user having added
              it, and in that case there's no per-user watch state to
              show even though the show metadata is available.
            --%>
            <div class={[
              "flex items-baseline justify-between mb-3 transition-colors duration-200",
              @in_library && "border-l-2 pl-2 -ml-2",
              @in_library &&
                if(MapSet.member?(@collapsed_seasons, season),
                  do: season_marginalia_border(episodes, @mark),
                  else: "border-l-transparent"
                )
            ]}>
              <button
                type="button"
                phx-click="toggle_season"
                phx-value-season={season}
                aria-expanded={!MapSet.member?(@collapsed_seasons, season)}
                class="group flex items-baseline gap-2 cursor-pointer focus:outline-none focus-visible:underline"
              >
                <span class="font-sans text-muted/60 group-hover:text-muted transition-colors text-[0.65rem] w-3 inline-block leading-none">
                  {if MapSet.member?(@collapsed_seasons, season), do: "▸", else: "▾"}
                </span>
                <span class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted">
                  Season {season}
                </span>
                <span
                  :if={MapSet.member?(@collapsed_seasons, season)}
                  class="font-display italic text-muted/70 text-sm"
                  style="font-variation-settings: 'opsz' 14;"
                >
                  · {length(episodes)} {if length(episodes) == 1, do: "episode", else: "episodes"}
                </span>
              </button>
            </div>
            <ul :if={!MapSet.member?(@collapsed_seasons, season)} class="border-t border-rule">
              <%!--
                When the show is in THIS user's library, each row has
                two click targets and a marginalia bar:
                  * Marker column (32px, leftmost) fires set_watch_point
                  * Play row (rest) fires play_episode
                The left border is the marginalia bar — oxblood/40 for
                rows before AND at the mark (forms a continuous ribbon),
                full oxblood on the at-mark row, transparent for rows
                after the mark. Editorial-bookmark vocabulary.

                Out-of-library shows skip both: nothing to set a watch
                point against (no library record means no per-user
                watch state — and we nuke watch state on library
                removal, so it's intrinsically tied to membership),
                and no ribbon to draw progress against. The row
                collapses to just the play button at full width —
                cleaner and saves the 32px gutter on mobile.

                Critical: this gates on @in_library (per-user library
                membership), NOT @show.source. A show with
                source: :library can still be out of this user's
                personal library if they haven't added it — that's
                what's been confused before.
              --%>
              <li
                :for={ep <- episodes}
                class={[
                  "border-b border-rule transition-colors duration-200",
                  # minmax(0, 1fr) — not bare 1fr — so the column track
                  # can SHRINK below its content's intrinsic width. A
                  # plain `1fr` track has default min-width:auto, which
                  # means a long episode title inside the play button
                  # inflates the column past 1fr and pushes the
                  # action_chip off the right edge of the viewport on
                  # mobile. Same flex-min-w-0 trick, at the grid level.
                  @in_library && "grid grid-cols-[32px_minmax(0,1fr)] border-l-2",
                  @in_library &&
                    case row_position(ep, @mark) do
                      :at -> "border-l-oxblood"
                      :before -> "border-l-oxblood/40"
                      :after -> "border-l-transparent"
                    end,
                  !ep.aired && "opacity-50"
                ]}
              >
                <%!--
                  Marker column. Empty by default; ghost ✓ on hover
                  invites the click without persistent noise. The
                  at-mark row shows ✓ or ~ depending on kind.
                  Disabled for not-yet-aired episodes (you can't mark
                  what hasn't dropped).
                --%>
                <button
                  :if={@in_library}
                  type="button"
                  phx-click="set_watch_point"
                  phx-value-id={ep.id}
                  disabled={!ep.aired}
                  aria-label={"Mark E#{ep.episode} as the watch point"}
                  class="group flex items-center justify-center cursor-pointer focus:outline-none focus-visible:bg-rule/50 transition-colors duration-150 disabled:cursor-default"
                >
                  <%= cond do %>
                    <% @mark && @mark.episode_id == ep.id && @mark.kind == :watched -> %>
                      <span class="font-sans font-bold text-oxblood text-sm leading-none">
                        ✓
                      </span>
                    <% @mark && @mark.episode_id == ep.id && @mark.kind == :in_progress -> %>
                      <%!--
                        Tilde-to-check on hover: the persistent ~ fades
                        out and a ghost ✓ fades in (same 30% ghost
                        opacity other rows use). Click → mark_played
                        sets PlayedPercentage=100 and clears the resume
                        position, so the mark recomputes as ✓ next
                        render.
                      --%>
                      <span class="relative inline-flex items-center justify-center">
                        <span
                          class="font-display italic text-oxblood text-base leading-none -mt-0.5 transition-opacity duration-150 group-hover:opacity-0"
                          style="font-variation-settings: 'opsz' 14;"
                        >
                          ~
                        </span>
                        <span class="absolute inset-0 flex items-center justify-center font-sans font-bold text-oxblood/0 group-hover:text-oxblood/30 transition-colors duration-150 text-sm leading-none">
                          ✓
                        </span>
                      </span>
                    <% ep.aired -> %>
                      <%!-- Ghost on hover — invites the click. --%>
                      <span class="font-sans font-bold text-oxblood/0 group-hover:text-oxblood/30 transition-opacity duration-150 text-sm leading-none">
                        ✓
                      </span>
                    <% true -> %>
                      <%!-- Not-yet-aired row, no affordance --%>
                  <% end %>
                </button>

                <%!--
                  Play row — clickable for aired episodes, info-only
                  for unaired. Same geometry across both so the list
                  stays as one continuous sequence.
                --%>
                <button
                  :if={ep.aired}
                  type="button"
                  phx-click="play_episode"
                  phx-value-id={ep.id}
                  class="group w-full flex items-center gap-4 py-3 px-1 cursor-pointer text-left"
                >
                  <span class="font-sans text-muted text-sm tabular-nums w-8 shrink-0">
                    {pad_episode(ep.episode)}
                  </span>
                  <%!--
                    min-w-0 is the standard flexbox truncate fix: flex
                    items default to min-width:auto (won't shrink below
                    intrinsic content width), which means a long title
                    pushes the chip off the row instead of clipping.
                    min-w-0 lets the title shrink to whatever space the
                    siblings leave and the truncate utility then adds
                    the ellipsis.
                  --%>
                  <span class="font-display text-ink flex-1 min-w-0 truncate">{ep.title}</span>
                  <span
                    :if={ep.runtime_minutes}
                    class="font-sans text-muted text-xs tabular-nums shrink-0"
                  >
                    {ep.runtime_minutes}m
                  </span>
                  <.action_chip state={episode_state(@show, ep, @sonarr_status)} label="▶ Play" />
                </button>

                <div
                  :if={!ep.aired}
                  class="w-full flex items-center gap-4 py-3 px-1"
                >
                  <span class="font-sans text-muted text-sm tabular-nums w-8 shrink-0">
                    {pad_episode(ep.episode)}
                  </span>
                  <span class="font-display text-ink flex-1 min-w-0 truncate">{ep.title}</span>
                  <span
                    :if={ep.air_date}
                    class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted shrink-0"
                  >
                    {air_date_label(ep.air_date)}
                  </span>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </article>

      <VideoPlayer.overlay
        :if={@playing_item}
        item={@playing_item}
        current_user={@current_user}
        title={@show.title}
        segments={@playing_segments}
        subtitles={@playing_subtitles}
        audio_stream_index={@playing_audio_index}
      />
    </Layouts.app>
    """
  end

  ## Helpers

  # "Drama · 5 seasons · TV-MA · 2018 – 2023" — drops parts that aren't
  # present so a show missing genre or rating doesn't get dangling
  # bullets.
  defp metadata_line(show) do
    [
      show.genre,
      seasons_text(show.season_count),
      show.official_rating,
      year_range(show.year)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp seasons_text(nil), do: nil
  defp seasons_text(0), do: nil
  defp seasons_text(1), do: "1 season"
  defp seasons_text(n), do: "#{n} seasons"

  defp year_range({start, nil}) when is_integer(start), do: "#{start} – present"
  defp year_range({start, finish}) when is_integer(start) and is_integer(finish), do: "#{start} – #{finish}"
  defp year_range(_), do: nil

  defp has_episodes?(show) do
    show.episodes_by_season != []
  end

  # Morphing label. Discover (not-in-library) shows always read
  # "Watch S1 E1" — the eventual flow is "click → kick Sonarr to
  # download → playback when ready," and the button stays disabled
  # for now until that's wired (per agreed scope).
  #
  # After discover, caught-up first because it short-circuits the
  # "no resume position" path that would otherwise read as
  # "Continue S X E Y" — confusing for an episode the user already
  # finished. The button is disabled in this state via
  # caught_up?/1; the calendar widget on the same page tells them
  # when the next episode airs.
  defp action_label(%{source: :discover}), do: "Add to library"

  # Library show whose next_up is a TMDB-only episode (not yet
  # downloaded — could be unaired or aired-but-missing). Two flavors:
  # unaired carries an air date and reads as a waiting state; aired-
  # but-missing reads as a Watch trigger.
  defp action_label(%{next_up: %{id: "tmdb-" <> _, season: s, episode: e, aired: false, air_date: %Date{} = date}}) do
    "S#{s} E#{e} " <> waiting_phrase(date)
  end

  defp action_label(%{next_up: %{id: "tmdb-" <> _, season: s, episode: e}}) do
    "Watch S#{s} E#{e}"
  end
  #
  # When we know the next episode's air date (Jellyseerr returned a
  # schedule), surface it on the button itself so the user sees
  # "S1 E6 later today" rather than the generic "Caught up". When we
  # don't have a schedule (show ended, plugin miss, etc.), fall
  # through to "Caught up".
  defp action_label(%{
         next_up: %{caught_up: true},
         schedule: %{air_date: %Date{} = date, season: s, episode: e}
       }) do
    "S#{s} E#{e} " <> waiting_phrase(date)
  end

  defp action_label(%{next_up: %{caught_up: true}}), do: "Caught up"

  defp action_label(%{next_up: nil} = show), do: first_episode_label(show)

  defp action_label(%{next_up: %{resume_seconds: r, season: s, episode: e}})
       when is_number(r) and r > 0 and not is_nil(s) and not is_nil(e) do
    "Resume S#{s} E#{e}"
  end

  defp action_label(%{next_up: %{season: s, episode: e}} = show)
       when not is_nil(s) and not is_nil(e) do
    case first_episode(show) do
      %{season: ^s, episode: ^e} -> first_episode_label(show)
      _ -> "Continue S#{s} E#{e}"
    end
  end

  # Jellyfin sometimes returns a next_up episode mid-import where
  # ParentIndexNumber/IndexNumber haven't populated yet — without
  # this guard the label renders as "Continue S E" with empty
  # numbers. Fall back to the first-episode label until metadata
  # catches up.
  defp action_label(%{next_up: %{}} = show), do: first_episode_label(show)

  defp caught_up?(%{next_up: %{caught_up: true}}), do: true
  defp caught_up?(_), do: false

  # Button is inert when:
  #   - the show has no episodes at all (rare; would need a Jellyseerr
  #     miss for a discover show)
  #   - the next-up episode hasn't aired yet (you can't Watch what
  #     hasn't dropped)
  #   - the user is genuinely caught up — no future episode known
  # Discover shows are NOT disabled even when caught_up never fired —
  # clicking them triggers Sonarr at the show scope.
  defp action_disabled?(%{source: :discover}), do: false
  defp action_disabled?(%{next_up: %{aired: false}}), do: true
  defp action_disabled?(show), do: not has_episodes?(show) or caught_up?(show)

  # Short, tiered phrase for the caught-up button: "later today" /
  # "tomorrow" / day-name / "next [day]" / month-day. Mirrors the
  # calendar caption's tiers but terser since this lives on a button.
  defp waiting_phrase(air_date) do
    today = Aviary.LocalTime.today()
    days = Date.diff(air_date, today)

    cond do
      days == 0 -> "later today"
      days == 1 -> "tomorrow"
      days in 2..6 -> "this " <> Calendar.strftime(air_date, "%A")
      days in 7..13 -> "next " <> Calendar.strftime(air_date, "%A")
      true -> Calendar.strftime(air_date, "%B %-d")
    end
  end

  # Uses the actual first episode's season/episode rather than
  # hardcoding "S1 E1" — libraries don't always start at season 1
  # (specials, partial libraries, late seasons only, etc.).
  defp first_episode_label(show) do
    case first_episode(show) do
      %{season: s, episode: e} -> "Play S#{s} E#{e}"
      _ -> "Play"
    end
  end

  # When NextUp returns nothing (never watched OR fully watched), play
  # the very first episode. If there's nothing at all, the button is
  # disabled so this never gets called.
  defp start_playing(socket, item) do
    user = socket.assigns.current_user
    show = socket.assigns.show

    # Any play action is a commitment signal — the show enters the
    # user's library. Idempotent at the DB layer; doesn't re-add if
    # already present. nil tmdb_id (rare: Jellyfin item without
    # ProviderIds.Tmdb) just skips the library write rather than
    # erroring.
    if show.tmdb_id, do: Aviary.Library.add(user.id, show.tmdb_id)

    # Lock the audio track up front so Jellyfin doesn't pick an
    # audio-description stream as the default. See
    # Jellyfin.default_audio_index/1 for the heuristic.
    audio_streams = Aviary.Jellyfin.audio_streams(item.id, user)
    audio_index = Aviary.Jellyfin.default_audio_index(audio_streams)

    socket
    |> assign(:playing_item, item)
    |> assign(:playing_segments, Aviary.Jellyfin.segments(item.id, user))
    |> assign(:playing_subtitles, Aviary.Jellyfin.subtitle_streams(item.id, user))
    |> assign(:playing_audio_index, audio_index)
  end

  defp pick_continue_episode(show) do
    case show.next_up do
      nil -> first_episode(show)
      ep -> ep
    end
  end

  defp first_episode(show) do
    case show.episodes_by_season do
      [{_, [first | _]} | _] -> first
      _ -> nil
    end
  end

  defp find_episode(show, episode_id) do
    show.episodes_by_season
    |> Enum.flat_map(fn {_, eps} -> eps end)
    |> Enum.find(&(&1.id == episode_id))
  end

  # Mirror Catalog.@done_threshold — when the just-closed episode is
  # past this fraction, we advance the live next_up to the following
  # episode rather than leaving the button pointed at the credits.
  @done_fraction 0.90

  defp update_episode_progress(show, episode_id, position) do
    updated_episodes_by_season =
      Enum.map(show.episodes_by_season, fn {season, eps} ->
        {season,
         Enum.map(eps, fn ep ->
           if ep.id == episode_id, do: Map.put(ep, :resume_seconds, position), else: ep
         end)}
      end)

    flat = Enum.flat_map(updated_episodes_by_season, fn {_, eps} -> eps end)
    closed_ep = Enum.find(flat, &(&1.id == episode_id))

    # When the user closes a basically-done episode, advance to the
    # next one so the action_label reflects "Continue S1 E6" rather
    # than "Resume S1 E5" pointing at the credits they just closed.
    # When mid-watch (< 90%), keep next_up on the just-closed episode
    # for a resume target.
    next_up =
      cond do
        closed_ep && basically_done?(closed_ep, position) ->
          next_after_in(flat, episode_id) || closed_ep

        closed_ep ->
          closed_ep

        true ->
          show.next_up
      end

    show
    |> Map.put(:episodes_by_season, updated_episodes_by_season)
    |> Map.put(:next_up, next_up)
  end

  defp basically_done?(%{runtime_minutes: m}, position)
       when is_integer(m) and m > 0 and is_number(position) do
    position / (m * 60) >= @done_fraction
  end

  defp basically_done?(_, _), do: false

  defp next_after_in(flat, id) do
    flat
    |> Enum.drop_while(&(&1.id != id))
    |> case do
      [_current, next | _] -> next
      _ -> nil
    end
  end

  defp pad_episode(nil), do: ""
  defp pad_episode(n), do: "E" <> String.pad_leading(to_string(n), 2, "0")

  # Dispatch a Sonarr intent (show / season / episode). Commits the
  # library entry first so the user can navigate away mid-download
  # and find the show back where it should be when they return.
  # Stage 5 will replace these flashes with per-button download
  # progress on the same page.
  defp trigger_sonarr(socket, scope, season, episode) do
    user = socket.assigns.current_user
    show = socket.assigns.show

    Aviary.Library.add(user.id, show.tmdb_id)

    {result, flash_text} =
      case scope do
        :show ->
          {Aviary.Sonarr.watch_show(show.tmdb_id), "Adding #{show.title} to your library…"}

        :episode ->
          # Two-stage download: this single episode now, then once
          # the file lands SeriesFollowup broadens to the rest of the
          # series. Lets the targeted episode get the entire download
          # pipe without making the user click again for the rest.
          # See Aviary.SeriesFollowup for the polling/timeout shape.
          result = Aviary.Sonarr.watch_episode(show.tmdb_id, season, episode)
          Aviary.SeriesFollowup.after_episode_imports(show.tmdb_id, season, episode)
          {result, "Grabbing S#{season} E#{episode} of #{show.title}…"}
      end

    case result do
      {:ok, _} ->
        # Re-fetch immediately so the button reflects the new state on
        # the same tick the user clicked — without waiting up to 5s
        # for the next poll. The periodic poll keeps it fresh after.
        {:noreply,
         socket
         |> fetch_sonarr_status()
         |> put_flash(:info, flash_text)}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Couldn't reach Sonarr. Try again in a moment.")}
    end
  end

  defp in_progress?(:searching), do: true
  defp in_progress?({:downloading, _}), do: true
  defp in_progress?(:imported), do: true
  # Sonarr's stuck on this one (importBlocked or import warning) —
  # clicking shouldn't fire a fresh grab; the user has to resolve the
  # block in Sonarr's UI before anything moves.
  defp in_progress?(:stuck), do: true
  defp in_progress?(_), do: false

  # The single "watch mark" for a show: which episode carries the
  # user's bookmark, and whether they finished it (✓) or are mid-watch
  # (~). Computed from per-episode Jellyfin UserData; returns nil for
  # shows the user hasn't touched.
  #
  # "Most recent activity" is the wins condition — if the user has
  # E3 mid-watch and E5 marked played, the mark sits on E5 (most
  # recent). The mark moves naturally as the user watches.
  defp watch_mark(show) do
    most_recent =
      show.episodes_by_season
      |> Enum.flat_map(fn {_, eps} -> eps end)
      |> Enum.filter(& &1.last_played_at)
      |> Enum.max_by(& &1.last_played_at, DateTime, fn -> nil end)

    case most_recent do
      %{resume_seconds: r, season: s, episode: e, id: id} when is_number(r) and r > 0 ->
        %{episode_id: id, season: s, episode: e, kind: :in_progress}

      %{played_percentage: p, season: s, episode: e, id: id} when is_number(p) and p >= 90 ->
        %{episode_id: id, season: s, episode: e, kind: :watched}

      _ ->
        nil
    end
  end

  # Mirrors what Jellyfin will look like once the background writes
  # settle: every episode 1..idx gets played_percentage=100, resume
  # cleared, and a fresh last_played_at; every episode idx+1..end
  # gets played_percentage=0, last_played_at cleared. Timestamps
  # ascend with index so the *clicked* episode wins max_by — that's
  # what makes the mark land on it instead of E1.
  defp apply_optimistic_watch_point(show, flat, idx) do
    now = DateTime.utc_now()

    marked =
      flat
      |> Enum.with_index()
      |> Enum.take(idx + 1)
      |> Map.new(fn {ep, i} -> {ep.id, DateTime.add(now, i, :microsecond)} end)

    unmarked = MapSet.new(Enum.drop(flat, idx + 1), & &1.id)

    updated =
      Enum.map(show.episodes_by_season, fn {season, eps} ->
        {season,
         Enum.map(eps, fn ep ->
           cond do
             ts = Map.get(marked, ep.id) ->
               %{ep | played_percentage: 100.0, resume_seconds: nil, last_played_at: ts}

             MapSet.member?(unmarked, ep.id) ->
               %{ep | played_percentage: 0.0, resume_seconds: nil, last_played_at: nil}

             true ->
               ep
           end
         end)}
      end)

    %{show | episodes_by_season: updated}
  end

  # Default collapse rule: a show with a mark in S9 doesn't want to
  # make the user scroll past S1-S8. Collapse every season strictly
  # before the mark-season; mark-season and anything later stay
  # expanded. No mark → expand everything (the user has nothing they
  # need to be "past").
  defp initial_collapsed_seasons(show) do
    case watch_mark(show) do
      %{season: mark_season} ->
        show.episodes_by_season
        |> Enum.map(fn {s, _} -> s end)
        |> Enum.filter(&(&1 < mark_season))
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # Marginalia bar for a collapsed season header — preserves the
  # ribbon continuity when the user has hidden a stretch of watched
  # episodes. Looks at every episode in the season and picks the
  # strongest position present.
  defp season_marginalia_border(_eps, nil), do: "border-l-transparent"

  defp season_marginalia_border(eps, mark) do
    positions = Enum.map(eps, &row_position(&1, mark))

    cond do
      :at in positions -> "border-l-oxblood"
      Enum.all?(positions, &(&1 == :before)) -> "border-l-oxblood/40"
      true -> "border-l-transparent"
    end
  end

  # Where a given episode sits relative to the show's mark. Drives the
  # marginalia-bar color: before / at = ribbon visible, after = not.
  defp row_position(_ep, nil), do: :after

  defp row_position(ep, %{episode_id: mark_id, season: ms, episode: me}) do
    cond do
      ep.id == mark_id -> :at
      {ep.season, ep.episode} < {ms, me} -> :before
      true -> :after
    end
  end

  ## Sonarr-derived state for each button tier

  # Resolves a single episode to one of:
  #   :playable  — the file is in the library; click plays it
  #   {:downloading, pct} — actively downloading; chip shows progress
  #   :queued    — sonarr has searched/queued but no bytes yet
  #   :ready     — neither in library nor in queue; click triggers Sonarr
  #
  # An episode short-circuits to :playable only if THIS episode has a
  # real Jellyfin id — `tmdb-…` ids in `episodes_by_season` are filled
  # in by `Catalog.augment_with_tmdb` for episodes Jellyfin doesn't
  # have yet, and those need to fall through to the Sonarr status
  # path so the chip can show searching/downloading/queued progress.
  # The old short-circuit on `%{source: :library}` alone made every
  # episode of a library show render as :playable even while E2-E7
  # were mid-download.
  def episode_state(_show, %{id: "tmdb-" <> _, season: s, episode: e}, status) do
    sonarr_episode_state(s, e, status)
  end

  # Library episode (real Jellyfin id). Default is :playable, but if a
  # user-initiated re-grab is currently in Sonarr's queue for this
  # episode (Interactive Search → Add to download queue), surface the
  # download progress so the page reflects the in-flight work. The
  # episode row stays a button so the existing file is still
  # play-clickable while the re-grab runs.
  def episode_state(_show, %{id: id, season: s, episode: e}, status) when is_binary(id) do
    case library_episode_active_download(s, e, status) do
      nil -> :playable
      progress -> progress
    end
  end

  def episode_state(_show, %{season: s, episode: e}, status) do
    sonarr_episode_state(s, e, status)
  end

  defp library_episode_active_download(_s, _e, nil), do: nil

  defp library_episode_active_download(s, e, status) do
    case Map.get(status.episodes, {s, e}) do
      %{id: sonarr_episode_id} ->
        case download_progress(status.queue, sonarr_episode_id) do
          {:ok, pct} -> {:downloading, pct}
          :imported -> :imported
          :stuck -> :stuck
          :in_queue_no_bytes -> {:downloading, 0}
          :not_in_queue -> nil
        end

      _ ->
        nil
    end
  end

  defp sonarr_episode_state(_s, _e, nil), do: :ready

  defp sonarr_episode_state(s, e, status) do
    case Map.get(status.episodes, {s, e}) do
      # Sonarr says it has the file, but if we reached this branch
      # the calling clause has already established the episode is
      # tmdb-prefixed in our view — meaning Jellyfin hasn't scanned
      # the new file yet. That's `:imported`, not `:playable`: the
      # chip should say "Importing…" and clicks should no-op rather
      # than firing another grab. The poll loop re-fetches the show
      # when any episode is in this state so the transition to
      # :playable happens automatically once Jellyfin catches up.
      %{has_file: true} ->
        :imported

      # Three sub-states once Sonarr is monitoring the episode:
      #   - in queue with progress  → :downloading {pct}%
      #   - in queue, no bytes yet  → :downloading 0%
      #   - monitored, NOT in queue → :searching (Sonarr is still
      #     looking for / waiting on a release)
      # Splitting :searching from :downloading kills the confusing
      # "Queued" label the user saw on episodes that weren't actually
      # in qBit's queue — those are conceptually "we're looking,"
      # not "in the download queue."
      %{id: episode_id, monitored: true} ->
        case download_progress(status.queue, episode_id) do
          {:ok, pct} -> {:downloading, pct}
          :imported -> :imported
          :stuck -> :stuck
          :in_queue_no_bytes -> {:downloading, 0}
          :not_in_queue -> :searching
        end

      _ ->
        :ready
    end
  end

  # Show-level state mirrors the episode you'd start watching from the
  # top button. For library shows that's always playable (file's
  # there); for discover shows it's the first episode of the first
  # season.
  def show_state(%{source: :library}, _status), do: :playable

  def show_state(show, status) do
    case show.episodes_by_season do
      [{_, [first | _]} | _] -> episode_state(show, first, status)
      _ -> :ready
    end
  end

  # Reach into Sonarr's queue for the first-episode-of-first-season's
  # `timeleft` field, parse it to seconds. That episode is what
  # `show_state/2` keys off of — the user can start watching as soon
  # as it lands. Returns nil if there's no queue record yet (e.g.,
  # Sonarr is still searching) so the label gracefully omits.
  defp show_timeleft_seconds(show, status)
       when not is_nil(status) and is_list(status.queue) do
    with [{_, [first | _]} | _] <- show.episodes_by_season,
         %{id: sonarr_episode_id} <- Map.get(status.episodes, {first.season, first.episode}, %{}),
         record when not is_nil(record) <-
           Enum.find(status.queue, &(&1["episodeId"] == sonarr_episode_id)) do
      Aviary.WatchProgress.parse_timeleft(record["timeleft"])
    else
      _ -> nil
    end
  end

  defp show_timeleft_seconds(_show, _status), do: nil

  # Looks up an episode's current queue record. Returns one of:
  #   {:ok, pct}           bytes actively transferring
  #   :imported            download finished, Sonarr is importing
  #                        (or import-blocked / import-pending) — the
  #                        queue record persists during this phase with
  #                        sizeleft=0, and the chip should say
  #                        "Importing…" rather than sticking at 100%
  #                        forever
  #   :in_queue_no_bytes   Sonarr knows about it but no bytes yet
  #   :not_in_queue        not in queue at all
  defp download_progress(queue, episode_id) do
    case Enum.find(queue, &(&1["episodeId"] == episode_id)) do
      nil ->
        :not_in_queue

      record ->
        queue_record_state(record)
    end
  end

  # Maps a raw Sonarr queue record to one of the states above. The
  # warning check must come first: a record can be `importPending`
  # with `trackedDownloadStatus: "warning"` and a non-empty
  # statusMessages list — Sonarr's signal for "I'm not going to
  # finish this import without your help" (e.g. "Not an upgrade for
  # existing episode file(s)"). Without distinguishing this from a
  # healthy `importPending`, the chip would sit on "Importing…"
  # forever even though nothing will resolve on its own.
  defp queue_record_state(%{
         "trackedDownloadStatus" => "warning",
         "statusMessages" => [_ | _]
       }),
       do: :stuck

  defp queue_record_state(%{"trackedDownloadState" => state})
       when state in ["importPending", "importing", "importBlocked", "imported"],
       do: :imported

  defp queue_record_state(%{"size" => size, "sizeleft" => 0})
       when is_number(size) and size > 0,
       do: :imported

  defp queue_record_state(%{"size" => size, "sizeleft" => left})
       when is_number(size) and is_number(left) and size > 0 and left > 0 do
    {:ok, round((size - left) / size * 100)}
  end

  defp queue_record_state(_), do: :in_queue_no_bytes

  # Short tiered air-date label for unaired-episode rows: stays
  # consistent with the show detail Play button's waiting_phrase
  # vocabulary so the user sees one language across the page.
  defp air_date_label(%Date{} = date) do
    today = Aviary.LocalTime.today()
    days = Date.diff(date, today)

    cond do
      days == 0 -> "Today"
      days == 1 -> "Tomorrow"
      days in 2..6 -> "This " <> Calendar.strftime(date, "%A")
      days in 7..13 -> "Next " <> Calendar.strftime(date, "%A")
      true -> Calendar.strftime(date, "%b %-d, %Y")
    end
  end

  defp air_date_label(_), do: nil

  ## Trailer helpers (duplicate of MoviesDetailLive — small enough to
  ## not justify a shared module yet)

  defp upper_right_present?(show) do
    cond do
      show.source == :library and show.schedule != :none -> true
      trailer_embeddable?(show.trailer_url) -> true
      true -> false
    end
  end

  defp trailer_embeddable?(nil), do: false
  defp trailer_embeddable?(url) when is_binary(url), do: youtube_id(url) != nil
  defp trailer_embeddable?(_), do: false

  defp trailer_embed_url(url) do
    case youtube_id(url) do
      nil -> nil
      id -> "https://www.youtube.com/embed/#{id}?modestbranding=1&rel=0"
    end
  end

  defp youtube_id(url) when is_binary(url) do
    case Regex.run(~r/(?:v=|\/embed\/|youtu\.be\/)([A-Za-z0-9_-]{11})/, url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp youtube_id(_), do: nil
end
