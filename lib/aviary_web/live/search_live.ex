defmodule AviaryWeb.SearchLive do
  @moduledoc """
  Single-input full-bleed search across Jellyseerr's `/search/multi`
  (TV + movies in one response). Results render as a flat marquee row
  ordered by Jellyseerr/TMDB relevance — no "in library vs not"
  split, because the click target is the same regardless and the
  detail page already handles the per-state affordances. Debounced so
  typing doesn't fire a Jellyseerr round-trip per keystroke.
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(params, _session, socket) do
    initial_q = (params["q"] || "") |> String.trim()

    socket =
      socket
      |> assign(
        page_title: "Search · Aviary",
        query: initial_q,
        items: [],
        # `loading?` toggles while a request is in flight so the marquee
        # area can render a skeleton instead of "no results."
        loading?: false,
        # The query token currently in-flight, used to discard stale
        # async results when the user keeps typing past an earlier
        # debounce fire.
        in_flight_for: nil
      )
      |> maybe_kick_initial(initial_q)

    {:ok, socket}
  end

  defp maybe_kick_initial(socket, "") do
    socket
  end

  defp maybe_kick_initial(socket, q) do
    do_search(socket, q)
  end

  # `phx-keyup` with `phx-debounce` on the input — LiveView fires this
  # once the user pauses ~300 ms. We re-issue the search even when the
  # text is unchanged (rare given the debounce, but cheap to guard).
  def handle_event("search", %{"value" => value}, socket) do
    q = String.trim(value)

    cond do
      q == socket.assigns.query and not socket.assigns.loading? ->
        {:noreply, socket}

      q == "" ->
        {:noreply,
         socket
         |> assign(:query, "")
         |> assign(:items, [])
         |> assign(:loading?, false)
         |> assign(:in_flight_for, nil)}

      true ->
        {:noreply, do_search(socket, q)}
    end
  end

  # Clearing via the keyboard (escape, etc.) — also exposed by the
  # 'X' button rendered next to the input. Resets to empty state.
  def handle_event("clear", _, socket) do
    {:noreply,
     socket
     |> assign(:query, "")
     |> assign(:items, [])
     |> assign(:loading?, false)
     |> assign(:in_flight_for, nil)}
  end

  defp do_search(socket, q) do
    parent = self()

    Task.start(fn -> send(parent, {:search_result, q, Aviary.Search.run(q)}) end)

    socket
    |> assign(:query, q)
    |> assign(:loading?, true)
    |> assign(:in_flight_for, q)
  end

  # Only apply the result if it belongs to the user's latest query —
  # otherwise it's a stale debounce fire from before they kept typing,
  # and dropping it avoids the "results flicker back to an older
  # query's hits" jank.
  def handle_info({:search_result, q, results}, socket) do
    if q == socket.assigns.in_flight_for do
      {:noreply,
       socket
       |> assign(:items, results)
       |> assign(:loading?, false)
       |> assign(:in_flight_for, nil)}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="search"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <div class="pt-2 space-y-10">
        <%!--
          Search input. Generous height + serif italic placeholder so
          it reads as editorial-search rather than a stuck-in-the-
          masthead toolbar. autocomplete=off keeps the browser's own
          autofill from competing with our own results below.
        --%>
        <div class="border-b border-rule pb-2">
          <input
            type="text"
            name="q"
            id="search-input"
            value={@query}
            phx-keyup="search"
            phx-debounce="300"
            phx-hook="AutoFocus"
            placeholder="Search shows and movies…"
            autocomplete="off"
            class="w-full bg-transparent border-0 outline-none font-display text-ink text-2xl md:text-3xl placeholder:text-muted/60 placeholder:italic"
            style="font-variation-settings: 'opsz' 36;"
          />
        </div>

        <%= cond do %>
          <% @loading? -> %>
            <Marquee.skeleton />
          <% @query == "" -> %>
            <%!-- Empty input → empty screen. No helper copy. --%>
          <% @items == [] -> %>
            <p
              class="font-display italic text-muted/80 text-base"
              style="font-variation-settings: 'opsz' 14;"
            >
              Nothing matched "{@query}".
            </p>
          <% true -> %>
            <Marquee.row items={@items} from="search" key={"search:" <> @query}>
              <:empty>No results.</:empty>
            </Marquee.row>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
