defmodule AviaryWeb.SessionController do
  @moduledoc """
  Login + logout. Uses a plain controller (not a LiveView) because
  setting session cookies requires being in the conn lifecycle —
  LiveView socket processes can't write cookies directly.
  """
  use AviaryWeb, :controller

  alias Aviary.Auth
  alias AviaryWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, error: nil, username: "", layout: false)
  end

  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    case Auth.log_in(String.trim(username), password) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: "Wrong username or password.", username: username, layout: false)

      {:error, _} ->
        conn
        |> put_status(:bad_gateway)
        |> render(:new,
          error: "Couldn't reach Jellyfin. Try again in a moment.",
          username: username,
          layout: false
        )
    end
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
