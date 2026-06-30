defmodule AviaryWeb.API.NavController do
  @moduledoc """
  Top-level navigation hints for native clients — which sections have
  content worth a tab, and which to land on at launch. Reuses the web
  masthead's `Aviary.Nav` so tvOS and web agree on what's shown and the
  default landing (home > shows > movies > discover).
  """
  use AviaryWeb, :controller

  def show(conn, _params) do
    visibility = Aviary.Nav.visibility(conn.assigns.current_user)

    json(conn, %{
      home: visibility.home,
      shows: visibility.shows,
      movies: visibility.movies,
      landing: landing(visibility)
    })
  end

  defp landing(%{home: true}), do: "home"
  defp landing(%{shows: true}), do: "shows"
  defp landing(%{movies: true}), do: "movies"
  defp landing(_), do: "discover"
end
