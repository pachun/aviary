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
        Sticky masthead so the nav stays reachable on long pages
        (discover scrolls past a viewport now). bg-paper keeps content
        from bleeding through; z-20 sits above marquee cards and
        their hover rings.
      --%>
      <header class="sticky top-0 z-20 bg-paper px-4 sm:px-8 lg:px-12 pt-8 pb-6 sm:pt-10 sm:pb-8">
        <%!--
          items-baseline on the outer flex so the gear's bottom edge
          rests on the same baseline as the nav text — same typographic
          rhythm an editorial layout would set for a small glyph in
          running copy.

          Mobile-tight spacing: gap-3 between nav and gear (was gap-8)
          so a 360px viewport doesn't overflow once you account for
          four tracked-uppercase nav links plus the gear. Restores to
          gap-8 at sm.
        --%>
        <div class="mx-auto max-w-[1100px] flex items-baseline justify-between gap-3 sm:gap-8">
          <%!--
            Mobile: smaller text + tighter tracking + tighter gap so
            four nav links fit comfortably on a 360px-wide phone.
            Restores to the editorial rhythm at sm: same 0.78rem
            tracked-0.15em the rest of the design was built around.
          --%>
          <nav class="flex items-baseline gap-4 sm:gap-8 text-[0.65rem] sm:text-[0.78rem] font-sans tracking-[0.08em] sm:tracking-[0.15em] uppercase">
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

      <main class="px-4 sm:px-8 lg:px-12 pb-24">
        <div class="mx-auto max-w-[1100px]">
          {render_slot(@inner_block)}
        </div>
      </main>

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
