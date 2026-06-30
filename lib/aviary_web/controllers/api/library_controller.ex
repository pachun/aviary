defmodule AviaryWeb.API.LibraryController do
  @moduledoc """
  The user's curated library for native clients — the same per-user
  `Aviary.Catalog` lists the web Shows / Movies tabs render, flattened
  into the shape the tvOS client's catalog grid expects, with image
  URLs pointing at the token-authed image proxy (`/api/v1/image/:id`).
  """
  use AviaryWeb, :controller

  def shows(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Catalog.list_shows()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  def movies(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Catalog.list_movies()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  defp serialize(item) do
    %{
      id: item.id,
      kind: to_string(item.type),
      title: item.title,
      year: item.year,
      image: "/api/v1/image/#{item.id}"
    }
  end
end
