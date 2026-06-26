defmodule Aviary.Auth do
  @moduledoc """
  Authentication via Jellyfin. Aviary doesn't store its own user
  accounts — it delegates to Jellyfin's user system. A successful
  login returns a user-scoped access token from Jellyfin that we then
  use as the bearer for every subsequent API call, so per-user state
  (watch progress, favorites, etc.) flows through Jellyfin's normal
  auth context.
  """

  @doc """
  Authenticates against Jellyfin with username + password. On success
  returns `{:ok, %{id, username, token}}`; on failure returns
  `{:error, reason}`.

  Uses a freshly-generated DeviceId per login so concurrent sessions
  (different browsers, mobile + desktop, etc.) don't collide in
  Jellyfin's session tracking — a static DeviceId would cause Jellyfin
  to invalidate the older session's token whenever a new one logs in,
  silently logging the older session out.
  """
  def log_in(username, password) do
    url = base_url() <> "/Users/AuthenticateByName"
    device_id = "aviary-web-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    client_auth =
      ~s|MediaBrowser Client="Aviary", Device="Aviary Web", DeviceId="#{device_id}", Version="0.1.0"|

    case Req.post(url,
           headers: [
             {"content-type", "application/json"},
             {"x-emby-authorization", client_auth}
           ],
           json: %{"Username" => username, "Pw" => password},
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"User" => user, "AccessToken" => token}}} ->
        # PrimaryImageTag is Jellyfin's per-user cache key for the
        # avatar image — changes when the user uploads a new photo.
        # Persisted in the session so the avatar URL includes it as
        # a cache-buster; logging out + back in picks up new tags.
        {:ok,
         %{
           id: user["Id"],
           username: user["Name"],
           token: token,
           primary_image_tag: user["PrimaryImageTag"]
         }}

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
  Resolves a bare access token back to the full user map the context
  modules expect (`%{id, username, token, primary_image_tag}`).

  The web app carries this map in the session cookie from login
  onward, but a native client (tvOS) holds only the token — so on each
  API request the auth plug rebuilds the rest from the token alone.
  Jellyfin's `/Users/Me` returns the authenticated user for a token,
  which is exactly that; a 200 doubles as proof the token is still
  valid, while 401/403 means it's been revoked.
  """
  def user_from_token(token) when is_binary(token) do
    case Req.get(base_url() <> "/Users/Me",
           headers: [{"x-emby-token", token}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: user}} ->
        {:ok,
         %{
           id: user["Id"],
           username: user["Name"],
           token: token,
           primary_image_tag: user["PrimaryImageTag"]
         }}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :invalid_token}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, _} = err ->
        err
    end
  rescue
    _ -> {:error, :request_failed}
  end

  def user_from_token(_), do: {:error, :invalid_token}

  @doc """
  Best-effort logout — invalidates the access token on Jellyfin's side
  so it can't be reused. Always returns :ok; if the network call fails
  we just drop the session locally and move on.
  """
  def log_out(%{token: token}) when is_binary(token) do
    Aviary.TokenCache.invalidate(token)

    # DeviceId is irrelevant on logout — Jellyfin invalidates by
    # token, not by session-key. Static placeholder so the header
    # remains well-formed.
    Req.post(base_url() <> "/Sessions/Logout",
      headers: [
        {"x-emby-token", token},
        {"x-emby-authorization",
         ~s|MediaBrowser Client="Aviary", Device="Aviary Web", DeviceId="aviary-web", Version="0.1.0"|}
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
    # Cache + probe-lock layers. The cache cuts at most one probe per
    # token per minute for SEQUENTIAL requests. The probe-lock prevents
    # concurrent requests (page mount + all thumbnail proxies firing
    # at once) from ALL probing in parallel on a cold cache, which
    # would overwhelm Jellyfin and produce spurious 401s that drop
    # sessions. Only one probe in flight at a time; siblings trust the
    # in-flight prober and return true.
    case Aviary.TokenCache.status(token) do
      :cached_valid -> true
      :probing -> true
      :not_cached -> probe_with_lock(token)
    end
  end

  def token_valid?(_), do: false

  defp probe_with_lock(token) do
    case Aviary.TokenCache.take_probe_lock(token) do
      :locked ->
        # Another caller is mid-probe. Trust them; the cache will
        # be filled momentarily. Fail-open.
        true

      :ok ->
        try do
          probe_and_cache(token)
        after
          Aviary.TokenCache.release_probe_lock(token)
        end
    end
  end

  defp probe_and_cache(token) do
    # Only invalidate on an explicit "Jellyfin rejected this token" —
    # which is a 401/403. Transport failures (Tailscale flap, slow
    # VPN, Jellyfin restart) shouldn't log the user out; the session
    # cookie is still legitimate. Fail-open on doubt instead of
    # fail-closed.
    case Req.get(base_url() <> "/Users/Me",
           headers: [{"x-emby-token", token}],
           receive_timeout: 3_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200}} ->
        Aviary.TokenCache.mark_valid(token)
        true

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        Aviary.TokenCache.invalidate(token)
        false

      _ ->
        # Transport error or unexpected status — don't cache (so we
        # retry on the next request), but don't kick the user either.
        true
    end
  rescue
    _ -> true
  end

  defp base_url do
    Application.fetch_env!(:aviary, :jellyfin_url) |> String.trim_trailing("/")
  end
end
