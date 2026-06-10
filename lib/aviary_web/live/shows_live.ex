defmodule AviaryWeb.ShowsLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Shows · Aviary",
       items: Aviary.Catalog.list_shows()
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="shows">
      <CatalogGrid.grid items={@items}>
        <:empty>You don't have any shows.</:empty>
      </CatalogGrid.grid>
    </Layouts.app>
    """
  end
end
