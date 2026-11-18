defmodule AviaryWeb.API.MarqueeItem do
  @moduledoc """
  The JSON shape native clients get for a card in a row of titles.
  `id` is a Jellyfin id when the title is in the library and a TMDB id
  otherwise; the detail endpoints resolve both.
  """

  def serialize(item) do
    %{
      id: to_string(item.detail_id),
      kind: to_string(item.kind),
      title: item.title,
      image: item.thumbnail_url && "/api/v1" <> item.thumbnail_url,
      rating: item.rating
    }
  end
end
