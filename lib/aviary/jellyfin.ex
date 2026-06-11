defmodule Aviary.Jellyfin do
  @moduledoc """
  Thin wrapper over Jellyfin's REST API. Every function takes an
  `auth` map (`%{id, token, ...}`) — the currently logged-in user's
  identity, obtained from Aviary.Auth.log_in. We use the user's token
  for the X-Emby-Token header so reads/writes flow through Jellyfin's
  real user context. UserData (resume position, played, favorites)
  per-user "just works" with this pattern.

  Browser-loadable image URLs embed `api_key=` in the query string
  with the user's token — that's the only auth path for <img src>
  (no headers available) and is acceptable because the URL never
  leaves the user's session.
  """

  @api_path "/Items"

  ## Catalog reads

  def list_shows(auth) do
    get!(@api_path, auth,
      IncludeItemTypes: "Series",
      Recursive: true,
      Fields: "PremiereDate,EndDate,Status,ProductionYear"
    )
    |> Map.fetch!("Items")
  end

  def list_movies(auth) do
    get!(@api_path, auth,
      IncludeItemTypes: "Movie",
      Recursive: true,
      Fields: "ProductionYear"
    )
    |> Map.fetch!("Items")
  end

  @doc """
  Fetch a single item by id with the fuller field set the detail page
  needs — overview, MPAA rating, runtime, remote trailers, plus
  UserData (resume position, played state).
  """
  def get_item(id, auth) do
    result =
      get!(@api_path, auth,
        Ids: id,
        userId: auth.id,
        Fields:
          "Overview,OfficialRating,RunTimeTicks,RemoteTrailers,PremiereDate,EndDate,Status,ProductionYear,Genres,UserData"
      )

    case result["Items"] do
      [item | _] -> {:ok, item}
      _ -> :error
    end
  end

  ## Playback state

  @doc """
  Persists a playback position to the current user's UserData. Used
  after each progress report from the player.

  `position_ticks` is in Jellyfin's 100ns units.
  """
  def save_position(item_id, position_ticks, auth) do
    Req.post(base_url() <> "/UserItems/" <> item_id <> "/UserData",
      params: [userId: auth.id],
      headers: [{"x-emby-token", auth.token}],
      json: %{"PlaybackPositionTicks" => position_ticks},
      receive_timeout: 5_000
    )
  rescue
    _ -> :error
  end

  ## Image proxy

  @doc """
  Fetches a poster image as bytes + content-type. Used by AviaryWeb's
  image proxy controller — the browser can't reach the Jellyfin URL
  directly in deployed environments, so we proxy through aviary's own
  endpoint.
  """
  def fetch_poster(item_id, auth, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 400)
    url = "#{base_url()}/Items/#{item_id}/Images/Primary?maxWidth=#{max_width}"

    case Req.get(url,
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        {:ok, body, content_type(headers)}

      _ ->
        :error
    end
  end

  ## Video stream

  @doc """
  Returns an HLS master playlist URL the browser can open directly.
  Built against the public-facing Jellyfin URL (Tailscale-served HTTPS
  in deployed environments) and embeds the user's auth token so the
  request from the user's device is authenticated as them.
  """
  def hls_url(item_id, auth) do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    params =
      URI.encode_query(%{
        "api_key" => auth.token,
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

  ## Internals

  defp get!(path, auth, params) do
    Req.get!(base_url() <> path,
      params: params,
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
  end

  defp content_type(headers) do
    case Map.get(headers, "content-type") do
      [value | _] -> value
      _ -> "image/jpeg"
    end
  end

  defp base_url do
    Application.fetch_env!(:aviary, :jellyfin_url) |> String.trim_trailing("/")
  end

  defp public_url do
    case Application.get_env(:aviary, :jellyfin_public_url) do
      nil -> base_url()
      "" -> base_url()
      url -> String.trim_trailing(url, "/")
    end
  end
end
