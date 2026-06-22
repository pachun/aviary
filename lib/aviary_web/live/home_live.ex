defmodule AviaryWeb.HomeLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: "Home",
       items: Aviary.Home.continue_watching(user),
       upcoming: Aviary.Upcoming.releases(user),
       recommendations:
         Aviary.Recommendations.list_for_marquee(
           user,
           Aviary.Jellyfin.list_users(user)
         )
     )}
  end

  # Dismiss from Continue Watching = "mark this entirely unwatched."
  # Reset every episode's UserData (shows) or the movie's UserData,
  # so the show / movie drops off Continue Watching because there's
  # nothing to continue. `library_entries` is untouched — there's no
  # "remove from library" UI yet, and Continue Watching is gated on
  # watch state, not on library membership.
  def handle_event("dismiss", %{"id" => series_id, "kind" => "show"}, socket) do
    Aviary.Jellyfin.reset_series_progress(series_id, socket.assigns.current_user)
    {:noreply, refresh_continue_watching(socket)}
  end

  def handle_event("dismiss", %{"id" => id, "kind" => "movie"}, socket) do
    Aviary.Jellyfin.reset_item_progress(id, socket.assigns.current_user)
    {:noreply, refresh_continue_watching(socket)}
  end

  # Family Recommended dismiss — adds a per-item row to
  # dismissed_recommendations, then refreshes the section data so the
  # entry leaves the row immediately. Same shape as the CW dismiss
  # event but a different phx-click name so the marquee can route
  # them to different paths.
  def handle_event("dismiss_recommendation", %{"id" => tmdb_id, "kind" => kind}, socket)
      when kind in ["show", "movie"] do
    Aviary.Recommendations.dismiss(socket.assigns.current_user.id, tmdb_id, kind)
    {:noreply, refresh_continue_watching(socket)}
  end

  # After a dismiss the user's home state may have changed enough to
  # affect nav visibility (e.g., they just emptied Continue Watching
  # and Upcoming both — Home tab should disappear). Recompute both
  # the section data and the nav visibility so the masthead updates
  # without requiring a refresh.
  defp refresh_continue_watching(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:items, Aviary.Home.continue_watching(user))
    |> assign(:upcoming, Aviary.Upcoming.releases(user))
    |> assign(
      :recommendations,
      Aviary.Recommendations.list_for_marquee(user, Aviary.Jellyfin.list_users(user))
    )
    |> assign(:nav_visibility, Aviary.Nav.visibility(user))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="home"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <%!--
        Wrapper handles top padding + between-section spacing. pt-2
        matches Discover's `first:pt-2` so the first section header
        on either tab lands at the same y-coordinate — switching
        between Home and Discover should feel like only the section
        label changed, not like the page reflowed. space-y-12 applies
        via :not(:first-child), so a hidden first section doesn't
        leave a phantom gap.
      --%>
      <div class="pt-2 space-y-12">
        <%!--
          Continue Watching only renders when populated. Empty section
          with a "nothing in progress" message was noise; same pattern
          as Upcoming below — section presence itself is the signal.
        --%>
        <section :if={@items != []}>
          <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
            Continue Watching
          </h2>
          <Marquee.row items={@items} from="home" key="home:continue-watching" dismissible>
            <:empty></:empty>
          </Marquee.row>
        </section>

        <%!--
          Upcoming releases. Hidden entirely when nothing is dropping in
          the window — the section appearing/disappearing communicates
          "your week is empty / your week has drops" by its presence.
          Editorial list, not a grid: most users have 2–4 active shows
          so a 7×2 calendar would be mostly empty cells; the list
          contracts and expands with what's actually scheduled.
        --%>
        <section :if={@upcoming != []}>
        <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
          Upcoming
        </h2>
        <ul class="border-t border-rule">
          <li :for={r <- @upcoming}>
            <.link
              navigate={"/shows/#{r.series_id}?from=home"}
              class="grid grid-cols-[140px_1fr_auto] items-baseline gap-4 py-3 px-2 border-b border-rule hover:bg-rule/30 transition-colors"
            >
              <span class="font-sans uppercase tracking-[0.18em] text-[0.7rem] text-muted">
                {waiting_phrase(r.air_date)}
              </span>
              <span
                class="font-display text-ink text-lg leading-tight truncate"
                style="font-variation-settings: 'opsz' 14;"
              >
                {r.series_name}
              </span>
              <span class="font-sans uppercase tracking-[0.18em] text-[0.7rem] text-muted whitespace-nowrap">
                S{r.season} · E{r.episode}
                <%!--
                  Hidden below sm (phones in portrait, < 640px) because
                  the row is grid-cols-[140px_1fr_auto] and the "Premieres
                  in N days" left column plus this "New season" tag
                  squeezes the 1fr title column down to a single letter
                  truncation. Tag returns on tablet portrait and up
                  where there's room.
                --%>
                <span :if={r.kind == :new_season} class="hidden sm:inline text-oxblood ml-2">
                  New season
                </span>
              </span>
            </.link>
          </li>
        </ul>
        </section>

        <%!--
          Family Recommended — items household members have sent the
          user that they haven't watched yet, haven't dismissed, AND
          don't already have in their library (already-in-library
          recs are filtered out; see Aviary.Recommendations.list_for_marquee).
          Sender avatars stack in the bottom-right of each thumbnail.
          X on hover removes (per-item dismissal — doesn't bother
          them with re-recs of the same item from anyone).

          Placed AFTER Continue Watching + Upcoming because those
          are higher-priority signals (what the user is mid-watch,
          what's dropping for them this week) than a family member's
          suggestion.
        --%>
        <section :if={@recommendations != []}>
          <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
            Family Recommended
          </h2>
          <Marquee.row
            items={@recommendations}
            from="home"
            key="home:recommended"
            dismiss_event="dismiss_recommendation"
            dismissible
          >
            <:empty></:empty>
          </Marquee.row>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Mirrors the show detail button's tiered phrasing — same language
  # across pages so the user learns one vocabulary. Kept local rather
  # than extracting to a shared module yet: a third caller would be
  # the moment to consolidate.
  defp waiting_phrase(air_date) do
    today = Aviary.LocalTime.today()
    days = Date.diff(air_date, today)

    cond do
      days == 0 -> "Later today"
      days == 1 -> "Tomorrow"
      days in 2..6 -> "This " <> Calendar.strftime(air_date, "%A")
      days in 7..13 -> "Next " <> Calendar.strftime(air_date, "%A")
      true -> Calendar.strftime(air_date, "%B %-d")
    end
  end
end
