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

  # Per-user caches for the catalog and per-series episode lists.
  # SWR — fresh window short enough that newly-added Sonarr-imports
  # show up quickly, stale window long enough that the typical
  # navigation pattern (Library → show detail → Library again)
  # never re-fetches.
  @catalog_fresh_ms 30_000
  @catalog_stale_ms 5 * 60_000
  @episodes_fresh_ms 5_000
  @episodes_stale_ms 60_000
  # Home page reads — these reflect the user's UserData (Played,
  # resume position, LastPlayedDate). Aggressive invalidation after
  # any UserData write keeps these fresh; SWR makes back-to-back
  # navigations between Home/Library/Show instant.
  @userdata_fresh_ms 5_000
  @userdata_stale_ms 60_000

  ## Catalog reads

  def list_shows(auth) do
    Aviary.Cache.swr({:jellyfin_list_shows, auth.id}, @catalog_fresh_ms, @catalog_stale_ms, fn ->
      get!(@api_path, auth,
        IncludeItemTypes: "Series",
        Recursive: true,
        Fields: "PremiereDate,EndDate,Status,ProductionYear,ProviderIds"
      )
      |> Map.fetch!("Items")
    end)
  end

  def list_movies(auth) do
    Aviary.Cache.swr({:jellyfin_list_movies, auth.id}, @catalog_fresh_ms, @catalog_stale_ms, fn ->
      get!(@api_path, auth,
        IncludeItemTypes: "Movie",
        Recursive: true,
        Fields: "ProductionYear"
      )
      |> Map.fetch!("Items")
    end)
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
    Aviary.Cache.swr(
      {:jellyfin_list_episodes, series_id, auth.id},
      @episodes_fresh_ms,
      @episodes_stale_ms,
      fn ->
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
    )
  end

  @doc """
  Returns the next unplayed, in-library episode for a series — the
  one the user should play next given their progress — or nil when
  the user is caught up.

  "Next" means "first non-virtual unplayed episode AFTER the user's
  furthest-along played episode," not "first unplayed in the list."
  The naive interpretation breaks the moment any earlier episode has
  stale `Played=false` (a mark_played call that silently failed, a
  skipped episode, manual file imports Jellyfin saw before the user
  watched the predecessor — any non-linear case). For a series where
  E1-E9 are played and E10 is virtual, this returns nil. For one
  where E9 stayed Played=false even though E3-E8 are played, this
  still returns nil because the user is clearly past E9. For a true
  in-progress series with E1-E5 played and E6+ available, this
  returns E6.

  Returns nil if the user hasn't played anything in the series
  (caller is responsible for filtering down to engaged series).
  """
  def next_unplayed_episode(series_id, auth) do
    episodes =
      Req.get!(base_url() <> "/Shows/" <> series_id <> "/Episodes",
        params: [
          userId: auth.id,
          Fields:
            "Overview,RunTimeTicks,UserData,LocationType,SeriesPrimaryImageTag,DateCreated,PremiereDate"
        ],
        headers: [{"x-emby-token", auth.token}],
        receive_timeout: 15_000
      ).body
      |> case do
        %{"Items" => items} when is_list(items) -> items
        _ -> []
      end
      |> Enum.sort_by(fn ep ->
        {ep["ParentIndexNumber"] || 0, ep["IndexNumber"] || 0}
      end)

    # Furthest-along played episode by viewing order — the last index
    # where Played=true.
    last_played_idx =
      episodes
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {ep, idx}, acc ->
        if get_in(ep, ["UserData", "Played"]) == true, do: idx, else: acc
      end)

    case last_played_idx do
      nil ->
        nil

      idx ->
        episodes
        |> Enum.drop(idx + 1)
        |> Enum.find(fn ep ->
          get_in(ep, ["UserData", "Played"]) != true and
            ep["LocationType"] != "Virtual"
        end)
    end
  rescue
    _ -> nil
  end

  @doc """
  Items the user is mid-watch on — movies with saved positions, plus
  episodes in progress. Includes the SeriesId / SeriesName for
  episodes so the home page can group by show.
  """
  def resume_items(auth) do
    Aviary.Cache.swr(
      {:jellyfin_resume_items, auth.id},
      @userdata_fresh_ms,
      @userdata_stale_ms,
      fn ->
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
    )
  end

  @doc """
  All-shows NextUp — across the user's whole library, return the next
  episode to watch for each show with progress. Used by the home page
  Continue Watching row.
  """
  def next_up_across_library(auth) do
    Aviary.Cache.swr(
      {:jellyfin_next_up_across_library, auth.id},
      @userdata_fresh_ms,
      @userdata_stale_ms,
      fn ->
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
    )
  end

  @doc """
  Returns a `%{jellyfin_series_id => tmdb_id_string | nil}` map for a
  batch of series ids. Uses Jellyfin's `Ids` parameter so the whole
  set is one HTTP call. Series with no TMDB id in their ProviderIds
  map to nil — caller decides whether to filter them out or treat
  them as unmappable.
  """
  def series_tmdb_map(series_ids, auth) when is_list(series_ids) do
    case Enum.uniq(series_ids) do
      [] ->
        %{}

      ids ->
        case Req.get(base_url() <> "/Items",
               params: [Ids: Enum.join(ids, ","), userId: auth.id, Fields: "ProviderIds"],
               headers: [{"x-emby-token", auth.token}],
               receive_timeout: 10_000
             ) do
          {:ok, %Req.Response{status: 200, body: %{"Items" => items}}} when is_list(items) ->
            Map.new(items, fn item ->
              {item["Id"], get_in(item, ["ProviderIds", "Tmdb"])}
            end)

          _ ->
            %{}
        end
    end
  rescue
    _ -> %{}
  end

  @doc """
  Items the user has most recently watched (Played=true), sorted by
  DatePlayed descending. Used by the home page to surface shows where
  the user is caught up — Resume's lingering-ticks artifact would
  otherwise point at the wrong episode, and Latest's "newly added"
  ordering misses pure rewatch activity.
  """
  def recently_watched(auth) do
    Aviary.Cache.swr(
      {:jellyfin_recently_watched, auth.id},
      @userdata_fresh_ms,
      @userdata_stale_ms,
      fn ->
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
    )
  end

  @doc """
  Recently-added episodes — surfaces new episodes that arrived (via
  Sonarr import) since the user last interacted with the show. Sort
  by DateCreated descending on Jellyfin's side.
  """
  def latest_episodes(auth) do
    Aviary.Cache.swr(
      {:jellyfin_latest_episodes, auth.id},
      @userdata_fresh_ms,
      @userdata_stale_ms,
      fn ->
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
    )
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

  @doc """
  Asks Jellyfin to rescan a series' folder right now. Used when
  Sonarr has just imported a new episode file to disk but Jellyfin
  hasn't run its scheduled scan yet — without the nudge, the
  episode sits in our "Importing…" state for however long until
  the scheduled scan fires (often hours). The POST is async on
  Jellyfin's side (it queues the scan task) so it returns
  immediately; the freshly-discovered episode shows up on the
  next aviary poll cycle once Jellyfin's scan worker processes it
  (typically a few seconds).

  `Recursive=true` makes Jellyfin walk the series' folder for new
  files; the other refresh-mode params are deliberately left at
  Jellyfin's defaults so the scan picks up files without
  re-running every metadata provider.
  """
  def refresh_series(series_id, auth) do
    Req.post(base_url() <> "/Items/" <> series_id <> "/Refresh",
      params: [Recursive: true],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :error
  end

  ## Playback state

  @doc """
  Resets a single item to "never watched": canonical mark-unplayed
  (clears Played, PlayCount, LastPlayedDate via DELETE
  /UserPlayedItems) followed by a UserData write that zeroes
  PlaybackPositionTicks so any resume position is gone too. Used
  by the Home page's dismiss action — for shows, see
  `reset_series_progress/2`.

  Two calls is the price of getting Jellyfin's indexes (NextUp,
  recently_watched, Resume) to all reflect the change: a raw
  UserData write to `Played=false` succeeds at the document level
  but those indexes don't all consult it, so the show keeps
  reappearing in Continue Watching.
  """
  def reset_item_progress(item_id, auth) do
    mark_unplayed(item_id, auth)

    Req.post(base_url() <> "/UserItems/" <> item_id <> "/UserData",
      params: [userId: auth.id],
      headers: [{"x-emby-token", auth.token}],
      json: %{"PlaybackPositionTicks" => 0, "PlayedPercentage" => 0},
      receive_timeout: 5_000
    )

    invalidate_user_episode_caches(auth)
    :ok
  rescue
    _ -> :error
  end

  @doc """
  Resets every episode in a series to "never watched". Bounded
  parallelism so a 50-episode show doesn't fire 50 simultaneous
  requests. Used by Home's dismiss action on show tiles.
  """
  def reset_series_progress(series_id, auth) do
    series_id
    |> list_episodes(auth)
    |> Task.async_stream(&reset_item_progress(&1["Id"], auth),
      max_concurrency: 8,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    :ok
  end

  @doc """
  Marks a single item as fully played for the user. Used by the
  watch-mark feature on the show detail page: clicking the marker
  column on episode N fans this call out across episodes 1..N so
  Jellyfin's NextUp moves past the mark and Continue Watching
  surfaces the next-after.

  Uses the canonical `POST /UserPlayedItems/{itemId}` endpoint
  rather than a raw UserData overwrite — the raw write sets the
  `Played` flag but skips the bookkeeping NextUp's index relies on
  (PlayCount, parent-series UnplayedItemCount, UserDataSaved event).
  Without the canonical call, marked-only shows never re-enter
  Continue Watching even when an unwatched episode is in the
  library.
  """
  def mark_played(item_id, auth) do
    Req.post(base_url() <> "/UserPlayedItems/" <> item_id,
      params: [
        userId: auth.id,
        datePlayed: DateTime.utc_now() |> DateTime.to_iso8601()
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 5_000
    )

    # Canonical endpoint sets Played=true but doesn't reliably zero
    # PlaybackPositionTicks. Without this follow-up write, Jellyfin's
    # Resume/NextUp keep treating the episode as in-progress (the
    # symptom that landed E5 in Continue Watching instead of E6).
    Req.post(base_url() <> "/UserItems/" <> item_id <> "/UserData",
      params: [userId: auth.id],
      headers: [{"x-emby-token", auth.token}],
      json: %{"PlaybackPositionTicks" => 0},
      receive_timeout: 5_000
    )

    invalidate_user_episode_caches(auth)
    :ok
  rescue
    _ -> :error
  end

  @doc """
  Inverse of `mark_played/2` — clears Played=true and zeroes PlayCount
  via `DELETE /UserPlayedItems/{itemId}`. Used by the watch-mark
  feature: when the user sets the mark BACKWARD (e.g., from E5 to
  E2), anything past the new mark needs its played state cleared,
  otherwise NextUp correctly concludes the user has nothing left to
  watch.
  """
  def mark_unplayed(item_id, auth) do
    Req.delete(base_url() <> "/UserPlayedItems/" <> item_id,
      params: [userId: auth.id],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 5_000
    )

    invalidate_user_episode_caches(auth)
    :ok
  rescue
    _ -> :error
  end

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

    invalidate_user_episode_caches(auth)
    :ok
  rescue
    _ -> :error
  end

  # Wipe every cached UserData-derived entry for this user after a
  # UserData write (mark_played, mark_unplayed, save_position,
  # reset_item_progress). Without this, the home page mount that
  # follows a watch-mark would serve stale Continue Watching for up
  # to the SWR fresh window — the exact "is this just slow or did
  # my action not register?" jank.
  defp invalidate_user_episode_caches(auth) do
    Aviary.Cache.invalidate_match({:jellyfin_list_episodes, :_, auth.id})
    Aviary.Cache.invalidate({:jellyfin_resume_items, auth.id})
    Aviary.Cache.invalidate({:jellyfin_next_up_across_library, auth.id})
    Aviary.Cache.invalidate({:jellyfin_recently_watched, auth.id})
    Aviary.Cache.invalidate({:jellyfin_latest_episodes, auth.id})
    :ok
  end

  @doc """
  Returns the Intro Skipper plugin's detected segments for an item, or
  nil if the plugin isn't installed / has no data yet for this item.
  Shape: `%{introduction: %{start: 5.0, end: 87.0}}` — currently only
  the introduction segment is surfaced; credits/recap support is a
  future iteration. Times are in seconds.

  The plugin endpoint returns an object with all five segment types
  (Introduction, Credits, Recap, Preview, Commercial), each defaulting
  to `Start: 0, End: 0` when no data exists. We filter those zero
  segments out so callers can treat "no data" as nil.
  """
  def segments(item_id, auth) do
    url = base_url() <> "/Episode/" <> item_id <> "/Timestamps"

    case Req.get(url,
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        build_segments(body)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp build_segments(body) when is_map(body) do
    case to_segment(body["Introduction"]) do
      nil -> nil
      intro -> %{introduction: intro}
    end
  end

  defp build_segments(_), do: nil

  defp to_segment(%{"Start" => start_s, "End" => end_s})
       when is_number(start_s) and is_number(end_s) and end_s > start_s do
    %{start: start_s, end: end_s}
  end

  defp to_segment(_), do: nil

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
  Returns the item's subtitle tracks as `[%{index, lang, label, default}]`,
  empty list when there are none or on error. Each entry corresponds to
  a HTML5 `<track>` element the video player can offer via its native
  CC menu.
  """
  def subtitle_streams(item_id, auth) do
    case Req.get(base_url() <> "/Items",
           params: [Ids: item_id, userId: auth.id, Fields: "MediaStreams"],
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"Items" => [%{"MediaStreams" => streams} | _]}}}
      when is_list(streams) ->
        streams
        |> Enum.filter(&(&1["Type"] == "Subtitle"))
        |> Enum.map(&to_subtitle/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp to_subtitle(stream) do
    %{
      index: stream["Index"],
      lang: stream["Language"] || "und",
      label: stream["DisplayTitle"] || stream["Title"] || "Subtitle",
      default: stream["IsDefault"] == true
    }
  end

  @doc """
  Browser-loadable URL for one subtitle track. Uses the public Jellyfin
  URL (same as HLS) since the video element / browser fetches this
  directly, and `api_key=` in the query string because `<track>` can't
  carry auth headers.
  """
  def subtitle_url(item_id, stream_index, auth) do
    "#{public_url()}/Videos/#{item_id}/#{item_id}/Subtitles/#{stream_index}/0/Stream.vtt?api_key=#{auth.token}"
  end

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
