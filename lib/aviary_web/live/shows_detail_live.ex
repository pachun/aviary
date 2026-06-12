defmodule AviaryWeb.ShowsDetailLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid
  alias AviaryWeb.Components.ReleaseCalendar
  alias AviaryWeb.Components.VideoPlayer

  def mount(%{"id" => id} = params, _session, socket) do
    case Aviary.Catalog.get_show(id, socket.assigns.current_user) do
      {:ok, show} ->
        {:ok,
         assign(socket,
           page_title: "#{show.title} · Aviary",
           show: show,
           playing_item: nil,
           kicker: kicker(params["from"])
         )}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Show not found")
         |> push_navigate(to: ~p"/shows")}
    end
  end

  defp kicker("home"), do: %{label: "Home", path: "/home"}
  defp kicker("movies"), do: %{label: "Movies", path: "/movies"}
  defp kicker(_), do: %{label: "Shows", path: "/shows"}

  def handle_event("play", _, socket) do
    item = pick_continue_episode(socket.assigns.show)
    {:noreply, assign(socket, :playing_item, item)}
  end

  def handle_event("play_episode", %{"id" => episode_id}, socket) do
    case find_episode(socket.assigns.show, episode_id) do
      nil -> {:noreply, socket}
      episode -> {:noreply, assign(socket, :playing_item, episode)}
    end
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, :playing_item, nil)}
  end

  def handle_event("report_progress", %{"position" => position}, socket) do
    item = socket.assigns.playing_item

    if item do
      position_ticks = trunc(position * 10_000_000)

      Aviary.Jellyfin.save_position(
        item.id,
        position_ticks,
        socket.assigns.current_user
      )

      # Mirror the in-memory resume_seconds on the corresponding episode
      # so the Continue button label stays accurate after closing.
      {:noreply, update(socket, :show, &update_episode_progress(&1, item.id, position))}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <article>
        <div class={[
          "grid grid-cols-1 md:grid-cols-[260px_1fr] gap-8 pt-4"
        ]}>
          <%!-- Poster (hidden on mobile, matches movie detail) --%>
          <div class="hidden md:block">
            <img
              src={"/image/#{@show.id}"}
              alt={@show.title}
              class="w-full aspect-[2/3] object-cover rounded-sm bg-rule"
            />
          </div>

          <div class="flex flex-col gap-4">
            <div class={[
              "grid grid-cols-1 gap-4 lg:gap-6 lg:items-start",
              upper_right_present?(@show) && "lg:grid-cols-[1fr_360px]"
            ]}>
              <div class="flex flex-col gap-4">
                <.link
                  navigate={@kicker.path}
                  class="w-fit font-sans text-xs tracking-[0.18em] uppercase font-medium px-5 py-2 rounded-sm border border-oxblood text-oxblood transition-colors hover:bg-oxblood/5 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                >
                  ← {@kicker.label}
                </.link>

                <h1
                  class="font-heading text-ink tracking-tight leading-[1.1]"
                  style="font-size: clamp(1.5rem, 2.5vw + 0.25rem, 2.5rem); font-variation-settings: 'opsz' 36;"
                >
                  {@show.title}
                </h1>

                <div class="font-sans text-[0.8rem] tracking-[0.14em] uppercase text-muted">
                  {metadata_line(@show)}
                </div>

                <CatalogGrid.rotten_tomatoes
                  :if={@show.rating}
                  rating={@show.rating}
                  center={false}
                />

                <div>
                  <button
                    type="button"
                    phx-click="play"
                    disabled={!has_episodes?(@show)}
                    class="bg-oxblood text-paper font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 disabled:opacity-40 disabled:cursor-not-allowed focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    {action_label(@show)}
                  </button>
                </div>
              </div>

              <%!--
                Upper-right slot: release calendar takes priority over
                trailer for in-rotation shows ("we're invested, the
                trailer is no longer interesting"). Falls back to
                trailer when no schedule is known — ended shows,
                between-seasons-with-no-premiere-announced, or any
                Jellyseerr lookup failure.
              --%>
              <div :if={@show.schedule != :none} class="w-full">
                <ReleaseCalendar.widget schedule={@show.schedule} />
              </div>

              <div
                :if={@show.schedule == :none && trailer_embeddable?(@show.trailer_url)}
                class="aspect-video w-full bg-rule rounded-sm overflow-hidden"
              >
                <iframe
                  src={trailer_embed_url(@show.trailer_url)}
                  class="w-full h-full"
                  allow="encrypted-media; picture-in-picture; fullscreen"
                  allowfullscreen
                  loading="lazy"
                  title={"#{@show.title} trailer"}
                >
                </iframe>
              </div>
            </div>

            <p
              :if={@show.synopsis && @show.synopsis != ""}
              class="font-display text-ink/85 text-base md:text-lg leading-relaxed pt-1"
              style="font-variation-settings: 'opsz' 14;"
            >
              {@show.synopsis}
            </p>
          </div>
        </div>

        <%!--
          Episodes list. Grouped by season, headers in small-caps,
          rows are minimal: episode number, title, runtime. Click a
          row → opens the player for that episode.
        --%>
        <section :if={has_episodes?(@show)} class="mt-12 md:mt-14">
          <div :for={{season, episodes} <- @show.episodes_by_season} class="mb-10 last:mb-0">
            <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-3">
              Season {season}
            </h2>
            <ul class="border-t border-rule">
              <li :for={ep <- episodes}>
                <button
                  type="button"
                  phx-click="play_episode"
                  phx-value-id={ep.id}
                  class="w-full flex items-center gap-4 py-3 px-1 border-b border-rule cursor-pointer hover:bg-rule/30 transition-colors text-left"
                >
                  <span class="font-sans text-muted text-sm tabular-nums w-8 shrink-0">
                    {pad_episode(ep.episode)}
                  </span>
                  <span class="font-display text-ink flex-1 truncate">{ep.title}</span>
                  <span
                    :if={ep.runtime_minutes}
                    class="font-sans text-muted text-xs tabular-nums shrink-0"
                  >
                    {ep.runtime_minutes}m
                  </span>
                </button>
              </li>
            </ul>
          </div>
        </section>
      </article>

      <VideoPlayer.overlay
        :if={@playing_item}
        item={@playing_item}
        current_user={@current_user}
        title={@show.title}
      />
    </Layouts.app>
    """
  end

  ## Helpers

  # "Drama · 5 seasons · TV-MA · 2018 – 2023" — drops parts that aren't
  # present so a show missing genre or rating doesn't get dangling
  # bullets.
  defp metadata_line(show) do
    [
      show.genre,
      seasons_text(show.season_count),
      show.official_rating,
      year_range(show.year)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp seasons_text(nil), do: nil
  defp seasons_text(0), do: nil
  defp seasons_text(1), do: "1 season"
  defp seasons_text(n), do: "#{n} seasons"

  defp year_range({start, nil}) when is_integer(start), do: "#{start} – present"
  defp year_range({start, finish}) when is_integer(start) and is_integer(finish), do: "#{start} – #{finish}"
  defp year_range(_), do: nil

  defp has_episodes?(show) do
    show.episodes_by_season != []
  end

  # Morphing label: "Resume S2 E4" / "Continue S3 E1" / "Play S1 E1"
  # based on whether the next-up episode has a saved position and
  # whether it's the very first episode of the series.
  defp action_label(%{next_up: nil} = show), do: first_episode_label(show)

  defp action_label(%{next_up: %{resume_seconds: r, season: s, episode: e}})
       when is_number(r) and r > 0 do
    "Resume S#{s} E#{e}"
  end

  defp action_label(%{next_up: %{season: s, episode: e}} = show) do
    case first_episode(show) do
      %{season: ^s, episode: ^e} -> first_episode_label(show)
      _ -> "Continue S#{s} E#{e}"
    end
  end

  # Uses the actual first episode's season/episode rather than
  # hardcoding "S1 E1" — libraries don't always start at season 1
  # (specials, partial libraries, late seasons only, etc.).
  defp first_episode_label(show) do
    case first_episode(show) do
      %{season: s, episode: e} -> "Play S#{s} E#{e}"
      _ -> "Play"
    end
  end

  # When NextUp returns nothing (never watched OR fully watched), play
  # the very first episode. If there's nothing at all, the button is
  # disabled so this never gets called.
  defp pick_continue_episode(show) do
    case show.next_up do
      nil -> first_episode(show)
      ep -> ep
    end
  end

  defp first_episode(show) do
    case show.episodes_by_season do
      [{_, [first | _]} | _] -> first
      _ -> nil
    end
  end

  defp find_episode(show, episode_id) do
    show.episodes_by_season
    |> Enum.flat_map(fn {_, eps} -> eps end)
    |> Enum.find(&(&1.id == episode_id))
  end

  # Mirror Catalog.@done_threshold — when the just-closed episode is
  # past this fraction, we advance the live next_up to the following
  # episode rather than leaving the button pointed at the credits.
  @done_fraction 0.90

  defp update_episode_progress(show, episode_id, position) do
    updated_episodes_by_season =
      Enum.map(show.episodes_by_season, fn {season, eps} ->
        {season,
         Enum.map(eps, fn ep ->
           if ep.id == episode_id, do: Map.put(ep, :resume_seconds, position), else: ep
         end)}
      end)

    flat = Enum.flat_map(updated_episodes_by_season, fn {_, eps} -> eps end)
    closed_ep = Enum.find(flat, &(&1.id == episode_id))

    # When the user closes a basically-done episode, advance to the
    # next one so the action_label reflects "Continue S1 E6" rather
    # than "Resume S1 E5" pointing at the credits they just closed.
    # When mid-watch (< 90%), keep next_up on the just-closed episode
    # for a resume target.
    next_up =
      cond do
        closed_ep && basically_done?(closed_ep, position) ->
          next_after_in(flat, episode_id) || closed_ep

        closed_ep ->
          closed_ep

        true ->
          show.next_up
      end

    show
    |> Map.put(:episodes_by_season, updated_episodes_by_season)
    |> Map.put(:next_up, next_up)
  end

  defp basically_done?(%{runtime_minutes: m}, position)
       when is_integer(m) and m > 0 and is_number(position) do
    position / (m * 60) >= @done_fraction
  end

  defp basically_done?(_, _), do: false

  defp next_after_in(flat, id) do
    flat
    |> Enum.drop_while(&(&1.id != id))
    |> case do
      [_current, next | _] -> next
      _ -> nil
    end
  end

  defp pad_episode(nil), do: ""
  defp pad_episode(n), do: "E" <> String.pad_leading(to_string(n), 2, "0")

  ## Trailer helpers (duplicate of MoviesDetailLive — small enough to
  ## not justify a shared module yet)

  defp upper_right_present?(show) do
    show.schedule != :none || trailer_embeddable?(show.trailer_url)
  end

  defp trailer_embeddable?(nil), do: false
  defp trailer_embeddable?(url) when is_binary(url), do: youtube_id(url) != nil
  defp trailer_embeddable?(_), do: false

  defp trailer_embed_url(url) do
    case youtube_id(url) do
      nil -> nil
      id -> "https://www.youtube.com/embed/#{id}?modestbranding=1&rel=0"
    end
  end

  defp youtube_id(url) when is_binary(url) do
    case Regex.run(~r/(?:v=|\/embed\/|youtu\.be\/)([A-Za-z0-9_-]{11})/, url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp youtube_id(_), do: nil
end
