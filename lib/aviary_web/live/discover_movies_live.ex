defmodule AviaryWeb.DiscoverMoviesLive do
  @moduledoc """
  Discover Movies — well-liked movies you can watch at home today, from
  `Aviary.DiscoverMovies`. Each row loads independently, like Discover
  TV: labels and skeletons paint at once and rows fill as their ratings
  land. A row that comes back with nothing to show is dropped; one that
  fails is retried a few times before it is dropped too.
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  @retry_delays_ms [2_000, 5_000, 12_000]

  def mount(_params, _session, socket) do
    if Aviary.OnThisServer.all_there_is?(),
      do: {:ok, show_movies_on_this_server(socket)},
      else: {:ok, browse_movies_worth_watching(socket)}
  end

  defp show_movies_on_this_server(socket) do
    rows = Aviary.OnThisServer.movie_rows(socket.assigns.current_user)

    assign(socket,
      page_title: "Discover Movies",
      row_list: Enum.map(rows, fn {label, _items} -> {label, nil} end),
      rows: Map.new(rows),
      row_attempts: %{}
    )
  end

  defp browse_movies_worth_watching(socket) do
    row_list = Aviary.DiscoverMovies.rows(socket.assigns.current_user)

    socket
    |> assign(page_title: "Discover Movies", row_list: row_list, rows: %{}, row_attempts: %{})
    |> then(fn socket -> Enum.reduce(row_list, socket, &fetch_row/2) end)
  end

  defp fetch_row({label, row}, socket),
    do: start_async(socket, {:row, label}, fn -> Aviary.DiscoverMovies.fetch_row(row) end)

  def handle_async({:row, label}, {:ok, []}, socket), do: {:noreply, drop_row(socket, label)}

  def handle_async({:row, label}, {:ok, items}, socket),
    do: {:noreply, update(socket, :rows, &Map.put(&1, label, items))}

  def handle_async({:row, label}, {:exit, _reason}, socket) do
    attempt = Map.get(socket.assigns.row_attempts, label, 0)

    case Enum.at(@retry_delays_ms, attempt) do
      nil ->
        {:noreply, drop_row(socket, label)}

      delay ->
        Process.send_after(self(), {:retry_row, label}, delay)
        {:noreply, update(socket, :row_attempts, &Map.put(&1, label, attempt + 1))}
    end
  end

  def handle_info({:retry_row, label}, socket) do
    case List.keyfind(socket.assigns.row_list, label, 0) do
      {^label, _row} = entry -> {:noreply, fetch_row(entry, socket)}
      nil -> {:noreply, socket}
    end
  end

  defp drop_row(socket, label),
    do: update(socket, :row_list, &List.keydelete(&1, label, 0))

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="discover_movies"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <div class="pt-2 space-y-12">
        <section :for={{label, _row} <- @row_list}>
          <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
            {label}
          </h2>
          <%= if items = Map.get(@rows, label) do %>
            <Marquee.row items={items} from="discover_movies" key={"discover_movies:" <> label}>
              <:empty>Nothing to show right now.</:empty>
            </Marquee.row>
          <% else %>
            <Marquee.skeleton />
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
