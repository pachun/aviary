defmodule AviaryWeb.MoviesDetailLive do
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.CatalogGrid

  def mount(%{"id" => id}, _session, socket) do
    case Aviary.Catalog.get_movie(id) do
      {:ok, movie} ->
        {:ok,
         assign(socket,
           page_title: "#{movie.title} · Aviary",
           movie: movie
         )}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Movie not found")
         |> push_navigate(to: ~p"/movies")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article>
        <div class="grid md:grid-cols-[260px_1fr] lg:grid-cols-[300px_1fr] gap-8 md:gap-12 pt-4">
          <div class="w-full max-w-[300px] mx-auto md:mx-0">
            <img
              src={"/image/#{@movie.id}"}
              alt={@movie.title}
              class="w-full aspect-[2/3] object-cover rounded-sm bg-rule"
            />
          </div>

          <div class="flex flex-col gap-5">
            <%!--
              Editorial kicker above the title: doubles as orientation
              ("you're in the Movies section") and back link ("click to
              return to the list"). The masthead's MOVIES nav is the
              global wayfinding; this is the local back affordance.
            --%>
            <.link
              navigate={~p"/movies"}
              class="w-fit font-sans text-[0.72rem] tracking-[0.18em] uppercase text-oxblood underline decoration-oxblood decoration-1 underline-offset-[5px] hover:opacity-75 transition-opacity duration-200"
            >
              ← Movies
            </.link>

            <h1
              class="font-heading text-ink tracking-tight leading-[1.05]"
              style="font-size: clamp(2rem, 3.5vw + 0.75rem, 3.5rem); font-variation-settings: 'opsz' 72;"
            >
              {@movie.title}
            </h1>

            <div class="font-sans text-[0.8rem] tracking-[0.14em] uppercase text-muted">
              {metadata_line(@movie)}
            </div>

            <CatalogGrid.rotten_tomatoes :if={@movie.rating} rating={@movie.rating} center={false} />

            <p
              :if={@movie.synopsis && @movie.synopsis != ""}
              class="font-display text-ink/85 text-lg leading-relaxed max-w-[60ch] pt-2"
              style="font-variation-settings: 'opsz' 14;"
            >
              {@movie.synopsis}
            </p>

            <div class="pt-4">
              <button
                type="button"
                class="bg-oxblood text-paper font-sans text-xs tracking-[0.18em] uppercase font-medium px-7 py-3 rounded-sm transition-opacity hover:opacity-90 focus:outline-none focus-visible:ring-2 focus-visible:ring-oxblood/40 focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
              >
                Play
              </button>
            </div>
          </div>
        </div>

        <%!--
          Trailer embedded inline. Lazy-loaded so the YouTube iframe
          doesn't load for every page view — only when scrolled into
          range. No autoplay; user initiates playback by clicking
          YouTube's own play overlay. No heading because the player
          itself says what it is.
        --%>
        <%!--
          Trailer is constrained to a deliberate ~16:9 size (max-w-lg
          = 512px wide, 288px tall) rather than spanning the article
          width. Two reasons: (1) full-width 620px-tall iframes push
          everything else below the fold on most laptops; (2) a
          contained player reads as "preview embedded in an article"
          rather than a Netflix-style hero, which fits the editorial
          aesthetic better.
        --%>
        <section :if={trailer_embeddable?(@movie.trailer_url)} class="mt-12 md:mt-14">
          <div class="aspect-video w-full max-w-lg mx-auto bg-rule rounded-sm overflow-hidden">
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
        </section>
      </article>
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
