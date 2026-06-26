defmodule AviaryWeb.API.HomeController do
  @moduledoc """
  The home feed for native clients. `continue_watching` mirrors the
  marquee on the web home page — the same `Aviary.Home` computation —
  flattened into the shape the tvOS client renders, with image URLs
  pointing back at the token-authed image proxy (`/api/v1/image/:id`).
  """
  use AviaryWeb, :controller

  def continue_watching(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Home.continue_watching()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  defp serialize(item) do
    %{
      id: item.dedupe_key,
      kind: to_string(item.kind),
      title: item.title,
      subtitle: item.subtitle,
      image: "/api/v1/image/#{item.thumbnail_item_id}?kind=backdrop"
    }
  end
end
