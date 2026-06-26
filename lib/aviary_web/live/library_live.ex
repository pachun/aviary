defmodule AviaryWeb.LibraryLive do
  @moduledoc """
  The user's library for one media type, chosen by the URL
  (`?type=shows|movies`). Shows and Movies are separate top-level nav
  tabs; this page renders whichever the `type` param names — defaulting
  to Shows when it's missing or unrecognized, and forcing the kind the
  user actually has when only one is populated.

  Detail-page kicker uses `from=library_shows` / `from=library_movies`
  so the back trip restores the correct tab.
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(_params, _session, socket) do
    {:ok, socket}
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
       page_title: if(type == :shows, do: "Shows", else: "Movies")
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
      current_section={Atom.to_string(@type)}
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <%!--
        pt-2 matches Home / Discover / Search, whose content opens with
        the same top breathing.
      --%>
      <div class="pt-2">
        <CatalogGrid.grid items={@items}>
          <:empty>
            <%= if @type == :shows do %>
              You don't have any shows.
            <% else %>
              You don't have any movies.
            <% end %>
          </:empty>
        </CatalogGrid.grid>
      </div>
    </Layouts.app>
    """
  end
end
