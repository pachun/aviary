defmodule AviaryWeb.HomeLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       page_title: "Home · Aviary",
       items: Aviary.Home.continue_watching(user),
       upcoming: Aviary.Upcoming.releases(user)
     )}
  end

  # Dismiss from Continue Watching. Shows take the light path now:
  # delete the library_entry, watch history left alone. Sister-watched
  # / "remove from library" with full watch-state reset will be its
  # own deliberate action on the show detail page (separate from this
  # dismiss). Movies keep their old Jellyfin-reset path since they
  # don't go through library_entries yet — same UX as before for
  # them. The home item carries `tmdb_id` from `Home.normalize`, so
  # that's what we hand to `Library.remove`.
  def handle_event("dismiss", %{"id" => tmdb_id, "kind" => "show"}, socket) do
    Aviary.Library.remove(socket.assigns.current_user.id, tmdb_id)
    {:noreply, refresh_continue_watching(socket)}
  end

  def handle_event("dismiss", %{"id" => id, "kind" => "movie"}, socket) do
    Aviary.Jellyfin.reset_item_progress(id, socket.assigns.current_user)
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
                <span :if={r.kind == :new_season} class="text-oxblood ml-2">
                  New season
                </span>
              </span>
            </.link>
          </li>
        </ul>
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
    today = Date.utc_today()
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
