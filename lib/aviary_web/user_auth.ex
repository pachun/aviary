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
    # Validate at the plug layer (not in on_mount) so that when the
    # session is stale we can DROP THE COOKIE — a LV socket can't
    # write cookies, so an on_mount redirect to /login left the stale
    # session intact and produced an endless redirect loop ("logged
    # in" cookie → /login redirects to /home → on_mount kicks back
    # to /login → ...). Only manual cookie deletion broke the loop.
    #
    # token_valid? fails open on transport errors (anything that
    # isn't an explicit 401/403), so this doesn't kick users when
    # Jellyfin is briefly unreachable.
    case get_session(conn, @session_key) do
      %{token: token} = user when is_binary(token) ->
        if Aviary.Auth.token_valid?(token) do
          # Backfill is a no-op after the first request per user —
          # checks a primary-key lookup, runs the seed only if the
          # user_backfills row is missing. Belongs here (not on
          # explicit login) so existing users hitting a deployed
          # version of Stage 2 don't see empty Continue Watching.
          Aviary.Library.Backfill.ensure_run(user)
          assign(conn, :current_user, user)
        else
          conn
          |> configure_session(drop: true)
          |> assign(:current_user, nil)
        end

      _ ->
        assign(conn, :current_user, nil)
    end
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
        live "/library", LibraryLive, :index
        ...
      end
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    # Token validity is checked by fetch_current_user at the plug
    # layer (where we can actually drop the cookie on failure). Here
    # we just trust that whatever's in the session has already been
    # validated. If nothing's in the session, the user landed via a
    # path that doesn't go through the HTTP plug — push to /login.
    user = session["aviary_user"] || session[@session_key]

    if user do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:nav_visibility, Aviary.Nav.visibility(user))}
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
