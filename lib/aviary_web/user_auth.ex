defmodule AviaryWeb.UserAuth do
  @moduledoc """
  Session-based authentication plug + LiveView mount guard. Reads the
  current user from the session cookie and assigns it to `conn.assigns`
  (controllers) or `socket.assigns` (LiveViews) so downstream code can
  reach for `current_user.token` to authenticate Jellyfin calls.

  Following Phoenix's standard auth-module conventions so anyone
  familiar with `mix phx.gen.auth`'s output can navigate this without
  hunting.
  """
  use AviaryWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Aviary.Auth

  @session_key :aviary_user

  ## Session helpers

  @doc """
  Stores the user in the session and redirects to the post-login
  destination (path stored under :return_to, or /home by default).
  """
  def log_in_user(conn, user) do
    return_to = get_session(conn, :user_return_to) || ~p"/home"

    conn
    |> renew_session()
    |> put_session(@session_key, %{
      id: user.id,
      username: user.username,
      token: user.token
    })
    |> redirect(to: return_to)
  end

  @doc """
  Invalidates the user's session and redirects to the login page.
  """
  def log_out_user(conn) do
    user = get_session(conn, @session_key)
    Auth.log_out(user || %{})

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  ## Plugs

  @doc """
  Reads the session and assigns `current_user` to the conn. Always
  runs — protected routes still need require_authenticated_user.
  """
  def fetch_current_user(conn, _opts) do
    user = get_session(conn, @session_key)
    assign(conn, :current_user, user)
  end

  @doc """
  Redirects to /home if a user is already logged in. Used on the
  /login route so authenticated users don't hit the form again.
  """
  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: ~p"/home") |> halt()
    else
      conn
    end
  end

  @doc """
  Redirects to /login if no user is in the session. Stores the
  attempted path so log_in_user can return them there.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  ## LiveView guards

  @doc """
  on_mount callback for LiveView. Reads the user from session and
  assigns to socket; halts with a redirect if required and missing.

  Usage:

      live_session :authenticated, on_mount: {AviaryWeb.UserAuth, :require_authenticated} do
        live "/shows", ShowsLive, :index
        ...
      end
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    user = session["aviary_user"] || session[@session_key]

    # Probe Jellyfin to confirm the cookied token is still good. Without
    # this, a stale session (token Jellyfin no longer recognizes —
    # happens across deploys where Jellyfin's db was rebuilt) takes down
    # every authenticated page with a 500 once a Jellyfin call returns
    # 401 + empty body. One extra HTTP call per mount is cheap; the
    # alternative is per-call 500s.
    if user && Aviary.Auth.token_valid?(user.token) do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Sign in to continue")
       |> Phoenix.LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign_new(socket, :current_user, fn ->
       session["aviary_user"] || session[@session_key]
     end)}
  end
end
