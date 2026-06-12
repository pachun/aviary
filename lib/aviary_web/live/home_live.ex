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

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="home" current_user={@current_user}>
      <section class="pt-4">
        <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
          Continue Watching
        </h2>
        <Marquee.row items={@items} from="home" key="home:continue-watching">
          <:empty>Nothing in progress — pick something from Shows or Movies to get started.</:empty>
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
      <section :if={@upcoming != []} class="mt-12">
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
      days in 2..7 -> Calendar.strftime(air_date, "%A")
      days in 8..14 -> "Next " <> Calendar.strftime(air_date, "%A")
      true -> Calendar.strftime(air_date, "%B %-d")
    end
  end
end
