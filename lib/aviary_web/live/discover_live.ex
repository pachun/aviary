defmodule AviaryWeb.DiscoverLive do
  @moduledoc """
  Discover page — one marquee row per major streaming service,
  showing currently-popular TV on each. Click target is the existing
  show detail page; for shows not yet in the user's Jellyfin library
  that page bounces with "show not found" (acknowledged interim
  behavior until the not-in-library detail flow lands).
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Discover · Aviary",
       rows: Aviary.Discover.rows()
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="discover" current_user={@current_user}>
      <section :for={row <- @rows} class="pt-4 first:pt-2 mb-10 last:mb-0">
        <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
          {row.label}
        </h2>
        <Marquee.row items={row.items} from="discover" key={"discover:" <> row.label}>
          <:empty>No recommendations available right now.</:empty>
        </Marquee.row>
      </section>
    </Layouts.app>
    """
  end
end
