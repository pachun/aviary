defmodule AviaryWeb.HomeLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Home · Aviary",
       items: Aviary.Home.continue_watching(socket.assigns.current_user)
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
    </Layouts.app>
    """
  end
end
