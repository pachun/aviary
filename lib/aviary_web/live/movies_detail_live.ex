defmodule AviaryWeb.MoviesDetailLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(%{"id" => id}, _session, socket) do
    case Aviary.Catalog.get_movie(id) do
      {:ok, movie} ->
        {:ok,
         assign(socket,
           page_title: "#{movie.title} · Aviary",
           movie: movie,
           playing: false
         )}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Movie not found")
         |> push_navigate(to: ~p"/movies")}
    end
  end

  def handle_event("play", _, socket) do
    {:noreply, assign(socket, :playing, true)}
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, :playing, false)}
  end

  # Hook reports every 10s while playing plus on every pause. Convert
  # seconds (what JS hands us) to Jellyfin's 100ns ticks, then save
  # directly to the user's UserData. Also live-update the in-memory
  # resume_seconds so if the user closes the player and the page
  # rerenders, the Resume button reflects the latest position without
  # a roundtrip back to Jellyfin.
  def handle_event("report_progress", %{"position" => position}, socket) do
    position_ticks = trunc(position * 10_000_000)
    Aviary.Jellyfin.save_position(socket.assigns.movie.id, position_ticks)
    {:noreply, update(socket, :movie, &Map.put(&1, :resume_seconds, position))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
          <div class="hidden md:block">
            <img
              src={"/image/#{@movie.id}"}
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
                  navigate={~p"/movies"}
                  class="w-fit font-sans text-xs tracking-[0.18em] uppercase font-medium px-5 py-2 rounded-sm border border-oxblood text-oxblood transition-colors hover:bg-oxblood/5 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                >
                  ← Movies
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
                  Play button lives with the decision-relevant info
                  (title, metadata, RT) rather than below the synopsis.
                  Keeps it above the fold and pairs it visually with the
                  RT scores it sits next to.
                --%>
                <div>
                  <button
                    type="button"
                    phx-click="play"
                    class="bg-oxblood text-paper font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm cursor-pointer transition-opacity hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
                  >
                    {if @movie.resume_seconds, do: "Resume", else: "Play"}
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

      <%!--
        Full-viewport player overlay. Mounted only when @playing is
        true; closing the overlay removes the <video> element entirely
        so the HLS stream is torn down (HlsPlayer hook's destroyed
        callback releases the player).

        Native browser <video> controls — gives us play/pause, seek,
        fullscreen, picture-in-picture, subtitle selection, and (in
        Safari) AirPlay automatically. `x-webkit-airplay="allow"` is
        the magic attribute Safari needs to show the AirPlay button.

        ESC and the close button both close the overlay. We don't close
        on backdrop click because the entire backdrop IS the video — a
        misclick on the player would yank the user out.
      --%>
      <div
        :if={@playing}
        class="fixed inset-0 z-50 bg-black flex items-center justify-center"
        phx-window-keydown="close_player"
        phx-key="Escape"
      >
        <video
          id={"player-#{@movie.id}"}
          phx-hook="HlsPlayer"
          data-src={Aviary.Jellyfin.hls_url(@movie.id)}
          data-resume-at={@movie.resume_seconds || 0}
          controls
          autoplay
          playsinline
          x-webkit-airplay="allow"
          class="w-full h-full max-w-screen max-h-screen object-contain"
        >
        </video>

        <button
          type="button"
          phx-click="close_player"
          aria-label="Close player"
          class="absolute top-4 right-4 z-10 font-sans text-xs tracking-[0.18em] uppercase font-medium text-white/80 hover:text-white cursor-pointer transition-colors px-4 py-2 rounded-sm bg-black/40 backdrop-blur-sm"
        >
          Close ✕
        </button>
      </div>
    </Layouts.app>
    """
  end

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
