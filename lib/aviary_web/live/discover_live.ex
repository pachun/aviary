defmodule AviaryWeb.DiscoverLive do
  @moduledoc """
  Discover page — one marquee row per major streaming service. Each
  row loads independently via start_async/handle_async so the page
  paints immediately with skeleton placeholders and fills in row by
  row. Cold-cache load was 15s blocking before; now it's "page
  appears instantly, rows pop in as RT data lands."
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.Marquee

  def mount(_params, _session, socket) do
    services = Aviary.Discover.services()

    socket =
      socket
      |> assign(
        page_title: "Discover · Aviary",
        services: services,
        rows: %{}
      )
      |> kick_off_row_fetches(services)

    {:ok, socket}
  end

  defp kick_off_row_fetches(socket, services) do
    Enum.reduce(services, socket, fn {label, network_id}, acc ->
      start_async(acc, {:row, label}, fn -> Aviary.Discover.fetch_row(network_id) end)
    end)
  end

  def handle_async({:row, label}, {:ok, items}, socket) do
    {:noreply, update(socket, :rows, &Map.put(&1, label, items))}
  end

  def handle_async({:row, label}, {:exit, _reason}, socket) do
    # Task crashed; stamp an empty list so the skeleton stops pulsing
    # and the marquee's empty-slot message renders instead of leaving
    # the row in eternal loading state.
    {:noreply, update(socket, :rows, &Map.put(&1, label, []))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_section="discover" current_user={@current_user}>
      <section :for={{label, _id} <- @services} class="pt-4 first:pt-2 mb-10 last:mb-0">
        <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
          {label}
        </h2>
        <%= if items = Map.get(@rows, label) do %>
          <Marquee.row items={items} from="discover" key={"discover:" <> label}>
            <:empty>No recommendations available right now.</:empty>
          </Marquee.row>
        <% else %>
          <Marquee.skeleton />
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
