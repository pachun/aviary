defmodule AviaryWeb.DailyWireLive do
  use AviaryWeb, :live_view

  alias Aviary.DailyWire
  alias AviaryWeb.Components.VideoPlayer

  def mount(_params, _session, socket) do
    if DailyWire.allowed?(socket.assigns.current_user) do
      {:ok,
       socket
       |> assign(page_title: "Daily Wire", shows: DailyWire.shows(), watching: nil, error: nil)
       |> assign(show: "the-ben-shapiro-show", next_page: nil, loading: true, empty: true)
       |> stream(:episodes, [])
       |> load_page(nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Daily Wire is not connected for this account.")
       |> push_navigate(to: ~p"/home")}
    end
  end

  def handle_event("choose_show", %{"show" => show}, socket) do
    if Enum.any?(DailyWire.shows(), &(&1.slug == show)) do
      {:noreply,
       socket
       |> assign(show: show, next_page: nil, error: nil, empty: true)
       |> stream(:episodes, [], reset: true)
       |> load_page(nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("load_more", _, %{assigns: %{loading: false, next_page: cursor}} = socket)
      when is_binary(cursor), do: {:noreply, load_page(socket, cursor)}

  def handle_event("load_more", _, socket), do: {:noreply, socket}

  def handle_event("retry", _, socket),
    do: {:noreply, load_page(socket, socket.assigns.next_page)}

  def handle_event("watch", %{"slug" => slug}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:error, nil)
     |> start_async(:playback, fn -> DailyWire.playback(user, slug) end)}
  end

  def handle_event("close_player", _, socket), do: {:noreply, assign(socket, :watching, nil)}
  def handle_event("report_progress", _, socket), do: {:noreply, socket}
  def handle_event("resync_position", _, socket), do: {:noreply, socket}
  def handle_event("subtitles_changed", _, socket), do: {:noreply, socket}

  def handle_async(:episodes, {:ok, {:ok, page}}, socket) do
    {:noreply,
     socket
     |> stream(:episodes, page.episodes)
     |> assign(
       next_page: page.nextPage,
       loading: false,
       error: nil,
       empty: socket.assigns.empty and page.episodes == []
     )}
  end

  def handle_async(:playback, {:ok, {:ok, playback}}, socket) do
    {:noreply,
     assign(socket, :watching, %{
       id: "daily-wire",
       title: playback.title,
       resume_seconds: 0,
       src: playback.streamUrl
     })}
  end

  def handle_async(task, {:ok, {:error, reason}}, socket) do
    message =
      if reason in [:reconnect, :not_connected],
        do: "Daily Wire needs to be reconnected on the server.",
        else:
          "Daily Wire could not load this #{if task == :playback, do: "video", else: "page"}. Try again."

    {:noreply, assign(socket, loading: false, error: message)}
  end

  def handle_async(_, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(_, {:exit, _}, socket) do
    {:noreply, assign(socket, loading: false, error: "Daily Wire is unavailable. Try again.")}
  end

  defp load_page(socket, cursor) do
    user = socket.assigns.current_user
    show = socket.assigns.show

    socket
    |> cancel_async(:episodes)
    |> assign(:loading, true)
    |> start_async(:episodes, fn -> DailyWire.episodes(user, show, cursor) end)
  end

  defp date(nil), do: ""
  defp date(timestamp), do: timestamp |> String.slice(0, 10)

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="daily_wire"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <div id="daily-wire" class="space-y-8">
        <div class="flex flex-wrap gap-6 border-b border-rule pb-4">
          <button
            :for={show <- @shows}
            id={"show-#{show.slug}"}
            phx-click="choose_show"
            phx-value-show={show.slug}
            aria-pressed={@show == show.slug}
            class={[
              "font-display text-xl cursor-pointer hover:text-oxblood focus-visible:outline-2 focus-visible:outline-oxblood",
              @show == show.slug && "text-oxblood",
              @show != show.slug && "text-muted"
            ]}
          >
            {show.title}
          </button>
        </div>
        <div :if={@error} role="alert" class="font-sans text-oxblood">
          {@error}
          <button id="daily-wire-retry" phx-click="retry" class="underline cursor-pointer ml-3">
            Retry
          </button>
        </div>
        <div
          id="daily-wire-episodes"
          phx-update="stream"
          class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-10"
        >
          <article :for={{id, episode} <- @streams.episodes} id={id}>
            <button
              phx-click="watch"
              phx-value-slug={episode.id}
              aria-label={"Play #{episode.title}"}
              class="group w-full text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-oxblood"
            >
              <img
                :if={episode.image}
                src={episode.image}
                alt=""
                loading="lazy"
                class="aspect-video w-full object-cover bg-rule"
              />
              <div class="flex justify-between gap-2 font-sans text-xs text-muted mt-3">
                <span>{date(episode.publishedAt)}</span>
                <span :if={episode.memberOnly}>Member exclusive</span>
              </div>
              <h2 class="font-display text-xl leading-snug mt-2 group-hover:text-oxblood">
                {episode.title}
              </h2>
              <p class="font-sans text-sm text-muted mt-2 line-clamp-2">{episode.description}</p>
              <span class="inline-block font-sans text-sm text-oxblood mt-3">Play</span>
            </button>
          </article>
        </div>
        <p :if={@loading} role="status" class="font-sans text-muted">Loading episodes…</p>
        <p :if={@empty && !@loading && !@error} class="font-sans text-muted">
          No episodes available.
        </p>
        <button
          :if={@next_page && !@loading}
          id="daily-wire-more"
          phx-click="load_more"
          class="font-sans border border-rule px-6 py-3 hover:text-oxblood cursor-pointer"
        >
          Older episodes
        </button>
      </div>
      <VideoPlayer.overlay
        :if={@watching}
        item={@watching}
        src={@watching.src}
        native_src={@watching.src}
        current_user={@current_user}
        title={@watching.title}
      />
    </Layouts.app>
    """
  end
end
