defmodule AviaryWeb.Layouts do
  @moduledoc """
  App-wide layouts: the masthead (section nav on the left, settings
  gear on the right) that wraps every LiveView's content slot, plus
  the flash group and the theme toggle component (rendered on the
  /settings page now, not in the masthead).

  Visual language: editorial cabinet — Fraunces display serif, Instrument
  Sans for UI, day/night themes via [data-theme] on <html>, single
  oxblood accent. See assets/css/app.css for tokens.
  """
  use AviaryWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_section, :string,
    default: nil,
    doc: "which top-level section is active — \"home\", \"discover\", \"search\", \"library\", or nil"

  attr :current_user, :map,
    default: nil,
    doc: "currently signed-in user; surfaces as a chip in the masthead"

  attr :nav_visibility, :map,
    default: %{discover: true, home: true, library: true, search: true},
    doc:
      "Which top-level nav links to render — Discover and Search are always true; Home and Library hide when the user has no content for them, so a brand-new user sees only Discover and Search."

  attr :mobile_title, :string,
    default: nil,
    doc:
      "Title for the mobile sticky top-bar. When set, the bar renders on mobile only, clears the iOS safe-area inset, and stays anchored to the viewport top. Desktop ignores this."

  attr :mobile_back_to, :string,
    default: nil,
    doc: "Optional back-link href for the mobile top-bar (renders a chevron-left to the left of the title). Omit on root pages like Settings."

  attr :mobile_back_label, :string,
    default: nil,
    doc: "The DESTINATION name shown next to the chevron (e.g., \"Library\", \"Discover\"). Different from `mobile_title` (current page name) so the back button can't be mistaken for a self-link. iOS pattern: ‹ Library    Dutton Ranch."

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!--
      min-h-dvh (NOT min-h-screen) — on iOS Safari, `100vh` includes
      the area BEHIND the URL bar, making min-h-screen elements
      taller than the currently-visible viewport. That extra height
      becomes a phantom scroll region (roughly URL-bar / tab-bar
      sized) on pages whose actual content fits the viewport. The
      `dvh` ("dynamic viewport height") unit always matches the
      currently-visible area and avoids the bug.

      No overflow-x handling — we removed that defensively because
      iOS WebKit has a known bug where ancestor `overflow-x: clip`
      quietly breaks `position: sticky` descendants. If real
      horizontal-overflow appears later, fix it at the offending
      component rather than papering over it here.
    --%>
    <div class="min-h-dvh bg-paper text-ink antialiased">
      <%!--
        ====================================================
        Mobile sticky top bar — iOS large-title pattern.
        ====================================================
        Hidden by default (opacity-0, inert) and fades in via the
        MobileTopBar JS hook when the page's body title scrolls
        out of view. The body title carries `data-mobile-top-bar-
        trigger` and the IntersectionObserver watches it.

        Layout: back-with-destination on the LEFT, title CENTERED.
        The destination-name on the back button (e.g. "Library")
        prevents "‹ Dutton Ranch" from reading as a back-to-self
        link; the back-button's destination and the title now
        unambiguously label different things.

        Chevron: hand-rolled inline SVG with iOS proportions
        (tall narrow shape, 2.5 stroke, rounded line caps). The
        heroicons chevron-left at this size reads as chunky;
        this one reads as native.

        Title centered via absolute-position + translate-x-1/2 so
        it stays dead-center regardless of back-label width. The
        max-w-[60%] safety keeps long titles from colliding with
        the back link on narrow viewports.
      --%>
      <header
        id="mobile-top-bar"
        :if={@mobile_title}
        phx-hook="MobileTopBar"
        class={[
          "sm:hidden sticky top-0 z-30 bg-paper pt-[env(safe-area-inset-top)]",
          "opacity-0 pointer-events-none transition-opacity duration-200",
          "data-[show]:opacity-100 data-[show]:pointer-events-auto"
        ]}
      >
        <div class="relative flex items-center min-h-[44px] px-4 border-b border-rule/60">
          <a
            :if={@mobile_back_to}
            href={@mobile_back_to}
            aria-label={"Back to #{@mobile_back_label || "previous"}"}
            class="flex items-center gap-1 text-oxblood -ml-2 px-2 py-2 rounded-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40"
          >
            <svg
              viewBox="0 0 12 20"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              class="w-3 h-5 shrink-0"
              aria-hidden="true"
            >
              <path d="M10 2 L2 10 L10 18" />
            </svg>
            <span :if={@mobile_back_label} class="font-sans text-base leading-none">
              {@mobile_back_label}
            </span>
          </a>
          <h1 class="absolute left-1/2 -translate-x-1/2 max-w-[60%] font-display text-base text-ink leading-none truncate text-center">
            {@mobile_title}
          </h1>
        </div>
      </header>

      <%!--
        ====================================================
        Desktop masthead — original combined nav + gear.
        ====================================================
        Unchanged from prior behavior; only the visibility
        breakpoint shifted (now hidden below sm: so the
        mobile top + bottom rails take over).
      --%>
      <header class="hidden sm:block sticky top-0 z-20 bg-paper sm:px-8 lg:px-12 sm:pt-10 sm:pb-8">
        <%!--
          items-baseline on the outer flex so the gear's bottom edge
          rests on the same baseline as the nav text — same typographic
          rhythm an editorial layout would set for a small glyph in
          running copy.
        --%>
        <%!--
          Desktop nav suppresses the active-section highlight on
          detail pages (signaled by `mobile_back_to` being set —
          detail pages have a back affordance, top-level pages
          don't). Per prior feedback, having a desktop nav link
          highlighted while you're on a show/movie detail page
          reads as "you're still in the section" which is more
          confusing than just not highlighting anything.

          The mobile bottom tab bar uses the same current_section
          but the OPPOSITE policy — it DOES highlight on detail
          pages so the user gets a wayfinding cue for which
          section they came from.
        --%>
        <div class="mx-auto max-w-[1100px] flex items-baseline justify-between gap-8">
          <nav class="flex items-baseline gap-8 text-[0.78rem] font-sans tracking-[0.15em] uppercase">
            <.section_link
              :if={@nav_visibility.home}
              href={~p"/home"}
              active={is_nil(@mobile_back_to) && @current_section == "home"}
            >
              Home
            </.section_link>
            <.section_link
              :if={@nav_visibility.library}
              href={~p"/library"}
              active={is_nil(@mobile_back_to) && @current_section == "library"}
            >
              Library
            </.section_link>
            <.section_link
              href={~p"/discover"}
              active={is_nil(@mobile_back_to) && @current_section == "discover"}
            >
              Discover
            </.section_link>
            <.section_link
              href={~p"/search"}
              active={is_nil(@mobile_back_to) && @current_section == "search"}
            >
              Search
            </.section_link>
          </nav>

          <%!--
            Settings entry-point — small gear, muted by default, oxblood
            on hover/focus to match the nav-link rhythm. Only shown to
            signed-in users; on the sign-in screen there's nothing here.
          --%>
          <a
            :if={@current_user}
            href={~p"/settings"}
            aria-label="Settings"
            class="text-muted hover:text-oxblood transition-colors duration-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper rounded-sm"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" />
          </a>
        </div>
      </header>

      <%!--
        Bottom padding lives on the INNER max-w div (not on main)
        so any sticky elements inside the slot have their containing
        block extended past the natural content end. With pb on main
        only, a sticky element's containing block (the inner div)
        ended before main did, and iOS rubber-band overscroll could
        push that containing block's bottom up through the sticky's
        pinned position — detaching the sticky. Putting pb on the
        inner div fixes this by including the breathing room in the
        sticky's bounds.
      --%>
      <main class="px-4 sm:px-8 lg:px-12">
        <div class="mx-auto max-w-[1100px] pb-28 sm:pb-24">
          {render_slot(@inner_block)}
        </div>
      </main>

      <%!--
        ====================================================
        Mobile bottom tab bar — primary nav + settings.
        ====================================================
        Five tabs max: Home / Discover / Search / Library /
        Settings. Home and Library hide when the user has no
        content for them, so a brand-new user sees 3 tabs.

        Each tab: heroicon (outline when inactive, solid when
        active) above a small Instrument Sans label. Active
        tab shifts to oxblood; inactive sits in muted. No pill
        backgrounds, no underlines, no scale animations —
        color + icon-weight is the entire state signal.

        pb adds env(safe-area-inset-bottom) so the bar clears
        the iOS home indicator instead of fighting it for
        touch attention. min-h-[64px] on the inner row keeps
        each tap target generously above the 44pt iOS HIG
        minimum even after the safe area pushes content up.
      --%>
      <nav
        :if={@current_user}
        class="sm:hidden fixed bottom-0 inset-x-0 z-20 bg-paper border-t border-rule pb-[env(safe-area-inset-bottom)]"
      >
        <div class="flex items-stretch justify-around min-h-[64px]">
          <.tab_bar_link
            :if={@nav_visibility.home}
            href={~p"/home"}
            active={@current_section == "home"}
            label="Home"
            icon_outline="hero-home"
            icon_solid="hero-home-solid"
          />
          <.tab_bar_link
            :if={@nav_visibility.library}
            href={~p"/library"}
            active={@current_section == "library"}
            label="Library"
            icon_outline="hero-rectangle-stack"
            icon_solid="hero-rectangle-stack-solid"
          />
          <.tab_bar_link
            href={~p"/discover"}
            active={@current_section == "discover"}
            label="Discover"
            icon_outline="hero-sparkles"
            icon_solid="hero-sparkles-solid"
          />
          <.tab_bar_link
            href={~p"/search"}
            active={@current_section == "search"}
            label="Search"
            icon_outline="hero-magnifying-glass"
            icon_solid="hero-magnifying-glass-solid"
          />
          <.tab_bar_link
            href={~p"/settings"}
            active={@current_section == "settings"}
            label="Settings"
            icon_outline="hero-cog-6-tooth"
            icon_solid="hero-cog-6-tooth-solid"
          />
        </div>
      </nav>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp section_link(assigns) do
    ~H"""
    <%!--
      Inactive links also get an underline on hover (decoration-ink at
      the same offset as the active underline). Without it the muted
      text reads as flat copy — adding the appearing-underline gives
      the "clickable" cue without compromising the editorial calm.
    --%>
    <a
      href={@href}
      class={[
        "transition-colors duration-200 underline-offset-[6px] decoration-1",
        @active && "text-oxblood underline decoration-oxblood",
        !@active && "text-muted hover:text-ink hover:underline hover:decoration-ink"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :label, :string, required: true
  attr :icon_outline, :string, required: true, doc: "heroicon name for the inactive state"
  attr :icon_solid, :string, required: true, doc: "heroicon name for the active state"

  defp tab_bar_link(assigns) do
    ~H"""
    <%!--
      Single tab in the mobile bottom bar. iOS HIG shape: icon stacked
      above a small text label, full-width touch target. Outline icon
      flips to solid when active; color shifts from muted to oxblood.

      flex-1 spreads tabs evenly across the bar regardless of how
      many render (3, 4, or 5 depending on nav_visibility). The
      whole anchor is the tap area — labels at 10px would be
      fingertip-hostile if only the label itself were clickable.
    --%>
    <a
      href={@href}
      aria-label={@label}
      aria-current={@active && "page"}
      class={[
        "flex-1 flex flex-col items-center justify-center gap-1 py-2",
        "transition-colors duration-200",
        "focus:outline-none focus-visible:bg-rule/40",
        @active && "text-oxblood",
        !@active && "text-muted hover:text-ink"
      ]}
    >
      <.icon name={if @active, do: @icon_solid, else: @icon_outline} class="size-6" />
      <span class="font-sans text-[0.65rem] leading-none">{@label}</span>
    </a>
    """
  end

  @doc """
  Theme toggle — a small slider switch between light and dark, with
  sun and moon glyphs at either end. Click anywhere on the row to
  flip; the slider knob slides via CSS based on the current
  `[data-theme]` value, no per-click round-trip needed.

  The `phx:toggle-theme` event is handled by the bootstrap script in
  root.html.heex — it reads the current theme and swaps it.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={JS.dispatch("phx:toggle-theme")}
      aria-label="Toggle light/dark"
      class="flex items-center gap-2 cursor-pointer select-none focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper rounded"
    >
      <.icon name="hero-sun-micro" class="size-4 text-muted shrink-0" />
      <span class="relative inline-block w-9 h-5 bg-rule rounded-full shrink-0">
        <span class={[
          "absolute top-0.5 left-0.5 size-4 rounded-full bg-oxblood transition-transform duration-200",
          "[[data-theme=night]_&]:translate-x-4"
        ]}>
        </span>
      </span>
      <.icon name="hero-moon-micro" class="size-4 text-muted shrink-0" />
    </button>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <%!--
      Single positioning container — fixed to the viewport's top-right
      corner, flex-col gap-3 so multiple simultaneous flashes stack
      vertically with breathing room instead of piling at the same
      coordinate. z-50 keeps the group above the sticky masthead's
      z-20. pointer-events-none on the wrapper + auto on each child
      so the area between cards isn't a transparent click trap.
    --%>
    <div
      id={@id}
      aria-live="polite"
      class="fixed top-6 right-4 sm:right-6 z-50 flex flex-col gap-3 pointer-events-none [&>*]:pointer-events-auto"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path-mini" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path-mini" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

end
