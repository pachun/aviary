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
    <a href="#" class="group block focus:outline-none">
      <img
        src={@item.poster_url}
        alt={@item.title}
        loading="lazy"
        class={[
          "aspect-[2/3] w-full object-cover rounded-sm bg-rule",
          "ring-2 ring-transparent transition-all duration-200",
          "group-hover:ring-oxblood group-focus-visible:ring-oxblood"
        ]}
      />
    </a>
    """
  end

end
