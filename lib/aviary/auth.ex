defmodule Aviary.Auth do
  @moduledoc """
  Authentication via Jellyfin. Aviary doesn't store its own user
  accounts — it delegates to Jellyfin's user system. A successful
  login returns a user-scoped access token from Jellyfin that we then
  use as the bearer for every subsequent API call, so per-user state
  (watch progress, favorites, etc.) flows through Jellyfin's normal
  auth context.
  """

  @client_auth ~s|MediaBrowser Client="Aviary", Device="Aviary Web", DeviceId="aviary-web", Version="0.1.0"|

  @doc """
  Authenticates against Jellyfin with username + password. On success
  returns `{:ok, %{id, username, token}}`; on failure returns
  `{:error, reason}`.
  """
  def log_in(username, password) do
    url = base_url() <> "/Users/AuthenticateByName"

    case Req.post(url,
           headers: [
             {"content-type", "application/json"},
             {"x-emby-authorization", @client_auth}
           ],
           json: %{"Username" => username, "Pw" => password},
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"User" => user, "AccessToken" => token}}} ->
        {:ok, %{id: user["Id"], username: user["Name"], token: token}}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :invalid_credentials}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, _} = err ->
        err
    end
  rescue
    _ -> {:error, :request_failed}
  end

  @doc """
  Best-effort logout — invalidates the access token on Jellyfin's side
  so it can't be reused. Always returns :ok; if the network call fails
  we just drop the session locally and move on.
  """
  def log_out(%{token: token}) when is_binary(token) do
    Req.post(base_url() <> "/Sessions/Logout",
      headers: [
        {"x-emby-token", token},
        {"x-emby-authorization", @client_auth}
      ],
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :ok
  end

  def log_out(_), do: :ok

  @doc """
  Cheap "is this token still good with Jellyfin?" check. Used by the
  LiveView mount guard to bounce stale sessions to /login instead of
  letting downstream Jellyfin calls 500 on `Map.fetch!("Items")` when
  Jellyfin returns 401 with an empty body. Returns true only on a 200
  — any other status or transport error is treated as invalid so we
  fail closed.
  """
  def token_valid?(token) when is_binary(token) do
    case Req.get(base_url() <> "/Users/Me",
           headers: [{"x-emby-token", token}],
           receive_timeout: 3_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def token_valid?(_), do: false

  defp base_url do
    Application.fetch_env!(:aviary, :jellyfin_url) |> String.trim_trailing("/")
  end
end
