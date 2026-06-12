defmodule AviaryWeb.PageController do
  @moduledoc """
  Sends the bare root URL to the user's first visible section. Empty
  library? Lands on /discover. Has content for Home? Goes there.
  Otherwise /library. Keeps each section's URL distinct so the iOS
  PWA scope check stays consistent — every nav link points at the
  URL it advertises.
  """
  use AviaryWeb, :controller

  def home(conn, _params) do
    visibility = Aviary.Nav.visibility(conn.assigns.current_user)
    redirect(conn, to: Aviary.Nav.landing_path(visibility))
  end
end
