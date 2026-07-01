defmodule AviaryWeb.API.SearchController do
  @moduledoc """
  Search for native clients — the same TMDB multi-search (shows +
  movies) the web /search page runs (`Aviary.Search`), returned as a
  single flat, relevance-ordered list. The client groups by kind and
  handles its own debounce. Empty query returns no items.
  """
  use AviaryWeb, :controller

  def index(conn, %{"q" => q}) when is_binary(q) do
    items =
      case String.trim(q) do
        "" -> []
        trimmed -> trimmed |> Aviary.Search.run() |> Enum.map(&serialize/1)
      end

    json(conn, %{items: items})
  end

  def index(conn, _params), do: json(conn, %{items: []})

  defp serialize(item) do
    %{
      id: to_string(item.detail_id),
      kind: to_string(item.kind),
      title: item.title,
      image: item.thumbnail_url && "/api/v1" <> item.thumbnail_url,
      rating: item.rating
    }
  end
end
