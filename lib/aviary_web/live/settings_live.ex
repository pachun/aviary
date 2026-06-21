defmodule AviaryWeb.SettingsLive do
  @moduledoc """
  Account + display preferences + household storage breakdown for the
  signed-in user. The masthead's gear icon links here.

  Layout: two columns at lg+. Left column holds the user-facing
  preference sections (YOU, DISPLAY); right column shows the
  household-shared STORAGE panel — a stats table + a stacked bar
  colored per-user + a legend. Stacks vertically on smaller screens.

  Per-user colors come from a 6-slot palette (--user-1 through
  --user-6 in app.css), assigned deterministically by hashing the
  user_id. Same user gets the same color across sessions and
  refreshes.
  """
  use AviaryWeb, :live_view

  alias Aviary.Storage

  @palette_size 6

  def mount(_params, _session, socket) do
    current = socket.assigns.current_user
    %{per_user: breakdown, aggregate: totals, tank_bytes: tank_bytes} = Storage.stats(current)

    # The current user's slice — pulled out so the "Your usage" table
    # doesn't have to scan the list at render time. Falls back to a
    # zero struct if for any reason the current user isn't in the
    # breakdown (shouldn't happen — Jellyfin's user list is the
    # source — but defensive).
    your_stats =
      Enum.find(breakdown, &(&1.user_id == current.id)) ||
        %{
          movie_count: 0,
          show_count: 0,
          episode_count: 0,
          bytes: 0,
          bytes_movies: 0,
          bytes_shows: 0
        }

    {:ok,
     assign(socket,
       page_title: "Settings",
       breakdown: breakdown,
       totals: totals,
       your_stats: your_stats,
       tank_bytes: tank_bytes
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="settings"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
      mobile_title="Settings"
    >
      <%!--
        Page header: eyebrow + serif display title. Same rhythm the
        other section pages use (Discover, Library) so this lands as
        "an aviary page" before it lands as "the settings page."
      --%>
      <%!--
        Visible on every viewport — the body title is the page's
        primary anchor. Mobile keeps it smaller. The sticky top
        bar in Layouts.app fades in only after this h1 scrolls out
        of view (via the `data-mobile-top-bar-trigger` IntersectionObserver).
      --%>
      <header class="pt-4 sm:pt-6 pb-8 sm:pb-16">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-3">
          Account &amp; preferences
        </p>
        <h1
          data-mobile-top-bar-trigger
          class="font-display text-4xl sm:text-6xl text-ink"
        >
          Settings
        </h1>
      </header>

      <%!--
        Page-level two-column grid. lg+ shows preferences on the left
        and the household storage panel on the right (1fr/1fr); mobile
        stacks them. gap-12 mirrors the breathing room used between
        section blocks elsewhere.
      --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-y-2 lg:gap-x-16">
        <div>
          <.section_block label="You">
            <div class="flex flex-col gap-8">
              <div>
                <%!--
                  Inner "Signed in as" label hidden on mobile —
                  on mobile the section header "YOU" stacks ABOVE
                  it (one-column layout) and the two same-style
                  tracked-uppercase labels read as duplicates.
                  Desktop keeps it because the section header sits
                  to the LEFT, and the inner label provides a
                  useful sub-heading next to the username.
                --%>
                <p class="hidden sm:block font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-1">
                  Signed in as
                </p>
                <p class="font-display text-2xl text-ink">{@current_user.username}</p>
              </div>

              <.form for={%{}} action={~p"/logout"} method="post">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <input type="hidden" name="_method" value="delete" />
                <button
                  type="submit"
                  class="self-start font-sans text-[0.72rem] tracking-[0.18em] uppercase text-ink hover:text-oxblood underline decoration-1 underline-offset-[6px] decoration-rule hover:decoration-oxblood transition-colors duration-200 cursor-pointer"
                >
                  Sign out
                </button>
              </.form>
            </div>
          </.section_block>

          <.section_block label="Display">
            <div class="flex flex-col gap-3">
              <%!-- Same fix as "Signed in as" — hide redundant inner label on mobile. --%>
              <p class="hidden sm:block font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">
                Theme
              </p>
              <Layouts.theme_toggle />
            </div>
          </.section_block>
        </div>

        <%!--
          Right column: STORAGE panel. The label sits above the content
          rather than beside it (no internal label/content split) — the
          column is already narrower and the table needs the full width.
        --%>
        <div>
          <%!-- Two parallel sections, no outer "Storage" wrapper —
               the labels themselves carry enough context. --%>
          <.section_block label="Your usage" stacked>
            <.your_usage_table stats={@your_stats} />
          </.section_block>

          <.section_block label="Total storage" stacked>
            <.tank_summary totals={@totals} tank_bytes={@tank_bytes} />
            <div class="my-6">
              <.storage_bar breakdown={@breakdown} totals={@totals} tank_bytes={@tank_bytes} />
            </div>
            <.storage_legend breakdown={@breakdown} tank_bytes={@tank_bytes} />
          </.section_block>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ============================================================
  # Section block — used by both columns.
  # ============================================================
  attr :label, :string, required: true
  attr :stacked, :boolean, default: false, doc: "label above content rather than beside"
  slot :inner_block, required: true

  defp section_block(assigns) do
    ~H"""
    <%= if @stacked do %>
      <section class="py-10 border-t border-rule">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-6">
          {@label}
        </p>
        {render_slot(@inner_block)}
      </section>
    <% else %>
      <%!--
        gap-y-6 (not 3) so on mobile, where the columns collapse to
        one and the section label sits ABOVE the content, the section
        label gets clear breathing room from any small label that's
        the first thing inside the content (e.g. "Signed in as" /
        "Theme") — otherwise they read as two same-style labels
        stacked tight on each other. Desktop is unaffected because
        the two cells sit side-by-side and gap-y is a no-op.
      --%>
      <section class="grid grid-cols-1 sm:grid-cols-[180px_1fr] gap-y-6 gap-x-10 py-10 border-t border-rule">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">{@label}</p>
        <div>{render_slot(@inner_block)}</div>
      </section>
    <% end %>
    """
  end

  # ============================================================
  # "Your usage" table — current user's slice. Three rows, no Total.
  # ============================================================
  attr :stats, :map, required: true

  defp your_usage_table(assigns) do
    ~H"""
    <%!--
      Three columns: title (left-aligned), count + size (right-aligned).
      tabular-nums keeps the numbers vertically aligned. No Total row —
      the legend below shows the user's row directly. bytes_movies +
      bytes_shows are the per-type byte attributions (already divided
      by subscriber count in Storage); Episodes shows the count only
      because episode bytes roll up into Shows.
    --%>
    <dl class="grid grid-cols-[1fr_auto_auto] gap-x-8 font-sans text-[0.85rem] tabular-nums">
      <.stat_row label="Movies" count={@stats.movie_count} size={@stats.bytes_movies} />
      <.stat_row label="Shows" count={@stats.show_count} size={@stats.bytes_shows} />
      <.stat_row label="Episodes" count={@stats.episode_count} size={nil} />
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :count, :any, required: true
  attr :size, :any, required: true

  defp stat_row(assigns) do
    ~H"""
    <p class="text-ink py-2">{@label}</p>
    <p class="text-right text-ink py-2">
      {if is_nil(@count), do: "", else: format_count(@count)}
    </p>
    <p class="text-right text-muted py-2 tabular-nums">
      {Aviary.Storage.humanize_bytes(@size)}
    </p>
    """
  end

  defp format_count(n) when is_integer(n) and n >= 1000 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_count(n), do: Integer.to_string(n)

  # ============================================================
  # Tank capacity summary — single line, dot-separated values.
  # ============================================================
  attr :totals, :map, required: true
  attr :tank_bytes, :any, required: true

  defp tank_summary(assigns) do
    ~H"""
    <%!--
      One-line header: tank total · used · free. tabular-nums so the
      digits sit clean; muted color because this is informational
      context for the bar/legend below, not the visual hook. When
      tank_bytes is nil (TANK_BYTES env unset), drop the total + free
      pieces and just show what's used — quieter degraded mode.
    --%>
    <p class="font-sans text-[0.8rem] text-muted tabular-nums mb-4">
      <%= if @tank_bytes do %>
        {Aviary.Storage.humanize_bytes(@tank_bytes)} total
        <span class="px-2 text-rule">·</span>
        {Aviary.Storage.humanize_bytes(@totals.bytes)} used
        <span class="px-2 text-rule">·</span>
        {free_percent(@totals.bytes, @tank_bytes)}% free
      <% else %>
        {Aviary.Storage.humanize_bytes(@totals.bytes)} used
      <% end %>
    </p>
    """
  end

  defp free_percent(used, tank) when tank > 0 do
    pct = (tank - used) / tank * 100
    :erlang.float_to_binary(pct * 1.0, decimals: 2)
  end

  defp free_percent(_, _), do: "0.00"

  # ============================================================
  # Stacked bar — household-share at the moment; would shift to
  # %-of-tank if tank_bytes is set.
  # ============================================================
  attr :breakdown, :list, required: true
  attr :totals, :map, required: true
  attr :tank_bytes, :any, required: true

  defp storage_bar(assigns) do
    assigns =
      assign(assigns,
        scale_bytes: scale_bytes(assigns.breakdown, assigns.totals, assigns.tank_bytes)
      )

    ~H"""
    <%!--
      8px tall, rounded ends, paper-tone-on-rule unused space. Each
      filled segment is a span flexed in via percentage width. Segments
      butt cleanly (no gap) — the color shift IS the boundary. Rounding
      sits on the OUTER bar so the segments themselves stay flat-edged
      against each other.
    --%>
    <div class="h-2 w-full rounded-full bg-rule overflow-hidden flex">
      <%= for entry <- @breakdown do %>
        <span
          class="block h-full"
          style={"width: #{percent(entry.bytes, @scale_bytes)}%; background: var(--user-#{color_slot(entry.user_id)});"}
        ></span>
      <% end %>
    </div>
    """
  end

  defp scale_bytes(_breakdown, totals, nil), do: max(totals.bytes, 1)
  defp scale_bytes(_breakdown, _totals, tank_bytes), do: tank_bytes

  defp percent(0, _), do: 0

  defp percent(bytes, scale) when scale > 0 do
    bytes / scale * 100
  end

  # ============================================================
  # Legend — colored swatch + username on the left, size + % on the
  # right. Layout uses flexbox with justify-between so dot/name hug
  # the left edge and size/% hug the right; no grid columns to fight.
  # % is "of tank" (so we see each user's actual physical footprint),
  # rounded to whole percent.
  # ============================================================
  attr :breakdown, :list, required: true
  attr :tank_bytes, :any, required: true

  defp storage_legend(assigns) do
    ~H"""
    <ul class="mt-2 flex flex-col gap-2 font-sans text-[0.85rem]">
      <%= for entry <- @breakdown do %>
        <li class="flex items-center justify-between gap-4">
          <div class="flex items-center gap-3 min-w-0">
            <span
              class="size-2 rounded-full shrink-0"
              style={"background: var(--user-#{color_slot(entry.user_id)});"}
              aria-hidden="true"
            ></span>
            <span class="text-ink truncate">{entry.username}</span>
          </div>
          <div class="flex items-baseline gap-3 tabular-nums shrink-0">
            <span class="text-muted">{Aviary.Storage.humanize_bytes(entry.bytes)}</span>
            <span class="text-muted text-right w-12">
              {tank_share_percent(entry.bytes, @tank_bytes)}%
            </span>
          </div>
        </li>
      <% end %>
    </ul>
    """
  end

  # % of total tank capacity, rounded to nearest integer. Returns "0"
  # when tank_bytes is unset OR the user's bytes round to less than
  # 0.5% — the bar shows the relative magnitude either way.
  defp tank_share_percent(_user_bytes, nil), do: "0"
  defp tank_share_percent(_user_bytes, 0), do: "0"

  defp tank_share_percent(user_bytes, tank_bytes) do
    "#{round(user_bytes / tank_bytes * 100)}"
  end

  # ============================================================
  # Deterministic color slot — hash user_id to 1..@palette_size.
  # ============================================================
  defp color_slot(user_id) when is_binary(user_id) do
    :erlang.phash2(user_id, @palette_size) + 1
  end
end
