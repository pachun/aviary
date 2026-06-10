defmodule AviaryWeb.Components.CatalogGrid do
  @moduledoc """
  Shared grid used by Shows + Movies. Items are pure artwork — no title
  or year captions; the poster is the identity. Empty sections render a
  quiet italic line in lieu of an empty grid.
  """
  use Phoenix.Component

  attr :items, :list, required: true
  slot :empty, doc: "rendered when items is empty — each section supplies its own message"

  def grid(assigns) do
    ~H"""
    <%= if Enum.empty?(@items) do %>
      <p class="font-display italic text-muted text-2xl pt-4">
        {render_slot(@empty)}
      </p>
    <% else %>
      <div class="grid grid-cols-[repeat(auto-fill,minmax(140px,1fr))] gap-x-4 gap-y-10 sm:gap-x-8 sm:gap-y-12">
        <.item :for={item <- @items} item={item} />
      </div>
    <% end %>
    """
  end

  attr :item, :map, required: true

  defp item(assigns) do
    ~H"""
    <a href={item_href(@item)} class="group block focus:outline-none">
      <img
        src={"/image/#{@item.id}"}
        alt={@item.title}
        loading="lazy"
        class={[
          "aspect-[2/3] w-full object-cover rounded-sm bg-rule",
          "ring-2 ring-transparent transition-all duration-200",
          "group-hover:ring-oxblood group-focus-visible:ring-oxblood"
        ]}
      />
      <.rotten_tomatoes :if={@item.rating} rating={@item.rating} />
    </a>
    """
  end

  @doc """
  Rotten Tomatoes critic + audience badge cluster — reused by the
  detail page so the visual treatment stays identical wherever
  ratings show up.

  `:center` defaults true because the grid is the dominant caller and
  wants the cluster centered under each poster. The detail page sits
  in a flush-left info column and passes `center={false}` so the
  badges anchor to the same left edge as the title, metadata, and
  synopsis.
  """
  attr :rating, :map, required: true
  attr :center, :boolean, default: true

  # RT scoring threshold: fresh ≥ 60, rotten < 60 — mirrors RT's
  # own cutoff. Inlined as 60 below because module attributes collide
  # with HEEx's `@name` (which means `assigns.name`).
  def rotten_tomatoes(assigns) do
    ~H"""
    <div class={[
      "mt-3 flex items-center gap-6 sm:gap-8 font-sans tabular-nums text-lg",
      @center && "justify-center"
    ]}>
      <span class="flex items-center gap-2">
        <img
          src={if @rating.critic >= 60, do: "/images/rt_fresh.svg", else: "/images/rt_rotten.svg"}
          alt={if @rating.critic >= 60, do: "Fresh", else: "Rotten"}
          class="size-5 shrink-0"
        />
        <span class="text-ink leading-none font-medium">{@rating.critic}%</span>
      </span>
      <span class="flex items-center gap-2">
        <img
          src={if @rating.audience >= 60, do: "/images/rt_aud_fresh.svg", else: "/images/rt_aud_rotten.svg"}
          alt={if @rating.audience >= 60, do: "Audience Liked", else: "Audience Disliked"}
          class="size-5 shrink-0"
        />
        <span class="text-ink leading-none font-medium">{@rating.audience}%</span>
      </span>
    </div>
    """
  end

  # Movies link to their detail page; shows don't have one yet so they
  # render as non-navigating links. When ShowsDetailLive lands, this
  # second clause becomes the symmetric `/shows/:id` pattern.
  defp item_href(%{type: :movie, id: id}), do: "/movies/#{id}"
  defp item_href(_), do: "#"
end
