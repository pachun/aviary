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
    render(conn, :new, error: nil, username: "", custom_domain: custom_domain(), layout: false)
  end

  def create(conn, %{"login" => %{"username" => username, "password" => password}}) do
    case Auth.log_in(String.trim(username), password) do
      {:ok, user} ->
        UserAuth.log_in_user(conn, user)

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          error: "Wrong username or password.",
          username: username,
          custom_domain: custom_domain(),
          layout: false
        )

      {:error, _} ->
        conn
        |> put_status(:bad_gateway)
        |> render(:new,
          error: "Couldn't reach Jellyfin. Try again in a moment.",
          username: username,
          custom_domain: custom_domain(),
          layout: false
        )
    end
  end

  # Returns the configured public host IF it's a real custom domain
  # — i.e. PHX_HOST was set to something other than the Phoenix
  # default ("example.com") AND it isn't a tailscale URL. Shown as
  # a tracked-uppercase banner above the login form so a family
  # member who lands on pachulski.tv sees that this is THE family's
  # tank, not some random login page.
  defp custom_domain do
    host = Keyword.get(AviaryWeb.Endpoint.config(:url) || [], :host)

    cond do
      is_nil(host) -> nil
      host == "example.com" -> nil
      String.ends_with?(host, ".ts.net") -> nil
      true -> host
    end
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end
end
