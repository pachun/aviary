defmodule AviaryWeb.MoviesDetailLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid
  alias AviaryWeb.Components.VideoPlayer

  # Mirrors @sonarr_poll_ms in ShowsDetailLive. Five seconds is the
  # sweet spot between "the page feels alive" and "we're not hammering
  # Radarr." Polling stops when the LV dies.
  @radarr_poll_ms 5_000

  def mount(%{"id" => id} = params, _session, socket) do
    case Aviary.Catalog.get_movie(id, socket.assigns.current_user) do
      {:ok, movie} ->
        socket =
          socket
          |> assign(
            page_title: "#{movie.title} · Aviary",
            movie: movie,
            playing_item: nil,
            playing_segments: nil,
            playing_subtitles: [],
            playing_audio_index: nil,
            kicker: kicker(params["from"], params["q"]),
            radarr_status: nil,
            imported_stuck_since: nil,
            # Latches true the first time we observe the movie actively
            # downloading. Once latched, a transient queue-gone +
            # has_file=false state is read as :imported instead of
            # :searching — Radarr clears the queue record briefly
            # before flipping hasFile=true, and that gap was making
            # the chip flicker back to "Searching…" between 100% and
            # "Importing…".
            download_seen: false
          )
          |> fetch_radarr_status()
          |> schedule_radarr_poll()

        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Movie not found")
         |> push_navigate(to: ~p"/library?type=movies")}
    end
  end

  def handle_info(:poll_radarr, socket) do
    {:noreply,
     socket
     |> fetch_radarr_status()
     |> refresh_movie_if_imported()
     |> schedule_radarr_poll()}
  end

  # Side-effects that piggyback on the Radarr poll — same shape as
  # ShowsDetailLive.refresh_show_if_imported but per-movie:
  #
  #   * Active download → kick Radarr to refresh qBit progress now.
  #     Radarr's own RefreshMonitoredDownloads fires every ~90s; this
  #     nudge keeps the chip moving smoothly.
  #
  #   * Radarr has the file but Jellyfin doesn't → trigger a
  #     library-wide Jellyfin refresh. Throttled so a multi-second poll
  #     cadence doesn't pile up. Once Jellyfin picks up the file, the
  #     next get_movie call resolves the TMDB id to a Jellyfin id and
  #     the page flips to the library Play view automatically.
  defp refresh_movie_if_imported(socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    state =
      movie_state(movie, socket.assigns.radarr_status, socket.assigns.download_seen)

    cond do
      match?({:downloading, _}, state) ->
        throttle({:radarr_dl_refresh, movie.id}, 5_000, fn ->
          Aviary.Radarr.refresh_monitored_downloads()
        end)

        assign(socket, :download_seen, true)

      state == :imported ->
        throttle(:jellyfin_library_refresh, 15_000, fn ->
          Aviary.Jellyfin.refresh_library(user)
        end)

        # Force-invalidate the movies cache and re-resolve via Catalog
        # so the moment Jellyfin sees the file, this LV swaps to the
        # library view. The TMDB id stays as the URL token; resolve
        # finds the Jellyfin counterpart and Catalog returns a
        # source: :library shape.
        Aviary.Cache.invalidate({:jellyfin_list_movies, user.id})

        case Aviary.Catalog.get_movie(movie.tmdb_id || movie.id, user) do
          {:ok, refreshed} -> assign(socket, :movie, refreshed)
          _ -> socket
        end

      true ->
        assign(socket, :imported_stuck_since, nil)
    end
  end

  defp throttle(key, cooldown_ms, fun) do
    Aviary.Cache.fetch(key, cooldown_ms, fn ->
      fun.()
      :stamped
    end)

    :ok
  end

  defp fetch_radarr_status(socket) do
    status =
      case socket.assigns.movie do
        # No point asking Radarr about a movie Jellyfin already has —
        # the file is here, we're done. Skipping also keeps a misconfigured
        # Radarr (or no Radarr at all) from spamming the warning log on
        # every library-movie page load.
        %{source: :library} ->
          nil

        %{tmdb_id: tmdb_id} when is_binary(tmdb_id) ->
          case Aviary.Radarr.movie_status(tmdb_id) do
            {:ok, status} -> status
            _ -> nil
          end

        _ ->
          nil
      end

    assign(socket, :radarr_status, status)
  end

  defp schedule_radarr_poll(socket) do
    if connected?(socket) and poll_needed?(socket) do
      Process.send_after(self(), :poll_radarr, @radarr_poll_ms)
    end

    socket
  end

  # Stop polling once the movie is playable — there's nothing more for
  # Radarr to tell us, and the LV stays inert until the user navigates
  # away.
  defp poll_needed?(socket) do
    socket.assigns.movie.source == :discover
  end

  # Resolve the kicker (back link above the title) from the `from`
  # query param. Default lands on the Movies tab of /library since
  # there's no movie-other natural landing place. Search preserves
  # the query so the user lands back on their results, not a blank
  # search screen.
  defp kicker("home", _), do: %{label: "Home", path: "/home"}
  defp kicker("discover", _), do: %{label: "Discover", path: "/discover"}
  defp kicker("library_shows", _), do: %{label: "Library", path: "/library?type=shows"}

  defp kicker("search", q) when is_binary(q) and q != "",
    do: %{label: "Search", path: "/search?q=" <> URI.encode_www_form(q)}

  defp kicker("search", _), do: %{label: "Search", path: "/search"}
  defp kicker(_, _), do: %{label: "Library", path: "/library?type=movies"}

  def handle_event("play", _, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    # Resolve the audio track up front so Jellyfin doesn't pick an
    # audio-description stream as the default. See
    # Jellyfin.default_audio_index/1 for the heuristic.
    audio_streams = Aviary.Jellyfin.audio_streams(movie.id, user)
    audio_index = Aviary.Jellyfin.default_audio_index(audio_streams)

    {:noreply,
     socket
     |> assign(:playing_item, movie)
     |> assign(:playing_segments, Aviary.Jellyfin.segments(movie.id, user))
     |> assign(:playing_subtitles, Aviary.Jellyfin.subtitle_streams(movie.id, user))
     |> assign(:playing_audio_index, audio_index)}
  end

  def handle_event("watch", _, socket) do
    movie = socket.assigns.movie

    if in_progress?(movie_state(movie, socket.assigns.radarr_status, socket.assigns.download_seen)) do
      {:noreply, socket}
    else
      case Aviary.Radarr.watch_movie(movie.tmdb_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> fetch_radarr_status()
           |> put_flash(:info, "Grabbing #{movie.title}…")}

        _ ->
          {:noreply,
           put_flash(socket, :error, "Couldn't reach Radarr. Try again in a moment.")}
      end
    end
  end

  def handle_event("close_player", _, socket) do
    {:noreply,
     socket
     |> assign(:playing_item, nil)
     |> assign(:playing_segments, nil)
     |> assign(:playing_subtitles, [])
     |> assign(:playing_audio_index, nil)}
  end

  # Hook reports every 10s while playing plus on every pause. Convert
  # seconds (what JS hands us) to Jellyfin's 100ns ticks, then save
  # directly to the user's UserData. Also live-update the in-memory
  # resume_seconds so if the user closes the player and the page
  # rerenders, the Resume button reflects the latest position without
  # a roundtrip back to Jellyfin.
  def handle_event("report_progress", %{"position" => position} = payload, socket) do
    item = socket.assigns.playing_item
    user = socket.assigns.current_user
    duration = payload["duration"]

    # Past 95% of the runtime = effectively done. mark_played
    # (canonical endpoint + position zero) keeps Jellyfin's
    # Resume/NextUp from treating the movie as still in-progress.
    if is_number(duration) and duration > 0 and position / duration >= 0.95 do
      Aviary.Jellyfin.mark_played(item.id, user)
      {:noreply, update(socket, :movie, &Map.put(&1, :resume_seconds, nil))}
    else
      position_ticks = trunc(position * 10_000_000)
      Aviary.Jellyfin.save_position(item.id, position_ticks, user)
      {:noreply, update(socket, :movie, &Map.put(&1, :resume_seconds, position))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} nav_visibility={@nav_visibility}>
      <article>
        <div class="grid grid-cols-1 md:grid-cols-[260px_1fr] gap-8 pt-4">
          <%!--
            Poster only shows on tablet and up. On phone the 2:3 aspect
            takes the entire viewport and pushes the kicker / title /
            metadata / RT / trailer below the fold — the YouTube
            thumbnail and the title in Newsreader carry enough visual
            identity on mobile that the poster's aesthetic contribution
            isn't worth its real-estate cost there.
          --%>
          <%!--
            poster_url is set by Catalog.get_movie — for library movies
            it's the aviary image proxy keyed by Jellyfin id; for
            discover movies (Search hits) it's the TMDB CDN via our
            disk-cached proxy. Same field, same render, source
            abstracted away — mirrors how show detail does it.
          --%>
          <div class="hidden md:block">
            <img
              src={@movie.poster_url}
              alt={@movie.title}
              class="w-full aspect-[2/3] object-cover rounded-sm bg-rule"
            />
          </div>

          <div class="flex flex-col gap-4">
            <%!--
              Top section. At lg+, splits into two columns: text info
              on the left (kicker/title/metadata/RT) and the trailer
              on the right. Below lg they stack — text info on top,
              trailer below it. The split only happens when there's
              actually a trailer; otherwise stays single column so
              there's no dead 360px space on the right.
            --%>
            <div class={[
              "grid grid-cols-1 gap-4 lg:gap-6 lg:items-start",
              trailer_embeddable?(@movie.trailer_url) && "lg:grid-cols-[1fr_360px]"
            ]}>
              <div class="flex flex-col gap-4">
                <%!--
                  Back link, styled as the outlined sibling of the
                  Play button below. Same typographic family (Instrument
                  Sans, small caps, tracking, font-medium, rounded-sm)
                  and same oxblood color — differentiated by outline vs
                  fill and slightly smaller size, signaling secondary
                  action. Forms a coherent button family with Play.
                --%>
                <.link
                  navigate={@kicker.path}
                  class="w-fit font-sans text-xs tracking-[0.18em] uppercase font-medium px-5 py-2 rounded-sm border border-oxblood text-oxblood transition-colors hover:bg-oxblood/5 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                >
                  ← {@kicker.label}
                </.link>

                <%!--
                  Title scaled down from the previous hero clamp because
                  the poster already says what this is — the text serves
                  as a confirming label, not a competing headline. Reads
                  more museum-object-label than magazine-front-page.
                --%>
                <h1
                  class="font-heading text-ink tracking-tight leading-[1.1]"
                  style="font-size: clamp(1.5rem, 2.5vw + 0.25rem, 2.5rem); font-variation-settings: 'opsz' 36;"
                >
                  {@movie.title}
                </h1>

                <div class="font-sans text-[0.8rem] tracking-[0.14em] uppercase text-muted">
                  {metadata_line(@movie)}
                </div>

                <CatalogGrid.rotten_tomatoes
                  :if={@movie.rating}
                  rating={@movie.rating}
                  center={false}
                />

                <%!--
                  Library: Play (or Resume). Discover: one of Watch /
                  Searching… / {pct}% / Importing… driven by
                  movie_state(movie, radarr_status). Same geometry
                  across every state so the layout never shifts as
                  the state machine progresses.
                --%>
                <div>
                  <.movie_action_button
                    movie={@movie}
                    state={movie_state(@movie, @radarr_status, @download_seen)}
                  />
                </div>
              </div>

              <div
                :if={trailer_embeddable?(@movie.trailer_url)}
                class="aspect-video w-full bg-rule rounded-sm overflow-hidden"
              >
                <iframe
                  src={trailer_embed_url(@movie.trailer_url)}
                  class="w-full h-full"
                  allow="encrypted-media; picture-in-picture; fullscreen"
                  allowfullscreen
                  loading="lazy"
                  title={"#{@movie.title} trailer"}
                >
                </iframe>
              </div>
            </div>

            <p
              :if={@movie.synopsis && @movie.synopsis != ""}
              class="font-display text-ink/85 text-base md:text-lg leading-relaxed pt-1"
              style="font-variation-settings: 'opsz' 14;"
            >
              {@movie.synopsis}
            </p>
          </div>
        </div>
      </article>

      <VideoPlayer.overlay
        :if={@playing_item}
        item={@playing_item}
        current_user={@current_user}
        title={@movie.title}
        segments={@playing_segments}
        subtitles={@playing_subtitles}
        audio_stream_index={@playing_audio_index}
      />
    </Layouts.app>
    """
  end

  # Top-of-page action button — Play for library, the Radarr state
  # machine for discover. Mirrors top_action_button/1 in
  # ShowsDetailLive but for a movie (no Resume vs Continue branching,
  # no caught-up special case).
  attr :movie, :map, required: true
  attr :state, :any, required: true

  defp movie_action_button(assigns) do
    ~H"""
    <%= case @state do %>
      <% :playable -> %>
        <button
          type="button"
          phx-click="play"
          class="bg-oxblood text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
        >
          {if @movie.resume_seconds, do: "Resume", else: "Play"}
        </button>
      <% {:downloading, pct} -> %>
        <div class="relative overflow-hidden inline-block bg-oxblood/20 text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm tabular-nums">
          <span
            class="absolute inset-y-0 left-0 bg-oxblood transition-all duration-700 ease-out"
            style={"width: #{pct}%"}
          >
          </span>
          <span class="relative">{pct}%</span>
        </div>
      <% :searching -> %>
        <div class="inline-block bg-oxblood/40 text-white/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Searching…
        </div>
      <% :imported -> %>
        <div class="inline-block bg-oxblood/40 text-white/80 font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm">
          Importing…
        </div>
      <% _ -> %>
        <button
          type="button"
          phx-click="watch"
          class="bg-oxblood text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
        >
          Watch
        </button>
    <% end %>
    """
  end

  ## State machine

  # Resolves the current movie to one of:
  #   :playable          — Jellyfin has the file, click plays it
  #   :imported          — Radarr has the file, Jellyfin doesn't yet
  #   {:downloading, n}  — actively downloading, n% complete
  #   :searching         — Radarr is monitoring + has no release yet
  #   :ready             — not yet in Radarr; click triggers Watch
  def movie_state(movie, status, download_seen \\ false)
  def movie_state(%{source: :library}, _status, _seen), do: :playable
  def movie_state(_movie, nil, _seen), do: :ready
  def movie_state(_movie, %{has_file: true}, _seen), do: :imported

  def movie_state(_movie, %{queue: %{"size" => size, "sizeleft" => left}}, _seen)
      when is_number(size) and is_number(left) and size > 0 do
    {:downloading, round((size - left) / size * 100)}
  end

  def movie_state(_movie, %{queue: %{}}, _seen), do: {:downloading, 0}

  # Once we've watched the download progress this session, queue=nil
  # + has_file=false is the post-download import gap (Radarr clears
  # the queue record briefly before flipping hasFile). Render it as
  # :imported instead of :searching so the chip doesn't flicker back
  # to "Searching…" between 100% and "Importing…".
  def movie_state(_movie, %{monitored: true}, true), do: :imported
  def movie_state(_movie, %{monitored: true}, _seen), do: :searching
  def movie_state(_movie, _status, _seen), do: :ready

  defp in_progress?(:searching), do: true
  defp in_progress?({:downloading, _}), do: true
  defp in_progress?(:imported), do: true
  defp in_progress?(_), do: false

  # Builds the comma-bullet metadata string: "Adventure · 3h 28m ·
  # PG-13 · 2001". Each part is included only when present; the join
  # handles the separators so we never get leading/trailing bullets
  # or doubled-up dots when something's missing.
  defp metadata_line(movie) do
    [
      movie.genre,
      movie.runtime_minutes && format_runtime(movie.runtime_minutes),
      movie.official_rating,
      movie.year && to_string(movie.year)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Format like "3h 28m" / "1h 30m" / "47m". No leading zeros, no colons,
  # no seconds.
  defp format_runtime(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    cond do
      hours > 0 -> "#{hours}h #{mins}m"
      true -> "#{mins}m"
    end
  end

  # Whether to render the inline trailer section. Currently only YouTube
  # URLs embed cleanly; non-YouTube trailers (Vimeo, direct video files,
  # etc.) yield no trailer section rather than a broken embed.
  defp trailer_embeddable?(nil), do: false
  defp trailer_embeddable?(url) when is_binary(url), do: youtube_id(url) != nil
  defp trailer_embeddable?(_), do: false

  # Standard youtube.com/embed (not -nocookie) — the -nocookie domain
  # deliberately ignores the viewer's session cookies, which would lose
  # YouTube Premium recognition and force ads despite paying. Regular
  # /embed respects your signed-in session. No autoplay param because
  # the trailer is now embedded inline and shouldn't start playing on
  # page load.
  defp trailer_embed_url(url) do
    case youtube_id(url) do
      nil ->
        nil

      id ->
        "https://www.youtube.com/embed/#{id}?modestbranding=1&rel=0"
    end
  end

  # Extracts the 11-character YouTube video ID from any of the
  # common URL shapes: youtube.com/watch?v=, youtu.be/, /embed/.
  defp youtube_id(url) when is_binary(url) do
    case Regex.run(~r/(?:v=|\/embed\/|youtu\.be\/)([A-Za-z0-9_-]{11})/, url) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp youtube_id(_), do: nil
end
