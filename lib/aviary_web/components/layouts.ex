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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!--
      overflow-x-clip catches any rogue child wider than the viewport
      so it can't trigger horizontal scroll on mobile. `clip` (not
      `hidden`) is intentional — `hidden` establishes a new scrolling
      container which would break the sticky masthead inside it; `clip`
      just snips the overflow without creating that scroll context.
    --%>
    <div class="min-h-screen bg-paper text-ink antialiased overflow-x-clip">
      <%!--
        ====================================================
        Mobile top strip — brand + settings only.
        ====================================================
        Quiet Newsreader "Aviary" wordmark on the left,
        settings gear on the right. Primary nav lives on the
        bottom rail (below); top strip is just identity + the
        rare settings entry-point. Sticky so the gear stays
        reachable during scroll.
      --%>
      <header class="sm:hidden sticky top-0 z-20 bg-paper px-4 pt-5 pb-3">
        <div class="flex items-center justify-between">
          <a
            href={~p"/"}
            class="font-heading text-lg text-ink leading-none focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper rounded-sm"
          >
            Aviary
          </a>
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
        <div class="mx-auto max-w-[1100px] flex items-baseline justify-between gap-8">
          <nav class="flex items-baseline gap-8 text-[0.78rem] font-sans tracking-[0.15em] uppercase">
            <.section_link
              :if={@nav_visibility.home}
              href={~p"/home"}
              active={@current_section == "home"}
            >
              Home
            </.section_link>
            <.section_link href={~p"/discover"} active={@current_section == "discover"}>
              Discover
            </.section_link>
            <.section_link href={~p"/search"} active={@current_section == "search"}>
              Search
            </.section_link>
            <.section_link
              :if={@nav_visibility.library}
              href={~p"/library"}
              active={@current_section == "library"}
            >
              Library
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
        pb-24 sm:pb-24 — both viewports need bottom space, but for
        different reasons. Desktop: editorial breathing room below
        the last content. Mobile: clear the fixed bottom rail (~52px
        + breathing). Numbers happen to coincide; kept separate so
        either can be tuned without affecting the other.
      --%>
      <main class="px-4 sm:px-8 lg:px-12 pb-24 sm:pb-24">
        <div class="mx-auto max-w-[1100px]">
          {render_slot(@inner_block)}
        </div>
      </main>

      <%!--
        ====================================================
        Mobile bottom rail — primary nav.
        ====================================================
        Pure typographic state machine: inactive sections set
        in Instrument Sans uppercase tracked small-caps;
        active section set in Newsreader display serif italic,
        lowercase, larger. The typeface SHIFT is the active
        indicator (no oxblood underline, no pill background).
        Because the active label is larger, it visually rises
        above the others on the shared baseline — "you are
        here" without any additional decoration.

        Pulled directly from aviary's design system: every face
        used here (Instrument Sans tracked, Newsreader italic)
        is already established in the brand vocabulary. The
        navigation primitive is just expressing the brand
        voice as state.

        Hairline border-top separates rail from scrolling
        content above. fixed bottom-0 + inset-x-0 pins to the
        viewport's bottom edge regardless of scroll position;
        z-20 sits above marquee cards.
      --%>
      <nav
        :if={@current_user}
        class="sm:hidden fixed bottom-0 inset-x-0 z-20 bg-paper border-t border-rule"
      >
        <div class="flex items-baseline justify-evenly px-4 pt-3 pb-4">
          <.mobile_section_link
            :if={@nav_visibility.home}
            href={~p"/home"}
            active={@current_section == "home"}
          >
            Home
          </.mobile_section_link>
          <.mobile_section_link href={~p"/discover"} active={@current_section == "discover"}>
            Discover
          </.mobile_section_link>
          <.mobile_section_link href={~p"/search"} active={@current_section == "search"}>
            Search
          </.mobile_section_link>
          <.mobile_section_link
            :if={@nav_visibility.library}
            href={~p"/library"}
            active={@current_section == "library"}
          >
            Library
          </.mobile_section_link>
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
  slot :inner_block, required: true

  defp mobile_section_link(assigns) do
    ~H"""
    <%!--
      Mobile bottom-rail nav link. Two states, two typefaces:

        :active   → Newsreader display serif italic, lowercase,
                    1.05rem text, oxblood. The brand's display rhythm
                    pulled into the navigation primitive.

        :inactive → Instrument Sans uppercase tracked, 0.7rem,
                    muted. Catalog-text small-caps.

      Items share `items-baseline` on the parent so both sizes align
      at the baseline; the active label extends UPWARD past the
      others, giving "you are here" by elevation rather than by
      decoration. lowercase / uppercase transforms convert the same
      slot text ("Discover") to the right form per state, so the
      caller's source text stays Title Case.

      tap target: py-2 negative-margin trick keeps the visual
      typography tight while expanding the touchable rectangle to
      ~44×44px — well within iOS HIG / Material guidelines without
      adding visible padding to the chip.
    --%>
    <a
      href={@href}
      class={[
        "transition-colors duration-200 -my-2 py-2 px-1",
        @active && "font-heading italic text-[1.05rem] lowercase text-oxblood leading-none",
        !@active &&
          "font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted hover:text-ink leading-none"
      ]}
    >
      {render_slot(@inner_block)}
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
