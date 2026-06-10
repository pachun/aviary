defmodule Aviary.Jellyfin do
  @moduledoc """
  Thin wrapper over Jellyfin's REST API. Reads URL + API key from
  application config (which runtime.exs populates from env vars).

  Auth: X-Emby-Token header for API calls. For image URLs the browser
  loads via <img>, we embed `api_key=` in the query string — there's
  no other way to authenticate an <img src> without proxying. The
  exposure is tolerable on a Tailscale-internal app; revisit if Aviary
  ever leaves the tailnet.
  """

  @api_path "/Items"

  def list_shows do
    get!(@api_path,
      IncludeItemTypes: "Series",
      Recursive: true,
      Fields: "PremiereDate,EndDate,Status,ProductionYear"
    )
    |> Map.fetch!("Items")
  end

  def list_movies do
    get!(@api_path,
      IncludeItemTypes: "Movie",
      Recursive: true,
      Fields: "ProductionYear"
    )
    |> Map.fetch!("Items")
  end

  @doc """
  Fetch a single item by id with the fuller field set the detail page
  needs — overview, MPAA rating, runtime, remote trailers, plus
  UserData (resume position, played state). UserData is populated only
  when we pass userId, so we resolve the Jellyfin user first.
  """
  def get_item(id) do
    result =
      get!(@api_path,
        Ids: id,
        userId: user_id(),
        Fields:
          "Overview,OfficialRating,RunTimeTicks,RemoteTrailers,PremiereDate,EndDate,Status,ProductionYear,Genres,UserData"
      )

    case result["Items"] do
      [item | _] -> {:ok, item}
      _ -> :error
    end
  end

  @doc """
  Persists a playback position to the user's UserData. Used after every
  progress report from the player.

  We use `POST /UserItems/{id}/UserData?userId=X` rather than the
  Sessions/Playing/* API because aviary authenticates with an admin
  API key (not a user-bound session token). The Sessions endpoints
  attribute their reports to the auth context's user, and admin API
  keys have UserId="00000000-...", which means progress saved through
  them never lands in any real user's UserData. The /UserItems
  endpoint takes the userId explicitly via query param, which sidesteps
  that and persists reliably.

  `position_ticks` is in Jellyfin's 100ns units.
  """
  def save_position(item_id, position_ticks) do
    case user_id() do
      nil ->
        :error

      uid ->
        Req.post(base_url() <> "/UserItems/" <> item_id <> "/UserData",
          params: [userId: uid],
          headers: [{"x-emby-token", api_key()}],
          json: %{"PlaybackPositionTicks" => position_ticks},
          receive_timeout: 5_000
        )
    end
  rescue
    _ -> :error
  end

  # Discovers and caches the Jellyfin user this aviary instance reports
  # progress as. Single-user assumption — fine for the home media
  # context aviary is built for. Cached in :persistent_term so it
  # survives the BEAM scheduler across requests but resets on process
  # restart (which is the right time to rediscover anyway).
  defp user_id do
    case :persistent_term.get({__MODULE__, :user_id}, nil) do
      nil ->
        case fetch_user_id() do
          nil ->
            nil

          id ->
            :persistent_term.put({__MODULE__, :user_id}, id)
            id
        end

      id ->
        id
    end
  end

  # API keys in Jellyfin are tied to the user who generated them, and
  # the Sessions/Playing endpoints save UserData against that user
  # specifically. To make sure get_item queries the same user, we
  # look up our specific API key in /Auth/Keys to find its owner.
  # Falls back to first user from /Users if that path doesn't resolve.
  defp fetch_user_id do
    fetch_user_id_from_auth_keys() || fetch_user_id_from_users_list()
  end

  defp fetch_user_id_from_auth_keys do
    case Req.get(base_url() <> "/Auth/Keys",
           headers: [{"x-emby-token", api_key()}],
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"Items" => keys}}} when is_list(keys) ->
        keys
        |> Enum.find_value(fn key ->
          if key["AccessToken"] == api_key(), do: key["UserId"]
        end)
        |> non_null_user_id()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Admin-generated API keys report UserId as the all-zeros UUID,
  # which is Jellyfin's "no real user" sentinel. Treat it as nil so
  # discovery falls through to the /Users list (where a real user
  # will be found).
  defp non_null_user_id(nil), do: nil

  defp non_null_user_id(uid) when is_binary(uid) do
    if String.replace(uid, ~r/[-0]/, "") == "", do: nil, else: uid
  end

  defp fetch_user_id_from_users_list do
    case Req.get(base_url() <> "/Users",
           headers: [{"x-emby-token", api_key()}],
           receive_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: 200, body: [user | _]}} -> user["Id"]
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Fetches a poster image as bytes + content-type. Used by AviaryWeb's
  image proxy controller — the browser can't reach the Jellyfin URL
  directly in deployed environments (host.docker.internal is
  container-only), so we proxy through aviary's own endpoint.
  """
  def fetch_poster(item_id, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 400)
    url = "#{base_url()}/Items/#{item_id}/Images/Primary?maxWidth=#{max_width}"

    case Req.get(url,
           headers: [{"x-emby-token", api_key()}],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        {:ok, body, content_type(headers)}

      _ ->
        :error
    end
  end

  defp content_type(headers) do
    case Map.get(headers, "content-type") do
      [value | _] -> value
      _ -> "image/jpeg"
    end
  end

  defp get!(path, params) do
    Req.get!(base_url() <> path,
      params: params,
      headers: [{"x-emby-token", api_key()}],
      receive_timeout: 15_000
    ).body
  end

  @doc """
  Returns an HLS master playlist URL the browser can open directly.
  Built against the public-facing Jellyfin URL (Tailscale-served HTTPS
  in deployed environments) rather than the internal API URL — the
  `<video>` element fetches this URL from the user's device, which
  can't reach `host.docker.internal`.

  Auth via `api_key=` query param (HTML5 video can't carry headers).
  Random `PlaySessionId` so concurrent sessions don't collide on
  Jellyfin's side.
  """
  def hls_url(item_id) do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    params =
      URI.encode_query(%{
        "api_key" => api_key(),
        "MediaSourceId" => item_id,
        "PlaySessionId" => session_id,
        "DeviceId" => "aviary-web",
        "VideoCodec" => "h264",
        "AudioCodec" => "aac",
        "SegmentContainer" => "ts",
        "MaxAudioChannels" => "2",
        "TranscodingMaxAudioChannels" => "2"
      })

    "#{public_url()}/Videos/#{item_id}/master.m3u8?#{params}"
  end

  defp public_url do
    case Application.get_env(:aviary, :jellyfin_public_url) do
      nil -> base_url()
      "" -> base_url()
      url -> String.trim_trailing(url, "/")
    end
  end

  defp base_url do
    case Application.fetch_env!(:aviary, :jellyfin_url) do
      nil ->
        raise """
        JELLYFIN_URL is not set. Source .env.local (or copy
        .env.local.example to .env.local and fill it in) before
        starting the dev server.
        """

      url ->
        String.trim_trailing(url, "/")
    end
  end

  defp api_key do
    case Application.fetch_env!(:aviary, :jellyfin_api_key) do
      nil ->
        raise """
        JELLYFIN_API_KEY is not set. Generate one in Jellyfin's admin
        dashboard (API Keys → +) and add it to .env.local.
        """

      key ->
        key
    end
  end
end
