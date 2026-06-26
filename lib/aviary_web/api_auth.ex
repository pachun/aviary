defmodule AviaryWeb.APIAuth do
  @moduledoc """
  Bearer-token authentication for the JSON API consumed by native
  clients (tvOS). Where the web app carries the user in a session
  cookie, native clients send `Authorization: Bearer <jellyfin-token>`
  on every request; this plug rebuilds the current user from that
  token via `Aviary.Auth` and assigns it, or halts with a 401 JSON
  body. Downstream controllers then read `conn.assigns.current_user`
  exactly like the LiveViews do.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Aviary.Auth.user_from_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
