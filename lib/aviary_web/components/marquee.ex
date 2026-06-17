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

  attr :dismissible, :boolean,
    default: false,
    doc:
      "When true, renders a hover-revealed X button on each card; click fires phx-click=\"dismiss\" with kind + detail_id. Home uses this to give the user direct control over Continue Watching."

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
        id={"marquee-" <> (@key || "anon-" <> Integer.to_string(:erlang.phash2(@items)))}
        data-marquee-key={@key}
        phx-hook="MarqueeScrollRestore"
        class="flex gap-3 sm:gap-4 overflow-x-auto overscroll-x-contain snap-x snap-mandatory p-1 pb-4 scroll-p-1 [&::-webkit-scrollbar]:hidden [scrollbar-width:none]"
      >
        <li :for={item <- @items} class="snap-start shrink-0">
          <.card item={item} from={@from} dismissible={@dismissible} />
        </li>
      </ul>
    <% end %>
    """
  end

  @doc """
  Placeholder row rendered while the real items are still being
  fetched. Five pulsing cards matched to the same dimensions the
  real cards use, so the layout doesn't jump when items arrive.
  """
  def skeleton(assigns) do
    ~H"""
    <div class="flex gap-3 sm:gap-4 p-1 pb-4">
      <div
        :for={_ <- 1..5}
        class="shrink-0 w-[200px] sm:w-[240px] md:w-[260px] aspect-video bg-rule/40 rounded-sm animate-pulse"
      >
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :from, :string, required: true
  attr :dismissible, :boolean, default: false

  defp card(assigns) do
    ~H"""
    <%!--
      Wrapper holds the `group` class so both the link's hover ring AND
      the dismiss X-button's hover-reveal trigger from the same parent
      hover. The dismiss button is a SIBLING of the link, not a child —
      otherwise its click would bubble through to the link's navigate.
    --%>
    <div class="group relative w-[200px] sm:w-[240px] md:w-[260px]">
      <.link navigate={detail_href(@item, @from)} class="block focus:outline-none">
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
          RT corner badge — only renders when item has :rating with
          at least one score. Continue Watching items don't get
          enriched so they stay clean; Discover items do. Critic icon
          + audience icon side by side, numbers only (no %) for
          compactness. Critic absent when RT has no data for the
          show but TMDB audience fallback is present.
        --%>
        <div
          :if={has_score?(@item)}
          class="absolute top-1.5 right-1.5 flex items-center gap-1.5 bg-paper/95 rounded-sm px-1.5 py-0.5 shadow-sm"
        >
          <span :if={@item.rating.critic} class="flex items-center gap-1">
            <img
              src={if @item.rating.critic >= 60, do: "/images/rt_fresh.svg", else: "/images/rt_rotten.svg"}
              alt=""
              class="size-3"
            />
            <span class="font-sans tabular-nums text-[0.65rem] text-ink font-medium leading-none">
              {@item.rating.critic}
            </span>
          </span>
          <span :if={@item.rating.audience} class="flex items-center gap-1">
            <img
              src={if @item.rating.audience >= 60, do: "/images/rt_aud_fresh.svg", else: "/images/rt_aud_rotten.svg"}
              alt=""
              class="size-3"
            />
            <span class="font-sans tabular-nums text-[0.65rem] text-ink font-medium leading-none">
              {@item.rating.audience}
            </span>
          </span>
        </div>

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

      <%!--
        Dismiss control — hover-revealed, top-right. Sits outside the
        link element so the click doesn't bubble into navigation.
        focus-visible mirrors the hover state for keyboard users.
      --%>
      <%!--
        Dismiss carries the Jellyfin id (series id for shows, item
        id for movies) — that's what the home handler hands to
        `reset_series_progress` / `reset_item_progress`.
      --%>
      <button
        :if={@dismissible}
        type="button"
        phx-click="dismiss"
        phx-value-id={dismiss_id(@item)}
        phx-value-kind={to_string(@item.kind)}
        data-confirm="Remove this? Your watch history for it will be cleared on all devices — can't be undone."
        aria-label="Remove from Continue Watching"
        class="absolute top-2 right-2 z-10 size-6 rounded-full bg-black/60 backdrop-blur-sm text-white text-xs leading-none flex items-center justify-center cursor-pointer transition-opacity duration-200 opacity-0 group-hover:opacity-100 focus-visible:opacity-100 hover:bg-black/80 focus:outline-none focus-visible:ring-2 focus-visible:ring-white/60"
      >
        ✕
      </button>
    </div>
    """
  end

  # Explicit URL takes precedence — used by the discover page where
  # items come from TMDB and bypass aviary's Jellyfin image proxy.
  defp thumbnail_src(%{thumbnail_url: url}) when is_binary(url), do: url

  defp thumbnail_src(%{thumbnail_item_id: id, thumbnail_kind: :backdrop}) do
    "/image/#{id}?kind=backdrop"
  end

  defp thumbnail_src(%{thumbnail_item_id: id}), do: "/image/#{id}"

  defp detail_href(%{kind: :movie, detail_id: id} = item, from),
    do: "/movies/#{id}?from=#{from}" <> kicker_q(item)

  defp detail_href(%{kind: :show, detail_id: id} = item, from),
    do: "/shows/#{id}?from=#{from}" <> kicker_q(item)

  # Optional `kicker_q` on an item embeds the originating query into the
  # detail href so the detail page's back link can rebuild the exact
  # state the user came from. Today only Search sets it — Discover and
  # Home rows have a stable landing page that needs no parameters.
  defp kicker_q(%{kicker_q: q}) when is_binary(q) and q != "",
    do: "&q=" <> URI.encode_www_form(q)

  defp kicker_q(_), do: ""

  defp has_score?(%{rating: %{critic: c, audience: a}}) when not (is_nil(c) and is_nil(a)), do: true
  defp has_score?(_), do: false

  defp dismiss_id(%{detail_id: id}), do: id
end
