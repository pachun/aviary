defmodule AviaryWeb.API.NavController do
  @moduledoc """
  Top-level navigation hints for native clients — which sections have
  content worth a tab, and which to land on at launch. Reuses the web
  masthead's `Aviary.Nav` so tvOS and web agree on what's shown and the
  default landing (home > shows > movies > nhl > discover).

  `live` and `series` describe the two sections whose name and contents
  are the server's to define: what to call each, whether the live one
  comes with standings and team pages, and which shows the series one
  offers. Each is `false` when the server has nothing for it.
  """
  use AviaryWeb, :controller

  def show(conn, _params) do
    visibility = Aviary.Nav.visibility(conn.assigns.current_user)

    json(conn, %{
      home: visibility.home,
      shows: visibility.shows,
      movies: visibility.movies,
      live: visibility.nhl && %{label: Aviary.Live.label(), sports: Aviary.Live.sports?()},
      series:
        visibility.daily_wire && %{label: Aviary.Series.label(), shows: Aviary.Series.shows()},
      landing: landing(visibility)
    })
  end

  defp landing(%{home: true}), do: "home"
  defp landing(%{shows: true}), do: "shows"
  defp landing(%{movies: true}), do: "movies"
  defp landing(%{nhl: true}), do: "nhl"
  defp landing(_), do: "discover"
end
