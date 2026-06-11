defmodule AviaryWeb.PageController do
  @moduledoc """
  Sends the bare root URL to the canonical Shows page. Having `/shows`
  exist as a real route (not aliased at "/") keeps each section's URL
  distinct, which is what the PWA scope check on iOS needs to behave
  consistently — every nav link points at the URL it advertises.
  """
  use AviaryWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/home")
  end
end
