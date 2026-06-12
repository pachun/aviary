defmodule AviaryWeb.LibraryLive do
  @moduledoc """
  The user's library — collapses Shows + Movies into one section with
  a sub-toggle. Tab state lives in the URL (`?type=shows|movies`) so
  switching uses push_patch and stays instant, and links into a
  specific tab are bookmarkable. Default is Shows when type is missing
  or unrecognized.

  Detail-page kicker uses `from=library_shows` / `from=library_movies`
  so the back trip restores the correct tab.
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Library · Aviary")}
  end

  def handle_params(params, _uri, socket) do
    type = parse_type(params["type"])
    items = fetch(type, socket.assigns.current_user)

    {:noreply,
     assign(socket,
       type: type,
       items: items
     )}
  end

  defp parse_type("movies"), do: :movies
  defp parse_type(_), do: :shows

  defp fetch(:shows, user), do: Aviary.Catalog.list_shows(user)
  defp fetch(:movies, user), do: Aviary.Catalog.list_movies(user)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="library" current_user={@current_user}>
      <%!--
        Sub-toggle. Same uppercase tracked Instrument Sans + oxblood
        active underline as the masthead nav, dropped down a tier
        (smaller text, tighter tracking) so it reads as a filter
        under the primary "Library" header rather than competing with
        it.

        Sticky so it stays reachable when the catalog grid scrolls
        past viewport. Top offset matches the masthead's rendered
        height (pt-8/10 + 36px bird + pb-6/8), z-10 puts it below
        the masthead (z-20) so they don't overlap. bg-paper +
        vertical padding so content scrolls cleanly behind.
      --%>
      <nav class="sticky top-[92px] sm:top-[108px] z-10 bg-paper flex items-baseline gap-6 py-3 mb-8 font-sans text-[0.7rem] tracking-[0.18em] uppercase">
        <.tab patch={~p"/library?type=shows"} active={@type == :shows}>Shows</.tab>
        <.tab patch={~p"/library?type=movies"} active={@type == :movies}>Movies</.tab>
      </nav>

      <CatalogGrid.grid items={@items}>
        <:empty>
          <%= if @type == :shows do %>
            You don't have any shows.
          <% else %>
            You don't have any movies.
          <% end %>
        </:empty>
      </CatalogGrid.grid>
    </Layouts.app>
    """
  end

  attr :patch, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "transition-colors duration-200",
        @active && "text-oxblood underline decoration-oxblood decoration-1 underline-offset-[6px]",
        !@active && "text-muted hover:text-ink"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
