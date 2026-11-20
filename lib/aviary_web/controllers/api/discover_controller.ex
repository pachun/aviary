defmodule AviaryWeb.API.DiscoverController do
  @moduledoc """
  Discover for native clients — the same per-service rows the web
  /discover page renders (`Aviary.Discover`), flattened for the tvOS
  client. One row per streaming service, each a list of currently-
  popular shows. Rows are fetched concurrently so the endpoint returns
  in roughly the slowest single row's time rather than the sum; the
  client caches the result and revalidates in the background.

  Item images point at the TMDB proxy (`/api/v1/image/tmdb/...`) since
  discover shows usually aren't in the library yet — there's no
  Jellyfin id to serve a poster from.
  """
  use AviaryWeb, :controller

  def index(conn, _params) do
    if Aviary.OnThisServer.all_there_is?(),
      do: json(conn, %{rows: on_this_server(conn.assigns.current_user)}),
      else: json(conn, %{rows: across_streaming_services()})
  end

  defp on_this_server(user) do
    for {label, items} <- Aviary.OnThisServer.rows(user),
        do: %{label: label, items: Enum.map(items, &serialize/1)}
  end

  defp across_streaming_services do
    Aviary.Discover.services()
    |> Task.async_stream(
      fn {label, network_ids} ->
        %{label: label, items: Enum.map(Aviary.Discover.fetch_row(network_ids), &serialize/1)}
      end,
      max_concurrency: 7,
      timeout: 25_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, row} -> [row]
      _ -> []
    end)
    |> Enum.reject(&(&1.items == []))
  end

  # Shared shape with search results. detail_id is a Jellyfin id when
  # the show is already owned (routes to the real detail page) or a
  # TMDB id otherwise (the detail endpoints resolve both). Stringified
  # because a TMDB id comes through as an integer.
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
