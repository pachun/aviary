defmodule AviaryWeb.Layouts do
  @moduledoc """
  App-wide layouts: the masthead (with section nav + theme toggle) that
  wraps every LiveView's content slot, plus flash group + theme toggle
  components.

  Visual language: editorial cabinet — Fraunces display serif, Instrument
  Sans for UI, day/night themes via [data-theme] on <html>, single
  oxblood accent. See assets/css/app.css for tokens.
  """
  use AviaryWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_section, :string,
    default: nil,
    doc: "which top-level section is active — \"home\", \"discover\", \"shows\", \"movies\", or nil"

  attr :current_user, :map,
    default: nil,
    doc: "currently signed-in user; surfaces as a chip in the masthead"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-paper text-ink antialiased">
      <header class="px-4 sm:px-8 lg:px-12 pt-8 pb-10 sm:pt-10 sm:pb-12">
        <div class="mx-auto max-w-[1100px] flex items-baseline justify-between gap-8">
          <nav class="flex items-baseline gap-8 text-[0.78rem] font-sans tracking-[0.15em] uppercase">
            <.section_link href={~p"/home"} active={@current_section == "home"}>
              Home
            </.section_link>
            <.section_link href={~p"/discover"} active={@current_section == "discover"}>
              Discover
            </.section_link>
            <.section_link href={~p"/shows"} active={@current_section == "shows"}>
              Shows
            </.section_link>
            <.section_link href={~p"/movies"} active={@current_section == "movies"}>
              Movies
            </.section_link>
          </nav>

          <.bird_menu current_user={@current_user} />
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

  @doc """
  Bird-logo dropdown — appears in the top-right on every screen
  (logged in or not). Hovering / tapping it opens a small menu:
  the day/night theme toggle always, plus a Sign out row when a
  user is signed in.

  Pure CSS open/close via :hover (desktop) and :focus-within
  (touch — tapping the trigger focuses it, tapping outside blurs
  it). No JS required.
  """
  attr :current_user, :any, default: nil

  def bird_menu(assigns) do
    ~H"""
    <div class="group relative">
      <button
        type="button"
        aria-haspopup="true"
        aria-label="Menu"
        class="block cursor-pointer focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper rounded-sm"
      >
        <img
          src={~p"/images/apple-touch-icon.png"}
          alt="Aviary"
          class="size-9 rounded-sm"
        />
      </button>

      <%!--
        Popup positioned at `top-full` with `pt-3` padding — the
        visual gap to the trigger is *inside* the popup's box, so
        the cursor stays within the hover region while crossing it.
        Margin-based gaps (mt-3) broke this — the area outside the
        popup wasn't a descendant of `.group` so :hover ended mid-flight.
      --%>
      <div class={[
        "absolute right-0 top-full pt-3 z-20",
        "invisible opacity-0 pointer-events-none transition-opacity duration-150",
        "group-hover:visible group-hover:opacity-100 group-hover:pointer-events-auto",
        "group-focus-within:visible group-focus-within:opacity-100 group-focus-within:pointer-events-auto"
      ]}>
        <div class="min-w-[170px] bg-surface border border-rule rounded-sm shadow-lg overflow-hidden">
          <div class="px-4 py-3 flex items-center justify-center border-b border-rule">
            <.theme_toggle />
          </div>

          <.form
            :if={@current_user}
            for={%{}}
            action={~p"/logout"}
            method="post"
            class="contents"
          >
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="_method" value="delete" />
            <button
              type="submit"
              class="w-full text-center px-4 py-3 font-sans text-[0.72rem] tracking-[0.18em] uppercase text-ink hover:text-oxblood cursor-pointer transition-colors"
            >
              Sign out
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp section_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "transition-colors duration-200",
        @active && "text-oxblood underline decoration-oxblood decoration-1 underline-offset-[6px]",
        !@active && "text-muted hover:text-ink"
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
    <div id={@id} aria-live="polite">
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
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

end
