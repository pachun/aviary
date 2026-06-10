defmodule AviaryWeb.MoviesLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Movies · Aviary",
       items: Aviary.Catalog.list_movies()
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="movies">
      <CatalogGrid.grid items={@items}>
        <:empty>You don't have any movies.</:empty>
      </CatalogGrid.grid>
    </Layouts.app>
    """
  end
end
