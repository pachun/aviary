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
    user = socket.assigns.current_user
    shows = Aviary.Catalog.list_shows(user)
    movies = Aviary.Catalog.list_movies(user)

    type = effective_type(parse_type(params["type"]), shows, movies)
    items = if type == :shows, do: shows, else: movies

    {:noreply,
     assign(socket,
       type: type,
       items: items,
       has_both_libraries: shows != [] and movies != []
     )}
  end

  defp parse_type("movies"), do: :movies
  defp parse_type(_), do: :shows

  # When the user only has one kind of catalog, force that kind regardless
  # of the requested tab so the body always shows what they actually have.
  defp effective_type(requested, shows, movies) do
    cond do
      shows == [] and movies != [] -> :movies
      movies == [] and shows != [] -> :shows
      true -> requested
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="library"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
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
      <nav
        :if={@has_both_libraries}
        class="sticky top-[92px] sm:top-[108px] z-10 bg-paper flex items-baseline gap-6 py-3 mb-8 font-sans text-[0.7rem] tracking-[0.18em] uppercase"
      >
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
    <%!--
      Pill treatment makes the toggle read as actionable controls
      instead of plain text. Mirrors the primary/secondary button
      vocabulary on the show detail page: active is filled oxblood
      (like the Play button), inactive is outlined ink/rule (like
      the kicker). The user gets an immediate "these are clickable"
      signal without breaking the editorial palette.
    --%>
    <.link
      patch={@patch}
      class={[
        "px-4 py-1.5 rounded-sm border font-medium transition-colors duration-200",
        @active && "bg-oxblood text-white border-oxblood",
        !@active &&
          "bg-transparent text-muted border-rule hover:text-ink hover:border-ink"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
