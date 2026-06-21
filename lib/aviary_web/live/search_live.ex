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
        # Result groups: `[]` when no results, otherwise `[{label, items}, …]`
        # with at most two entries (Shows + Movies). Ordering: the group
        # whose top result is the highest-relevance overall wins the top
        # slot, so the row+card you're most likely looking for sits at
        # top-left. See group_results/1.
        groups: [],
        # `loading?` toggles while a request is in flight so the marquee
        # area can render a skeleton instead of "no results."
        loading?: false,
        # The query token currently in-flight, used to discard stale
        # async results when the user keeps typing past an earlier
        # debounce fire.
        in_flight_for: nil,
        # The user's recent committed searches, surfaced in the empty
        # state as clickable shortcuts. Click-tracked, capped, ordered
        # newest first — see Aviary.RecentSearches.
        recent: Aviary.RecentSearches.for_user(socket.assigns.current_user.id)
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
         |> assign(:groups, [])
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
     |> assign(:groups, [])
     |> assign(:loading?, false)
     |> assign(:in_flight_for, nil)}
  end

  # Click on a recent-search chip in the empty state — re-run the
  # search exactly as if the user had typed it. The input's value
  # is bound to @query so updating the assign re-paints it; do_search
  # handles the rest (sets loading?, kicks the async task).
  def handle_event("rerun", %{"q" => q}, socket) do
    {:noreply, do_search(socket, q)}
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
       |> assign(:groups, group_results(results))
       |> assign(:loading?, false)
       |> assign(:in_flight_for, nil)}
    else
      {:noreply, socket}
    end
  end

  # Splits the flat relevance-ordered result list into per-kind groups
  # for rendering as two stacked rows (one for Shows, one for Movies).
  # The group whose top result is overall-best (i.e., the first item
  # in `results`) gets the top slot, so the cell the user is most
  # likely looking for is top-left. With only one kind present, returns
  # a single group; empty input → empty list (template skips render).
  defp group_results([]), do: []

  defp group_results([first | _] = results) do
    shows = Enum.filter(results, &(&1.kind == :show))
    movies = Enum.filter(results, &(&1.kind == :movie))

    cond do
      shows == [] -> [{"Movies", movies}]
      movies == [] -> [{"Shows", shows}]
      first.kind == :show -> [{"Shows", shows}, {"Movies", movies}]
      true -> [{"Movies", movies}, {"Shows", shows}]
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
            <%!--
              Empty input → recent searches if there are any, else
              truly blank (matches the previous behavior for first-
              time users / new boxes). Each row re-runs that search
              via the "rerun" event. The chevron is a typographic
              continuation mark, matching the marquee edge buttons.
            --%>
            <div :if={@recent != []} class="space-y-3">
              <p class="font-sans uppercase tracking-[0.18em] text-[0.7rem] text-muted">
                Recent
              </p>
              <ul class="flex flex-col">
                <li :for={q <- @recent} class="border-b border-rule last:border-b-0">
                  <button
                    type="button"
                    phx-click="rerun"
                    phx-value-q={q}
                    class="group w-full block py-3 px-1 cursor-pointer text-left transition-colors hover:bg-rule/30 focus:outline-none focus-visible:bg-rule/30"
                  >
                    <span class="font-display text-ink text-lg block truncate group-hover:text-oxblood transition-colors">
                      {q}
                    </span>
                  </button>
                </li>
              </ul>
            </div>
          <% @groups == [] -> %>
            <p
              class="font-display italic text-muted/80 text-base"
              style="font-variation-settings: 'opsz' 14;"
            >
              Nothing matched "{@query}".
            </p>
          <% true -> %>
            <%!--
              One section per result kind (Shows + Movies). Section
              labels match Discover's typographic register (small caps
              tracked Instrument Sans), so the search results page
              feels like a sibling of Discover rather than its own
              vocabulary. The top section's first card is the highest-
              relevance match overall — i.e., the most likely answer
              sits top-left.
            --%>
            <section :for={{label, items} <- @groups} class="space-y-4">
              <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted">
                {label}
              </h2>
              <Marquee.row
                items={items}
                from="search"
                key={"search:" <> @query <> ":" <> label}
              >
                <:empty>No results.</:empty>
              </Marquee.row>
            </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
