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
       page_title: "Settings · Aviary",
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
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <%!--
        Page header: eyebrow + serif display title. Same rhythm the
        other section pages use (Discover, Library) so this lands as
        "an aviary page" before it lands as "the settings page."
      --%>
      <header class="pt-4 sm:pt-6 pb-12 sm:pb-16">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-3">
          Account &amp; preferences
        </p>
        <h1 class="font-display text-5xl sm:text-6xl text-ink">Settings</h1>
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
                <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted mb-1">
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
              <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">Theme</p>
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
          <.section_block label="Storage" stacked>
            <%!-- Sub-block: this user's slice of the library. Same
                 small-uppercase-tracked treatment as the section
                 label one step smaller, in text-muted so the rhythm
                 reads as "section / sub-section." --%>
            <.sub_label>Your usage</.sub_label>
            <.your_usage_table stats={@your_stats} />

            <div class="border-t border-rule my-8"></div>

            <%!-- Sub-block: household-wide tank context. Header line
                 with three dot-separated values, then the stacked bar,
                 then the per-user legend with proportional %. --%>
            <.sub_label>Total storage</.sub_label>
            <.tank_summary totals={@totals} tank_bytes={@tank_bytes} />
            <.storage_bar breakdown={@breakdown} totals={@totals} tank_bytes={@tank_bytes} />
            <.storage_legend breakdown={@breakdown} totals={@totals} />
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
      <section class="grid grid-cols-1 sm:grid-cols-[180px_1fr] gap-y-3 gap-x-10 py-10 border-t border-rule">
        <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">{@label}</p>
        <div>{render_slot(@inner_block)}</div>
      </section>
    <% end %>
    """
  end

  # ============================================================
  # Sub-section label — one step smaller than the section label.
  # ============================================================
  slot :inner_block, required: true

  defp sub_label(assigns) do
    ~H"""
    <p class="font-sans text-[0.65rem] tracking-[0.18em] uppercase text-muted mb-4">
      {render_slot(@inner_block)}
    </p>
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
  # Legend — colored swatch + username + their size + their % of
  # household usage. % is intentionally NOT % of tank — that'd be
  # near-zero for everyone until the tank fills. % of household used
  # gives a meaningful comparison even early.
  # ============================================================
  attr :breakdown, :list, required: true
  attr :totals, :map, required: true

  defp storage_legend(assigns) do
    ~H"""
    <ul class="mt-6 flex flex-col gap-2 font-sans text-[0.85rem] tabular-nums">
      <%= for entry <- @breakdown do %>
        <li class="grid grid-cols-[auto_1fr_auto_auto] items-baseline gap-x-3">
          <%!-- 8px swatch — small enough to read as data ink, not chrome --%>
          <span
            class="size-2 rounded-full self-center"
            style={"background: var(--user-#{color_slot(entry.user_id)});"}
            aria-hidden="true"
          ></span>
          <span class="text-ink">{entry.username}</span>
          <span class="text-right text-muted">{Aviary.Storage.humanize_bytes(entry.bytes)}</span>
          <span class="text-right text-muted pl-3">
            {household_share_percent(entry.bytes, @totals.bytes)}%
          </span>
        </li>
      <% end %>
    </ul>
    """
  end

  defp household_share_percent(_user_bytes, 0), do: "0"

  defp household_share_percent(user_bytes, total_bytes) do
    pct = user_bytes / total_bytes * 100
    cond do
      pct >= 10 -> "#{round(pct)}"
      pct == 0 -> "0"
      true -> :erlang.float_to_binary(pct * 1.0, decimals: 1)
    end
  end

  # ============================================================
  # Deterministic color slot — hash user_id to 1..@palette_size.
  # ============================================================
  defp color_slot(user_id) when is_binary(user_id) do
    :erlang.phash2(user_id, @palette_size) + 1
  end
end
