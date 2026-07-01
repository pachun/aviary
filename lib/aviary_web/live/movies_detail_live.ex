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
        # If we landed here from /search, record the query as a
        # committed search — that click-through is the signal that
        # turns "you've got mai" debounce noise into "you've got
        # mail." See Aviary.RecentSearches for the why.
        Aviary.RecentSearches.record_if_from_search(
          socket.assigns.current_user.id,
          params
        )

        socket =
          socket
          |> assign(
            page_title: movie.title,
            movie: movie,
            playing_item: nil,
            playing_segments: nil,
            playing_subtitles: [],
            playing_audio_index: nil,
            kicker: kicker(params["from"], params["q"]),
            radarr_status: nil,
            imported_stuck_since: nil,
            in_library: in_library?(movie, socket.assigns.current_user),
            # Family Recommendations state — see shows_detail_live for
            # docs; movies use the same pattern with kind "movie".
            household_users: list_household_users(socket.assigns.current_user),
            recommenders: recommender_records(movie, socket.assigns.current_user),
            recommend_popover_open: false,
            recommend_popover_recipients: [],
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
        # 5s throttle matches our Radarr poll cadence — while the chip
        # is in "Importing…" Jellyfin should be rescanning continuously,
        # not stuck behind a 15s lull. Jellyfin dedupes concurrent
        # refreshes so faster polling is cheap.
        throttle(:jellyfin_library_refresh, 5_000, fn ->
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

  # Only library-resolved movies can be removed (a discover-source
  # movie isn't in the library to begin with). Mirrors the shows
  # implementation.
  defp in_library?(%{source: :library, tmdb_id: tmdb_id}, user) when is_binary(tmdb_id) do
    Aviary.Library.member?(user.id, tmdb_id)
  end

  defp in_library?(_, _), do: false

  # Household member list for the Recommend popover. Excludes self.
  defp list_household_users(current_user) do
    current_user
    |> Aviary.Jellyfin.list_users()
    |> Enum.reject(&(&1["Id"] == current_user.id))
    |> Enum.sort_by(&(&1["Name"] || ""))
  end

  defp recommender_phrase([%{"Name" => name}]),
    do: "#{name} thinks you'll like this."

  defp recommender_phrase([%{"Name" => a}, %{"Name" => b}]),
    do: "#{a} and #{b} think you'll like this."

  defp recommender_phrase(senders) when length(senders) > 2 do
    names = Enum.map(senders, & &1["Name"])
    {init, [last]} = Enum.split(names, length(names) - 1)
    "#{Enum.join(init, ", ")}, and #{last} think you'll like this."
  end

  defp recommender_phrase(_), do: ""

  defp recommender_records(movie, current_user) do
    case movie.tmdb_id do
      nil ->
        []

      tmdb_id ->
        sender_ids =
          Aviary.Recommendations.recommenders_for(current_user.id, tmdb_id, "movie")

        if sender_ids == [] do
          []
        else
          current_user
          |> Aviary.Jellyfin.list_users()
          |> Enum.filter(&(&1["Id"] in sender_ids))
        end
    end
  end

  # Resolve the kicker (back link above the title) from the `from`
  # query param. Default lands on the Movies tab of /library since
  # there's no movie-other natural landing place. Search preserves
  # the query so the user lands back on their results, not a blank
  # search screen.
  defp kicker("home", _), do: %{label: "Home", path: "/home"}
  defp kicker("discover", _), do: %{label: "Discover", path: "/discover"}
  defp kicker("library_shows", _), do: %{label: "Shows", path: "/library?type=shows"}

  defp kicker("search", q) when is_binary(q) and q != "",
    do: %{label: "Search", path: "/search?q=" <> URI.encode_www_form(q)}

  defp kicker("search", _), do: %{label: "Search", path: "/search"}
  defp kicker(_, _), do: %{label: "Movies", path: "/library?type=movies"}

  def handle_event("play", _, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    # Play is a commitment signal — add the movie to this user's
    # library so it shows up on /library?type=movies. Mirrors the
    # play / watch / sonarr-trigger paths in shows_detail_live.
    if movie.tmdb_id, do: Aviary.Library.add(user.id, movie.tmdb_id)

    # Resolve the audio track up front so Jellyfin doesn't pick an
    # audio-description stream as the default. See
    # Jellyfin.default_audio_index/1 for the heuristic.
    audio_streams = Aviary.Jellyfin.audio_streams(movie.id, user)
    audio_index = Aviary.Jellyfin.default_audio_index(audio_streams)

    {:noreply,
     socket
     |> assign(:in_library, true)
     |> assign(:playing_item, movie)
     |> assign(:playing_segments, Aviary.Jellyfin.segments(movie.id, user))
     |> assign(:playing_subtitles, Aviary.Jellyfin.subtitle_streams(movie.id, user))
     |> assign(:playing_audio_index, audio_index)}
  end

  def handle_event("watch", _, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    if in_progress?(movie_state(movie, socket.assigns.radarr_status, socket.assigns.download_seen)) do
      {:noreply, socket}
    else
      case Aviary.Radarr.watch_movie(movie.tmdb_id) do
        {:ok, _} ->
          # Sonarr-trigger equivalent: clicking Watch is the user's
          # commitment to this movie. Persist it before the optimistic
          # UI flash so the library page reflects it immediately.
          if movie.tmdb_id, do: Aviary.Library.add(user.id, movie.tmdb_id)

          {:noreply,
           socket
           # Mirror the DB write on the socket — without this, the
           # big CTA stays "Add to library" + "Watchable now" after
           # the download finishes because @in_library never flipped
           # to true on the LV's local state.
           |> assign(:in_library, true)
           |> fetch_radarr_status()
           |> put_flash(:info, "Grabbing #{movie.title}…")}

        _ ->
          {:noreply,
           put_flash(socket, :error, "Couldn't reach Radarr. Try again in a moment.")}
      end
    end
  end

  # Per-user library curation. See shows_detail's remove handler for
  # the full rationale — short version: stay on the detail page,
  # which now renders the "not in your library" state cleanly (big
  # Add-to-library CTA + Watchable now subtitle), so a redirect
  # somewhere else is unnecessary.
  def handle_event("remove_from_library", _, socket) do
    user = socket.assigns.current_user
    movie = socket.assigns.movie

    if movie.tmdb_id do
      Aviary.Library.remove(user.id, movie.tmdb_id, "movie")
    end

    {:noreply,
     socket
     |> assign(:in_library, false)
     |> Aviary.Nav.refresh_visibility()
     |> put_flash(:info, "#{movie.title} removed from your library.")}
  end

  def handle_event("add_to_library", _, socket) do
    user = socket.assigns.current_user
    movie = socket.assigns.movie

    if movie.tmdb_id do
      Aviary.Library.add(user.id, movie.tmdb_id)
    end

    {:noreply,
     socket
     |> assign(:in_library, true)
     |> Aviary.Nav.refresh_visibility()
     |> put_flash(:info, "#{movie.title} added to your library.")}
  end

  # === Family Recommendations on the movie detail page ===

  def handle_event("open_recommend_popover", _, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    recipients =
      if is_binary(movie.tmdb_id) do
        Aviary.Recommendations.recipients_for(user.id, movie.tmdb_id, "movie")
      else
        []
      end

    {:noreply,
     socket
     |> assign(:recommend_popover_open, true)
     |> assign(:recommend_popover_recipients, recipients)}
  end

  def handle_event("close_recommend_popover", _, socket) do
    {:noreply, assign(socket, :recommend_popover_open, false)}
  end

  def handle_event("send_recommendation", %{"to" => to_user_id}, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    if is_binary(movie.tmdb_id) and to_user_id != user.id do
      Aviary.Recommendations.recommend(user.id, to_user_id, movie.tmdb_id, "movie")
    end

    recipients = [to_user_id | socket.assigns.recommend_popover_recipients] |> Enum.uniq()

    {:noreply,
     socket
     |> assign(:recommend_popover_recipients, recipients)
     |> put_flash(:info, "Recommended.")}
  end

  def handle_event("dismiss_recommendation_detail", _, socket) do
    movie = socket.assigns.movie
    user = socket.assigns.current_user

    if is_binary(movie.tmdb_id) do
      Aviary.Recommendations.dismiss(user.id, movie.tmdb_id, "movie")
    end

    {:noreply,
     socket
     |> assign(:recommenders, [])
     |> Aviary.Nav.refresh_visibility()}
  end

  def handle_event("close_player", _, socket) do
    # Refresh nav_visibility — playing this movie added a
    # library_entries row + flipped Jellyfin's Continue Watching
    # state. Without this the user closes the player and sees the
    # same "no Library / no Home tab" nav they started with until
    # they navigate to trigger a fresh mount.
    {:noreply,
     socket
     |> assign(:playing_item, nil)
     |> assign(:playing_segments, nil)
     |> assign(:playing_subtitles, [])
     |> assign(:playing_audio_index, nil)
     |> Aviary.Nav.refresh_visibility()}
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

    case Aviary.Jellyfin.report_progress(item.id, position, payload["duration"], user) do
      :played ->
        {:noreply, update(socket, :movie, &Map.put(&1, :resume_seconds, nil))}

      :in_progress ->
        {:noreply, update(socket, :movie, &Map.put(&1, :resume_seconds, position))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_visibility={@nav_visibility}
      current_section={String.downcase(@kicker.label)}
      mobile_title={@movie.title}
      mobile_back_to={@kicker.path}
      mobile_back_label={@kicker.label}
    >
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

                <%!-- Family recommendation note — see shows_detail. --%>
                <div :if={@recommenders != []} class="flex items-center gap-2 -mt-1">
                  <div class="flex flex-row-reverse">
                    <span
                      :for={r <- @recommenders}
                      class="size-7 -ml-2 rounded-full ring-2 ring-paper bg-rule overflow-hidden flex items-center justify-center text-ink font-display text-xs"
                    >
                      <img
                        :if={r["PrimaryImageTag"]}
                        src={"/user-image/#{r["Id"]}?tag=#{r["PrimaryImageTag"]}"}
                        alt={r["Name"]}
                        class="w-full h-full object-cover"
                      />
                      <span :if={!r["PrimaryImageTag"]}>
                        {r["Name"] |> String.first() |> String.upcase()}
                      </span>
                    </span>
                  </div>
                  <p class="font-display italic text-muted text-sm leading-tight">
                    {recommender_phrase(@recommenders)}
                  </p>
                </div>

                <%!--
                  Title scaled down from the previous hero clamp because
                  the poster already says what this is — the text serves
                  as a confirming label, not a competing headline. Reads
                  more museum-object-label than magazine-front-page.
                --%>
                <h1
                  data-mobile-top-bar-trigger
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
                <div class="space-y-2">
                  <%!--
                    See shows_detail's call site for full context. Big
                    CTA is "Add to library" when this movie isn't in
                    the user's library yet, regardless of whether the
                    files are downloaded — the only thing that changes
                    is the subtitle below. The click handler swaps too:
                    `add_to_library` for downloaded-but-not-saved (just
                    persist the row, no Radarr roundtrip) vs `watch`
                    for discover (trigger the Radarr request).
                  --%>
                  <.movie_action_button
                    movie={@movie}
                    state={movie_state(@movie, @radarr_status, @download_seen)}
                    label={movie_action_label(@movie, @in_library)}
                    click_event={movie_action_click_event(@movie, @in_library)}
                  />
                  <p
                    :if={
                      subtitle =
                        movie_subtitle_label(
                          @movie,
                          @radarr_status,
                          @download_seen,
                          @in_library
                        )
                    }
                    class="font-display italic text-muted text-xs"
                  >
                    {subtitle}
                  </p>
                </div>

                <%!--
                  Library curation: Remove (when in library) or Add
                  (when not). Mirrors the shows side — same chip
                  treatment + same hover semantics (Add → oxblood
                  invitation, Remove → neutral ink).
                --%>
                <%!-- "Add to library" chip removed — big CTA owns it. --%>
                <div :if={@movie.source == :library and @movie.tmdb_id} class="mt-1 flex flex-wrap gap-2 items-center">
                  <button
                    :if={@in_library}
                    type="button"
                    phx-click="remove_from_library"
                    data-confirm={"Remove #{@movie.title} from your library?"}
                    class="font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium px-3 py-1.5 rounded-sm border border-ink/30 text-ink/80 hover:border-ink hover:text-ink hover:bg-ink/5 cursor-pointer transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ink/30 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    Remove from library
                  </button>
                  <button
                    :if={@household_users != []}
                    type="button"
                    phx-click="open_recommend_popover"
                    class="font-sans text-[0.7rem] tracking-[0.18em] uppercase font-medium px-3 py-1.5 rounded-sm border border-ink/30 text-ink/80 hover:border-oxblood hover:text-oxblood hover:bg-oxblood/5 cursor-pointer transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    Recommend to family
                  </button>
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

      <%!--
        Recommend popover — see shows_detail_live for behavior docs.
      --%>
      <div
        :if={@recommend_popover_open}
        class="fixed inset-0 z-50 flex items-center justify-center px-4"
      >
        <%!--
          Backdrop owns the close-on-click. Modal box deliberately has
          no phx-click of its own — that's what lets buttons inside it
          fire their own phx-click handlers cleanly.
        --%>
        <div
          class="absolute inset-0 bg-ink/60 backdrop-blur-sm cursor-pointer"
          phx-click="close_recommend_popover"
          aria-label="Close"
        >
        </div>
        <div class="relative z-10 w-full max-w-sm bg-paper rounded-sm shadow-xl border border-rule p-6">
          <div class="flex items-baseline justify-between mb-4">
            <p class="font-sans text-[0.7rem] tracking-[0.18em] uppercase text-muted">
              Recommend to
            </p>
            <button
              type="button"
              phx-click="close_recommend_popover"
              aria-label="Close"
              class="text-muted hover:text-ink cursor-pointer transition-colors text-sm leading-none"
            >
              ✕
            </button>
          </div>
          <ul class="flex flex-col">
            <li :for={u <- @household_users} class="border-b border-rule last:border-b-0">
              <button
                type="button"
                phx-click="send_recommendation"
                phx-value-to={u["Id"]}
                disabled={u["Id"] in @recommend_popover_recipients}
                class="w-full flex items-center gap-3 py-3 px-1 text-left transition-colors hover:bg-rule/30 disabled:hover:bg-transparent disabled:cursor-default cursor-pointer focus:outline-none focus-visible:bg-rule/30"
              >
                <span class="size-9 rounded-full bg-rule overflow-hidden flex items-center justify-center text-ink font-display text-xs shrink-0">
                  <img
                    :if={u["PrimaryImageTag"]}
                    src={"/user-image/#{u["Id"]}?tag=#{u["PrimaryImageTag"]}"}
                    alt={u["Name"]}
                    class="w-full h-full object-cover"
                  />
                  <span :if={!u["PrimaryImageTag"]}>
                    {u["Name"] |> String.first() |> String.upcase()}
                  </span>
                </span>
                <span class="font-display text-ink text-base flex-1 truncate">
                  {u["Name"]}
                </span>
                <span
                  :if={u["Id"] in @recommend_popover_recipients}
                  class="font-sans text-[0.65rem] tracking-[0.18em] uppercase text-oxblood"
                >
                  Sent
                </span>
                <span
                  :if={u["Id"] not in @recommend_popover_recipients}
                  class="font-sans text-[0.65rem] tracking-[0.18em] uppercase text-muted"
                >
                  Send
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Top-of-page action button. Label + click_event are passed in so
  # the call site can swap between "Play"/"Resume" + `play` (in-library
  # downloaded), "Add to library" + `add_to_library` (downloaded but
  # not in this user's library), and "Add to library" + `watch` (not
  # downloaded — triggers Radarr). The transitional states still
  # render their own status pills regardless.
  attr :movie, :map, required: true
  attr :state, :any, required: true
  attr :label, :string, required: true
  attr :click_event, :string, required: true

  defp movie_action_button(assigns) do
    ~H"""
    <%= case @state do %>
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
          phx-click={@click_event}
          class="bg-oxblood text-white font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
        >
          {@label}
        </button>
    <% end %>
    """
  end

  # Extract Radarr's queue.timeleft as seconds, or nil if there's no
  # queue record yet. See Aviary.WatchProgress for the parser.
  defp movie_timeleft_seconds(%{queue: %{"timeleft" => t}}),
    do: Aviary.WatchProgress.parse_timeleft(t)

  defp movie_timeleft_seconds(_), do: nil

  # Big CTA label. When the movie is in the user's library AND has
  # files, fall back to the Play/Resume affordance. Otherwise the
  # label is always "Add to library" — same vocabulary whether the
  # files are on disk yet or not.
  defp movie_action_label(%{resume_seconds: r}, true) when is_number(r) and r > 0, do: "Resume"
  defp movie_action_label(_movie, true), do: "Play"
  defp movie_action_label(_movie, false), do: "Add to library"

  # Click event paired with the label. Discover-source movies trigger
  # Radarr via `watch`; library-source movies that the user hasn't
  # added yet just persist the library_entries row via
  # `add_to_library`. In-library + playable goes through `play`.
  defp movie_action_click_event(_movie, true), do: "play"
  defp movie_action_click_event(%{source: :library}, false), do: "add_to_library"
  defp movie_action_click_event(_movie, false), do: "watch"

  # Subtitle under the big CTA. When not in user library + already
  # downloaded → "Watchable now"; otherwise the regular progress
  # label (returns nil for :playable so in-library shows no label).
  defp movie_subtitle_label(%{source: :library}, _status, _seen, false), do: "Watchable now"

  defp movie_subtitle_label(movie, status, seen, _in_library) do
    Aviary.WatchProgress.label(
      movie_state(movie, status, seen),
      movie.runtime_minutes,
      movie_timeleft_seconds(status)
    )
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

  # Download is done — qBit handed the file off and Radarr is mid-
  # import. Without this clause, the chip sits at "100%" for the
  # entire import window (file move + Jellyfin scan), which reads
  # as "something is stuck." Skip straight to `:imported` so the
  # chip shows "Importing…" instead. Mirrors the shows-side
  # queue_record_state pattern.
  def movie_state(_movie, %{queue: %{"size" => size, "sizeleft" => 0}}, _seen)
      when is_number(size) and size > 0,
      do: :imported

  def movie_state(_movie, %{queue: %{"size" => size, "sizeleft" => left}}, _seen)
      when is_number(size) and is_number(left) and size > 0 and left > 0 do
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
