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
        socket =
          socket
          |> assign(
            page_title: "#{show.title} · Aviary",
            show: show,
            playing_item: nil,
            playing_segments: nil,
            playing_subtitles: [],
            kicker: kicker(params["from"]),
            sonarr_status: nil
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
     |> schedule_sonarr_poll()}
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

  defp kicker("home"), do: %{label: "Home", path: "/home"}
  defp kicker("discover"), do: %{label: "Discover", path: "/discover"}
  defp kicker("library_movies"), do: %{label: "Library", path: "/library?type=movies"}
  defp kicker(_), do: %{label: "Library", path: "/library?type=shows"}

  # Three handlers, one routing rule: an episode id with the `tmdb-`
  # prefix means "not in Jellyfin's library yet" and routes to
  # Sonarr; anything else is a Jellyfin id and routes to playback.
  # Works uniformly across discover shows (everything `tmdb-`) and
  # library shows (mix of Jellyfin ids and `tmdb-` ids for episodes
  # not yet downloaded).

  def handle_event("play", _, socket) do
    case pick_continue_episode(socket.assigns.show) do
      nil ->
        trigger_sonarr(socket, :show, nil, nil)

      %{id: "tmdb-" <> _} ->
        trigger_sonarr(socket, :show, nil, nil)

      ep ->
        {:noreply, start_playing(socket, ep)}
    end
  end

  def handle_event("watch_season", %{"season" => season_str}, socket) do
    season = String.to_integer(season_str)

    case first_episode_of_season(socket.assigns.show, season) do
      nil ->
        {:noreply, put_flash(socket, :error, "No episodes in this season.")}

      %{id: "tmdb-" <> _} ->
        trigger_sonarr(socket, :season, season, nil)

      ep ->
        {:noreply, start_playing(socket, ep)}
    end
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    case find_episode(socket.assigns.show, episode_id) do
      nil ->
        {:noreply, socket}

      %{id: "tmdb-" <> _} = ep ->
        trigger_sonarr(socket, :episode, ep.season, ep.episode)

      ep ->
        {:noreply, start_playing(socket, ep)}
    end
  end

  def handle_event("close_player", _, socket) do
    {:noreply,
     socket
     |> assign(:playing_item, nil)
     |> assign(:playing_segments, nil)
     |> assign(:playing_subtitles, [])}
  end

  def handle_event("report_progress", %{"position" => position}, socket) do
    item = socket.assigns.playing_item

    if item do
      position_ticks = trunc(position * 10_000_000)

      Aviary.Jellyfin.save_position(
        item.id,
        position_ticks,
        socket.assigns.current_user
      )

      # Mirror the in-memory resume_seconds on the corresponding episode
      # so the Continue button label stays accurate after closing.
      {:noreply, update(socket, :show, &update_episode_progress(&1, item.id, position))}
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

  defp action_chip(assigns) do
    ~H"""
    <%= case @state do %>
      <% {:downloading, pct} -> %>
        <span class="relative inline-block overflow-hidden font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium text-paper px-3 py-1.5 rounded-sm shrink-0 bg-oxblood/20 tabular-nums">
          <span
            class="absolute inset-y-0 left-0 bg-oxblood transition-all duration-700 ease-out"
            style={"width: #{pct}%"}
          >
          </span>
          <span class="relative">{pct}%</span>
        </span>
      <% :queued -> %>
        <span class="font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium bg-oxblood/40 text-paper/80 px-3 py-1.5 rounded-sm shrink-0">
          Queued
        </span>
      <% _ -> %>
        <span class="font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium bg-oxblood text-paper px-3 py-1.5 rounded-sm shrink-0 transition-opacity opacity-90 group-hover:opacity-100">
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
        <div class="relative overflow-hidden inline-block bg-oxblood/20 text-paper font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm tabular-nums">
          <span
            class="absolute inset-y-0 left-0 bg-oxblood transition-all duration-700 ease-out"
            style={"width: #{pct}%"}
          >
          </span>
          <span class="relative">{pct}%</span>
        </div>
      <% :queued -> %>
        <div class="inline-block bg-oxblood/40 text-paper/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Queued
        </div>
      <% _ -> %>
        <button
          type="button"
          phx-click="play"
          disabled={@disabled}
          class="bg-oxblood text-paper font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 disabled:opacity-40 disabled:cursor-not-allowed focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
        >
          {@label}
        </button>
    <% end %>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} nav_visibility={@nav_visibility}>
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

                <div>
                  <.top_action_button
                    show={@show}
                    status={@sonarr_status}
                    label={action_label(@show)}
                    disabled={action_disabled?(@show)}
                  />
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
              Season header gets its own Play affordance — the
              intermediate scope between "play this episode" and
              "watch the whole show." Same oxblood vocabulary as the
              top action button and per-episode chip so the three
              tiers visually belong to the same action family.
            --%>
            <div class="flex items-baseline justify-between mb-3">
              <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted">
                Season {season}
              </h2>
              <button
                type="button"
                phx-click="watch_season"
                phx-value-season={season}
                class="cursor-pointer"
              >
                <.action_chip state={season_state(@show, season, @sonarr_status)} label="▶ Play Season" />
              </button>
            </div>
            <ul class="border-t border-rule">
              <%!--
                Aired episodes get the clickable Play row. Not-aired
                episodes get a dimmed info row with the air date in
                place of the Play chip — same vocabulary, same
                geometry, so the user reads the list as one continuous
                sequence with the unaired ones flagged as future.
              --%>
              <li :for={ep <- episodes}>
                <button
                  :if={ep.aired}
                  type="button"
                  phx-click="play_episode"
                  phx-value-id={ep.id}
                  class="group w-full flex items-center gap-4 py-3 px-1 border-b border-rule cursor-pointer hover:bg-rule/30 transition-colors text-left"
                >
                  <span class="font-sans text-muted text-sm tabular-nums w-8 shrink-0">
                    {pad_episode(ep.episode)}
                  </span>
                  <span class="font-display text-ink flex-1 truncate">{ep.title}</span>
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
                  class="w-full flex items-center gap-4 py-3 px-1 border-b border-rule opacity-50"
                >
                  <span class="font-sans text-muted text-sm tabular-nums w-8 shrink-0">
                    {pad_episode(ep.episode)}
                  </span>
                  <span class="font-display text-ink flex-1 truncate">{ep.title}</span>
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
  defp action_label(%{source: :discover}), do: "Watch"

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
       when is_number(r) and r > 0 do
    "Resume S#{s} E#{e}"
  end

  defp action_label(%{next_up: %{season: s, episode: e}} = show) do
    case first_episode(show) do
      %{season: ^s, episode: ^e} -> first_episode_label(show)
      _ -> "Continue S#{s} E#{e}"
    end
  end

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
    today = Date.utc_today()
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

    socket
    |> assign(:playing_item, item)
    |> assign(:playing_segments, Aviary.Jellyfin.segments(item.id, user))
    |> assign(:playing_subtitles, Aviary.Jellyfin.subtitle_streams(item.id, user))
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

        :season ->
          {Aviary.Sonarr.watch_season(show.tmdb_id, season),
           "Grabbing Season #{season} of #{show.title}…"}

        :episode ->
          {Aviary.Sonarr.watch_episode(show.tmdb_id, season, episode),
           "Grabbing S#{season} E#{episode} of #{show.title}…"}
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

  defp first_episode_of_season(show, season) do
    case Enum.find(show.episodes_by_season, fn {s, _} -> s == season end) do
      {_, [first | _]} -> first
      _ -> nil
    end
  end

  ## Sonarr-derived state for each button tier

  # Resolves a single episode to one of:
  #   :playable  — the file is in the library; click plays it
  #   {:downloading, pct} — actively downloading; chip shows progress
  #   :queued    — sonarr has searched/queued but no bytes yet
  #   :ready     — neither in library nor in queue; click triggers Sonarr
  #
  # Library shows short-circuit to :playable for any episode in the
  # `episodes_by_season` list (presence there means Jellyfin has the
  # file). Discover shows route through the sonarr_status map.
  def episode_state(%{source: :library}, _ep, _status), do: :playable

  def episode_state(_show, _ep, nil), do: :ready

  def episode_state(_show, %{season: s, episode: e}, status) do
    case Map.get(status.episodes, {s, e}) do
      %{has_file: true} ->
        :playable

      # Monitored = Sonarr has accepted the intent. From the user's
      # perspective, "I clicked Watch" → the work has started; the
      # button should reflect that until bytes either start flowing
      # (transitions to :downloading) or the file lands
      # (transitions to :playable). Without this, the window between
      # add-to-Sonarr and search-finding-a-release looked indistin-
      # guishable from "nothing happened."
      %{id: episode_id, monitored: true} ->
        case download_progress(status.queue, episode_id) do
          {:ok, pct} -> {:downloading, pct}
          _ -> :queued
        end

      _ ->
        :ready
    end
  end

  # Season-level state mirrors that season's first episode — clicking
  # "Play Season 2" means "start playing S2 E1 (downloading it first
  # if needed)" so the button's appearance reflects S2 E1's exact
  # state.
  def season_state(show, season_number, status) do
    case first_episode_of_season(show, season_number) do
      nil -> :ready
      ep -> episode_state(show, ep, status)
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

  # Looks up an episode's current queue record. Returns:
  #   {:ok, pct} when bytes are being transferred
  #   :queued    when Sonarr knows about it but it's not yet downloading
  #   :ready     when not in queue at all
  defp download_progress(queue, episode_id) do
    case Enum.find(queue, &(&1["episodeId"] == episode_id)) do
      %{"size" => size, "sizeleft" => left}
      when is_number(size) and is_number(left) and size > 0 ->
        {:ok, round((size - left) / size * 100)}

      %{} ->
        :queued

      nil ->
        :ready
    end
  end

  # Short tiered air-date label for unaired-episode rows: stays
  # consistent with the show detail Play button's waiting_phrase
  # vocabulary so the user sees one language across the page.
  defp air_date_label(%Date{} = date) do
    today = Date.utc_today()
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
