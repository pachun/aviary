defmodule AviaryWeb.Components.Marquee do
  @moduledoc """
  Horizontal scrollable row of 16:9 thumbnail cards. Used by the home
  page's Continue Watching feed, and reusable for episode-list views
  on show detail pages.

  Each item is `%{detail_id, kind, thumbnail_item_id, thumbnail_kind,
  title, subtitle}` — kind is `:movie` or `:show` and determines the
  detail-page URL prefix.
  """
  use Phoenix.Component

  attr :items, :list, required: true
  attr :from, :string, required: true, doc: "kicker source — \"home\", \"discover\", \"shows\", \"movies\""

  attr :key, :string,
    default: nil,
    doc:
      "Optional stable key used by the scroll-restore JS hook to remember this row's horizontal scrollLeft when the user navigates away and comes back."

  slot :empty, doc: "rendered when there's nothing to show"

  def row(assigns) do
    ~H"""
    <%= if Enum.empty?(@items) do %>
      <p class="font-display italic text-muted text-2xl pt-4">
        {render_slot(@empty)}
      </p>
    <% else %>
      <%!--
        Stays within the content gutter (no negative-margin full bleed)
        so items clip cleanly at the same edges as the label above
        when scrolled. Scrollbar hidden via webkit + Firefox properties;
        snap-x for clean card-by-card scrolling.
      --%>
      <ul
        data-marquee-key={@key}
        class="flex gap-3 sm:gap-4 overflow-x-auto snap-x snap-mandatory p-1 pb-4 scroll-p-1 [&::-webkit-scrollbar]:hidden [scrollbar-width:none]"
      >
        <li :for={item <- @items} class="snap-start shrink-0">
          <.card item={item} from={@from} />
        </li>
      </ul>
    <% end %>
    """
  end

  attr :item, :map, required: true
  attr :from, :string, required: true

  defp card(assigns) do
    ~H"""
    <%!--
      .link navigate (rather than a bare <a href>) makes this a LV soft
      nav. The scroll-restore hook listens to phx:page-loading-start to
      capture the source page's scrollY + marquee scrollLefts before
      the navigation begins — a regular anchor would trigger a full
      page reload and bypass that event, so the back-trip would land
      at the top.
    --%>
    <.link
      navigate={detail_href(@item, @from)}
      class="group block w-[240px] sm:w-[280px] md:w-[320px] focus:outline-none"
    >
      <div class={[
        "aspect-video w-full overflow-hidden rounded-sm bg-rule relative",
        "ring-2 ring-transparent transition-all duration-200",
        "group-hover:ring-oxblood group-focus-visible:ring-oxblood"
      ]}>
        <img
          src={thumbnail_src(@item)}
          alt={@item.title}
          loading="lazy"
          class="w-full h-full object-cover"
        />
        <%!--
          Bottom-anchored title overlay. Gradient ensures legibility
          regardless of artwork brightness.
        --%>
        <div class="absolute inset-x-0 bottom-0 p-3 bg-gradient-to-t from-black/85 via-black/50 to-transparent">
          <h3 class="font-display text-white text-base leading-tight line-clamp-1">
            {@item.title}
          </h3>
          <p
            :if={@item.subtitle}
            class="font-sans text-white/75 text-[0.7rem] tracking-[0.04em] line-clamp-1 mt-0.5"
          >
            {@item.subtitle}
          </p>
        </div>
      </div>
    </.link>
    """
  end

  # Explicit URL takes precedence — used by the discover page where
  # items come from TMDB and bypass aviary's Jellyfin image proxy.
  defp thumbnail_src(%{thumbnail_url: url}) when is_binary(url), do: url

  defp thumbnail_src(%{thumbnail_item_id: id, thumbnail_kind: :backdrop}) do
    "/image/#{id}?kind=backdrop"
  end

  defp thumbnail_src(%{thumbnail_item_id: id}), do: "/image/#{id}"

  defp detail_href(%{kind: :movie, detail_id: id}, from), do: "/movies/#{id}?from=#{from}"
  defp detail_href(%{kind: :show, detail_id: id}, from), do: "/shows/#{id}?from=#{from}"
end
