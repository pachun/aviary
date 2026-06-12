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
          "Overview,OfficialRating,RunTimeTicks,RemoteTrailers,PremiereDate,EndDate,Status,ProductionYear,Genres,UserData,ProviderIds"
      )

    case result["Items"] do
      [item | _] -> {:ok, item}
      _ -> :error
    end
  end

  @doc """
  Lists all episodes for a series, including UserData (resume + played)
  per-episode. Returned items have ParentIndexNumber (season number)
  and IndexNumber (episode number within the season).
  """
  def list_episodes(series_id, auth) do
    Req.get!(base_url() <> "/Shows/" <> series_id <> "/Episodes",
      params: [
        userId: auth.id,
        Fields: "Overview,RunTimeTicks,UserData"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      %{"Items" => items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Items the user is mid-watch on — movies with saved positions, plus
  episodes in progress. Includes the SeriesId / SeriesName for
  episodes so the home page can group by show.
  """
  def resume_items(auth) do
    Req.get!(base_url() <> "/UserItems/Resume",
      params: [
        userId: auth.id,
        Limit: 30,
        MediaTypes: "Video",
        Fields: "UserData,SeriesId,SeriesPrimaryImageTag,SeriesStudio"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      %{"Items" => items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  All-shows NextUp — across the user's whole library, return the next
  episode to watch for each show with progress. Used by the home page
  Continue Watching row.
  """
  def next_up_across_library(auth) do
    Req.get!(base_url() <> "/Shows/NextUp",
      params: [
        userId: auth.id,
        Limit: 50,
        Fields: "UserData,SeriesPrimaryImageTag"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      %{"Items" => items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Items the user has most recently watched (Played=true), sorted by
  DatePlayed descending. Used by the home page to surface shows where
  the user is caught up — Resume's lingering-ticks artifact would
  otherwise point at the wrong episode, and Latest's "newly added"
  ordering misses pure rewatch activity.
  """
  def recently_watched(auth) do
    Req.get!(base_url() <> "/Items",
      params: [
        userId: auth.id,
        IncludeItemTypes: "Episode,Movie",
        Filters: "IsPlayed",
        SortBy: "DatePlayed",
        SortOrder: "Descending",
        Recursive: true,
        Limit: 30,
        Fields: "UserData,SeriesId,SeriesPrimaryImageTag,DateCreated"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      %{"Items" => items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Recently-added episodes — surfaces new episodes that arrived (via
  Sonarr import) since the user last interacted with the show. Sort
  by DateCreated descending on Jellyfin's side.
  """
  def latest_episodes(auth) do
    Req.get!(base_url() <> "/Users/" <> auth.id <> "/Items/Latest",
      params: [
        IncludeItemTypes: "Episode",
        Limit: 30,
        Fields: "UserData,SeriesPrimaryImageTag,DateCreated"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      items when is_list(items) -> items
      _ -> []
    end
  end

  @doc """
  Browser-loadable backdrop (16:9) image URL — used on the home page
  marquee where landscape thumbnails read better than 2:3 posters.
  Falls back to the poster URL when the item has no backdrop.
  """
  def fetch_backdrop(item_id, auth, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 600)
    url = "#{base_url()}/Items/#{item_id}/Images/Backdrop/0?maxWidth=#{max_width}"

    case Req.get(url,
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        {:ok, body, content_type(headers)}

      _ ->
        fetch_poster(item_id, auth, opts)
    end
  end

  @doc """
  Returns the next-up episode for this user on the given series.
  Returns `{:ok, episode}` when there is one, or `:none` if the user
  has finished the series (or never started — both result in NextUp
  returning an empty list).
  """
  def next_up(series_id, auth) do
    Req.get!(base_url() <> "/Shows/NextUp",
      params: [
        userId: auth.id,
        seriesId: series_id,
        Fields: "UserData"
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
    |> case do
      %{"Items" => [item | _]} -> {:ok, item}
      _ -> :none
    end
  end

  ## Playback state

  @doc """
  Persists a playback position to the current user's UserData. Used
  after each progress report from the player.

  `position_ticks` is in Jellyfin's 100ns units.
  """
  def save_position(item_id, position_ticks, auth) do
    # Jellyfin doesn't auto-update LastPlayedDate when a partial
    # UserData payload arrives — we have to stamp it explicitly. Without
    # this, every progress report correctly updates the position but
    # leaves "when did the user last touch this" frozen at whatever
    # client first recorded the item, so the home page's recency
    # ordering misses anything watched through aviary.
    Req.post(base_url() <> "/UserItems/" <> item_id <> "/UserData",
      params: [userId: auth.id],
      headers: [{"x-emby-token", auth.token}],
      json: %{
        "PlaybackPositionTicks" => position_ticks,
        "LastPlayedDate" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
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
