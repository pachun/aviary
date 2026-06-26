defmodule AviaryWeb.API.InfoController do
  @moduledoc """
  Unauthenticated server identity. A native client hits this right
  after the user enters a server URL — it confirms the address really
  is an aviary server (the `service` field) before the app asks for
  credentials, and surfaces the deploy's brand name for display.
  """
  use AviaryWeb, :controller

  def show(conn, _params) do
    json(conn, %{service: "aviary", name: System.get_env("TAB_TITLE") || "Aviary"})
  end
end
