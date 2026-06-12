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

  # Backoff schedule for retried rows. Picked so the user sees a quick
  # second attempt (most rows succeed on retry because the partial RT
  # data the first attempt collected is now warm in the cache), and
  # then progressively longer waits if something's actually broken
  # upstream. After the last attempt we stop retrying and the row
  # stays in the skeleton state — better to keep showing "loading"
  # than to commit to a misleading "no recommendations" message.
  @retry_delays_ms [2_000, 5_000, 12_000]

  def mount(_params, _session, socket) do
    services = Aviary.Discover.services()

    socket =
      socket
      |> assign(
        page_title: "Discover · Aviary",
        services: services,
        rows: %{},
        row_attempts: %{}
      )
      |> kick_off_row_fetches(services)

    {:ok, socket}
  end

  defp kick_off_row_fetches(socket, services) do
    Enum.reduce(services, socket, fn {label, network_id}, acc ->
      start_async(acc, {:row, label}, fn -> Aviary.Discover.fetch_row(network_id) end)
    end)
  end

  def handle_async({:row, label}, {:ok, items}, socket) when items != [] do
    {:noreply, update(socket, :rows, &Map.put(&1, label, items))}
  end

  # Empty result or task crash — both are "the row didn't actually
  # populate." Retry rather than stamping an empty list into the rows
  # map. Earlier behavior was to stamp empty on crash so the skeleton
  # stopped pulsing, but that left the user looking at "no
  # recommendations" for huge networks like Disney+ when the only
  # actual problem was a slow first attempt.
  def handle_async({:row, label}, {:ok, []}, socket), do: maybe_retry(socket, label)
  def handle_async({:row, label}, {:exit, _reason}, socket), do: maybe_retry(socket, label)

  defp maybe_retry(socket, label) do
    attempt = Map.get(socket.assigns.row_attempts, label, 0)

    case Enum.at(@retry_delays_ms, attempt) do
      nil ->
        # Out of retries — leave the row in skeleton state. User
        # can hard-refresh; we'd rather show "still loading" than
        # mislead with an empty-state message.
        {:noreply, socket}

      delay ->
        Process.send_after(self(), {:retry_row, label}, delay)
        {:noreply, update(socket, :row_attempts, &Map.put(&1, label, attempt + 1))}
    end
  end

  def handle_info({:retry_row, label}, socket) do
    case Enum.find(socket.assigns.services, fn {l, _} -> l == label end) do
      {^label, network_id} ->
        {:noreply,
         start_async(socket, {:row, label}, fn -> Aviary.Discover.fetch_row(network_id) end)}

      _ ->
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="discover"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
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
