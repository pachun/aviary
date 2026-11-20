defmodule AviaryWeb.API.CreditsController do
  @moduledoc "The server's credits for native clients, one line each (`Aviary.Credits`)."
  use AviaryWeb, :controller

  def show(conn, _params), do: json(conn, %{credits: Aviary.Credits.all()})
end
