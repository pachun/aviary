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
    breakdown = Storage.breakdown_per_user(socket.assigns.current_user)
    totals = Storage.totals(breakdown)
    tank_bytes = Storage.tank_bytes()

    {:ok,
     assign(socket,
       page_title: "Settings · Aviary",
       breakdown: breakdown,
       totals: totals,
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
            <.storage_table totals={@totals} />

            <%!-- Hairline between the table and the bar — same rule
                 token used between sections, restating the rhythm. --%>
            <div class="border-t border-rule my-6"></div>

            <.storage_bar breakdown={@breakdown} totals={@totals} tank_bytes={@tank_bytes} />

            <.storage_legend breakdown={@breakdown} />
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
  # Storage table — Movies / Shows / Episodes / Total
  # ============================================================
  attr :totals, :map, required: true

  defp storage_table(assigns) do
    ~H"""
    <%!--
      Three columns: title (left-aligned), count + size (right-aligned).
      tabular-nums keeps the numbers vertically aligned without manual
      width-setting. py-2 per row gives the typographic breathing room
      the rest of the page uses.

      Total row sits above a hairline rule, with a slight font-weight
      bump. Oxblood is reserved for the stacked bar — Total stays in
      text-ink so the page's accent budget concentrates lower.
    --%>
    <dl class="grid grid-cols-[1fr_auto_auto] gap-x-8 font-sans text-[0.85rem] tabular-nums">
      <.stat_row label="Movies"   count={@totals.movie_count}   size={@totals.bytes_movies} />
      <.stat_row label="Shows"    count={@totals.show_count}    size={@totals.bytes_shows} />
      <.stat_row label="Episodes" count={@totals.episode_count} size={nil} />
      <div class="col-span-3 border-t border-rule mt-2 pt-2"></div>
      <.stat_row
        label="Total"
        count={nil}
        size={@totals.bytes}
        weight="font-medium"
      />
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :count, :any, required: true
  attr :size, :any, required: true
  attr :weight, :string, default: ""

  defp stat_row(assigns) do
    ~H"""
    <p class={["text-ink py-2", @weight]}>{@label}</p>
    <p class={["text-right text-ink py-2", @weight]}>
      {if is_nil(@count), do: "", else: format_count(@count)}
    </p>
    <p class={["text-right text-muted py-2 tabular-nums", @weight]}>
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
  # Legend — colored swatch + username + their size
  # ============================================================
  attr :breakdown, :list, required: true

  defp storage_legend(assigns) do
    ~H"""
    <ul class="mt-6 flex flex-col gap-2 font-sans text-[0.85rem] tabular-nums">
      <%= for entry <- @breakdown do %>
        <li class="grid grid-cols-[auto_1fr_auto] items-baseline gap-3">
          <%!-- 8px swatch — small enough to read as data ink, not chrome --%>
          <span
            class="size-2 rounded-full self-center"
            style={"background: var(--user-#{color_slot(entry.user_id)});"}
            aria-hidden="true"
          ></span>
          <span class="text-ink">{entry.username}</span>
          <span class="text-right text-muted">{Aviary.Storage.humanize_bytes(entry.bytes)}</span>
        </li>
      <% end %>
    </ul>
    """
  end

  # ============================================================
  # Deterministic color slot — hash user_id to 1..@palette_size.
  # ============================================================
  defp color_slot(user_id) when is_binary(user_id) do
    :erlang.phash2(user_id, @palette_size) + 1
  end
end
