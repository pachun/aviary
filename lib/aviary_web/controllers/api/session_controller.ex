defmodule AviaryWeb.API.SessionController do
  @moduledoc """
  JSON auth for native clients. `create` exchanges Jellyfin
  credentials for an access token; `show` echoes the current user
  back, so a client can confirm a stored token is still good on
  launch.
  """
  use AviaryWeb, :controller

  def create(conn, %{"username" => username, "password" => password})
      when is_binary(username) and is_binary(password) do
    case Aviary.Auth.log_in(String.trim(username), password) do
      {:ok, user} ->
        json(conn, %{token: user.token, user: public_user(user)})

      {:error, :invalid_credentials} ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_credentials"})

      {:error, _reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "server_unreachable"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing_credentials"})
  end

  def show(conn, _params) do
    json(conn, %{user: public_user(conn.assigns.current_user)})
  end

  defp public_user(user) do
    %{id: user.id, username: user.username, primary_image_tag: user.primary_image_tag}
  end
end
