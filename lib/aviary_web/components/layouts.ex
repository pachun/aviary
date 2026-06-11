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
    doc: "which top-level section is active — \"shows\", \"movies\", or nil"

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
            <.section_link href={~p"/shows"} active={@current_section == "shows"}>
              Shows
            </.section_link>
            <.section_link href={~p"/movies"} active={@current_section == "movies"}>
              Movies
            </.section_link>
          </nav>

          <div class="flex items-baseline gap-5">
            <.user_chip :if={@current_user} user={@current_user} />
            <.theme_toggle />
          </div>
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

  attr :user, :map, required: true

  defp user_chip(assigns) do
    ~H"""
    <details class="relative">
      <summary class="list-none cursor-pointer font-sans text-[0.78rem] tracking-[0.15em] uppercase text-muted hover:text-ink transition-colors">
        {@user.username}
      </summary>
      <div class="absolute right-0 mt-3 z-10 min-w-[140px] bg-surface border border-rule rounded-sm shadow-lg">
        <.form for={%{}} action={~p"/logout"} method="post" class="contents">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="_method" value="delete" />
          <button
            type="submit"
            class="w-full text-left px-4 py-3 font-sans text-[0.72rem] tracking-[0.15em] uppercase text-ink hover:text-oxblood cursor-pointer transition-colors"
          >
            Sign out
          </button>
        </.form>
      </div>
    </details>
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
  The day/night theme toggle — italic Fraunces text, oxblood for the
  active state, separator is a vertical hairline. Replaces the typical
  sun/moon icon button because the publication metaphor wants text.

  Implementation: each button dispatches `phx:set-theme` with its
  data-theme; the root.html.heex bootstrap script catches the event
  and updates <html data-theme> + localStorage. CSS selectors below
  match `[data-theme=...]` on the document so the active state
  reflects the current theme without any server state.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="font-display italic text-base leading-none flex items-center gap-2 select-none">
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-theme="day"
        aria-label="Switch to day theme"
        class={[
          "cursor-pointer transition-colors duration-200 focus:outline-none",
          "[[data-theme=day]_&]:text-oxblood",
          "[[data-theme=night]_&]:text-muted [[data-theme=night]_&]:hover:text-ink"
        ]}
      >
        day
      </button>
      <span class="h-3 w-px bg-muted/60" aria-hidden="true"></span>
      <button
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-theme="night"
        aria-label="Switch to night theme"
        class={[
          "cursor-pointer transition-colors duration-200 focus:outline-none",
          "[[data-theme=night]_&]:text-oxblood",
          "[[data-theme=day]_&]:text-muted [[data-theme=day]_&]:hover:text-ink"
        ]}
      >
        night
      </button>
    </div>
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
