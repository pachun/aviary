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
        # ProviderIds carries the TMDB id we use to resolve a discover-
        # source movie (URL is its TMDB id) back to its Jellyfin
        # counterpart once Jellyfin sees the freshly-imported file.
        # Without it the MoviesDetailLive poll loop can never flip
        # "Importing…" to "Play" — the lookup walks this list comparing
        # `nil` to the TMDB id and never matches.
        Fields: "ProductionYear,ProviderIds"
      )
      |> Map.fetch!("Items")
    end)
  end

  @doc """
  Like list_movies/1 but also returns MediaSources so callers can sum
  file sizes (Storage stats panel). MediaSources adds ~1KB per movie
  to the response so we don't fold it into the everyday list_movies
  read — it's only worth the bytes when sizes are actually consumed.
  """
  def list_movies_with_sizes(auth) do
    Aviary.Cache.swr(
      {:jellyfin_list_movies_sized, auth.id},
      @catalog_fresh_ms,
      @catalog_stale_ms,
      fn ->
        get!(@api_path, auth,
          IncludeItemTypes: "Movie",
          Recursive: true,
          Fields: "ProviderIds,MediaSources"
        )
        |> Map.fetch!("Items")
      end
    )
  end

  @doc """
  All episodes across all series with their parent SeriesId + file
  sizes. Single recursive read — much cheaper than walking
  list_episodes/2 per series. Used by Storage stats to roll up
  per-show file size from episode files.
  """
  def list_all_episodes_with_sizes(auth) do
    Aviary.Cache.swr(
      {:jellyfin_list_episodes_sized, auth.id},
      @catalog_fresh_ms,
      @catalog_stale_ms,
      fn ->
        get!(@api_path, auth,
          IncludeItemTypes: "Episode",
          Recursive: true,
          Fields: "SeriesId,MediaSources"
        )
        |> Map.fetch!("Items")
      end
    )
  end

  @doc """
  All Jellyfin users — Id + Name. Used by the Storage stats panel to
  resolve `library_entries.jellyfin_user_id` to the human username for
  the per-user color legend. /Users is readable by any authenticated
  Jellyfin user (it's what the login screen uses), so this works
  regardless of admin status.
  """
  def list_users(auth) do
    Req.get!(base_url() <> "/Users",
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 15_000
    ).body
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
  Asks Jellyfin to rescan all libraries right now via
  `/Library/Refresh`. Used when Sonarr has just imported a new
  episode but Jellyfin hasn't seen it yet — without the nudge,
  the chip can sit on "Importing…" until Jellyfin's scheduled
  scan fires (12 h default).

  Why a library-wide scan instead of the more surgical
  `/Library/Media/Updated` with a path: depot's compose files
  bind-mount the shows directory at different in-container
  paths for Sonarr (`/shows`) and Jellyfin (`/media/shows`). A
  path-targeted scan needs the path Jellyfin understands, and
  Sonarr's path doesn't translate without configuration in
  aviary. `/Library/Refresh` sidesteps the path-translation
  problem entirely — Jellyfin scans every library and finds
  files wherever they actually are.

  Trade-off: it's a heavier scan. Throttled at the caller (15 s
  per process via `Aviary.Cache.fetch`) so we don't fire it
  every poll tick, and Jellyfin's task scheduler dedupes
  concurrent triggers.
  """
  def refresh_library(auth) do
    Req.post(base_url() <> "/Library/Refresh",
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 5_000
    )

    :ok
  rescue
    _ -> :error
  end

  @doc """
  Heavy refresh on a single series — `MetadataRefreshMode=FullRefresh`
  + `ReplaceAllMetadata=true` together. Empirically the only thing
  that unsticks Jellyfin when its scanner has cached a "skip this
  series" decision and `/Library/Refresh` no longer touches the
  underlying files: it forces Jellyfin to throw out its existing
  series record and rebuild from scratch, which re-walks the disk
  and picks up any episode files it had given up on.

  Expensive (re-fetches metadata from providers, refreshes images).
  Caller should throttle aggressively — once per series per ~10
  minutes is plenty.

  Used as the auto-retry path when an episode stays in `:imported`
  state for more than ~2 minutes, suggesting the cheap
  `/Library/Refresh` couldn't get Jellyfin to notice the file.
  """
  def full_refresh_series(series_id, auth) do
    Req.post(base_url() <> "/Items/" <> series_id <> "/Refresh",
      params: [
        Recursive: true,
        MetadataRefreshMode: "FullRefresh",
        ImageRefreshMode: "Default",
        ReplaceAllMetadata: true,
        ReplaceAllImages: false
      ],
      headers: [{"x-emby-token", auth.token}],
      receive_timeout: 10_000
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

  @doc """
  Records a single progress report from a player. Past 95% of the
  runtime the item is treated as finished (`mark_played` — the
  canonical write that moves Jellyfin's NextUp on to the next
  episode); otherwise the partial position is saved. Returns
  `:played` or `:in_progress` so callers can update their own view of
  the item to match.

  Shared by the LiveView web player (`report_progress` event) and the
  native-client progress API so both branch identically.
  """
  def report_progress(item_id, position, duration, auth)
      when is_number(position) do
    if is_number(duration) and duration > 0 and position / duration >= 0.95 do
      mark_played(item_id, auth)
      :played
    else
      save_position(item_id, trunc(position * 10_000_000), auth)
      :in_progress
    end
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

  @doc """
  Fetches a Jellyfin user's avatar (PrimaryImage) as bytes +
  content-type. Source endpoint is `/Users/{userId}/Images/Primary`
  and doesn't require auth — Jellyfin treats user avatars as
  semi-public (they show on Jellyfin's own login screen).
  """
  def fetch_user_image(user_id) do
    url = "#{base_url()}/Users/#{user_id}/Images/Primary?maxWidth=200"

    case Req.get(url, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        {:ok, body, content_type(headers)}

      _ ->
        :error
    end
  end

  ## Video stream

  @doc """
  Returns the item's ENGLISH subtitle tracks as
  `[%{index, lang, label, default}]`, empty list when there are none or
  on error. Each entry corresponds to a track a player can offer via
  its CC menu.

  English-only is a deliberate product policy, applied here so every
  surface (web player, native API, tvOS) offers the same one language —
  the household only reads English, and surfacing the source's other
  language tracks (Chinese, etc.) is exactly the menu clutter we're
  removing. `english?/1` is the single place that decision lives.
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
        |> Enum.filter(&english?/1)
        |> Enum.map(&to_subtitle/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # English by language code (eng/en), or — when the source left the
  # language undetermined — by an "English" mention in the track's
  # human label. Everything else (Chinese, Polish, …) is filtered out.
  defp english?(stream) do
    lang = stream["Language"] |> to_string() |> String.downcase()

    label =
      [stream["DisplayTitle"], stream["Title"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    lang in ["en", "eng"] or
      (lang in ["", "und"] and String.contains?(label, "english"))
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
  Returns the item's audio tracks as
  `[%{index, lang, label, default, description?}]`, empty list on
  error. `description?` flags Audio Description streams (a narration
  track for visually-impaired viewers) so callers can prefer the
  non-description track as the default — Jellyfin will otherwise
  occasionally pick the description track on content (Apple TV+
  shows in particular) that flags it `IsDefault`.
  """
  def audio_streams(item_id, auth) do
    case Req.get(base_url() <> "/Items",
           params: [Ids: item_id, userId: auth.id, Fields: "MediaStreams"],
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"Items" => [%{"MediaStreams" => streams} | _]}}}
      when is_list(streams) ->
        streams
        |> Enum.filter(&(&1["Type"] == "Audio"))
        |> Enum.map(&to_audio/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp to_audio(stream) do
    %{
      index: stream["Index"],
      lang: stream["Language"] || "und",
      label: stream["DisplayTitle"] || stream["Title"] || "Audio",
      default: stream["IsDefault"] == true,
      # Channel count drives the surround-preference pick in
      # default_audio_index — higher is better (5.1 > stereo).
      # Default to 0 when missing so multichannel tracks always
      # outrank a track without metadata.
      channels: stream["Channels"] || 0,
      description?: audio_description?(stream)
    }
  end

  # Audio Description tracks ship with Apple TV+ content (Silo, Severance,
  # etc.) and many newer films. Jellyfin sometimes picks them as the
  # default audio track — the user hears a narrator describe what's on
  # screen instead of dialogue. Detect by the well-known fields first
  # (DispositionFlags, Role); fall back to the human-readable label
  # since older Jellyfin builds don't always populate the flags.
  defp audio_description?(stream) do
    disposition = stream["DispositionFlags"] || ""
    role = stream["Role"] || ""

    haystack =
      [
        stream["DisplayTitle"],
        stream["Title"],
        stream["Profile"]
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(String.downcase(to_string(disposition)), "description") or
      String.downcase(to_string(role)) == "description" or
      String.contains?(haystack, "description") or
      String.contains?(haystack, "descriptive") or
      String.contains?(haystack, "narration") or
      String.contains?(haystack, "[ad]") or
      String.contains?(haystack, "(ad)")
  end

  @doc """
  Picks the audio stream index aviary should default to. Selection
  priority (highest first):

    1. Most channels (5.1 > stereo). Households with surround setups
       prefer the multichannel track; stereo-only browsers downmix
       the multichannel stream automatically so there's no penalty
       for picking it as the default.
    2. Among same-channel-count tracks, prefer the one Jellyfin
       marks `IsDefault`.
    3. Among same-channel + same-default tracks, take the first by
       order in the file.

  Audio-description tracks are excluded before sorting. Returns nil
  when the list is empty.
  """
  def default_audio_index([]), do: nil

  def default_audio_index(streams) do
    non_desc = Enum.reject(streams, & &1.description?)

    chosen =
      (non_desc != [] && non_desc) || streams

    chosen
    |> Enum.sort_by(
      fn s -> {-s.channels, if(s.default, do: 0, else: 1), s.index} end
    )
    |> List.first()
    |> case do
      nil -> nil
      track -> track.index
    end
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
  # The total stream bitrate cap aviary asks Jellyfin to respect.
  # Jellyfin's server-side RemoteClientBitrateLimit is a hint —
  # the client (this URL) has to actually request a cap for the
  # transcode pipeline to fall into a fit-the-bitrate path. Without
  # MaxStreamingBitrate in the URL, Jellyfin video-copies the source
  # (25+ Mbps for a 1080p REMUX), which then can't fit through the
  # household's ~20 Mbps upload when the viewer is reaching aviary
  # via Cloudflare Tunnel.
  #
  # 8 Mbps fits two concurrent streams in 20 Mbps with headroom. All
  # viewers get this cap currently — a follow-up should detect
  # LAN/tailnet viewers and skip the cap for them (full quality with
  # direct play / hardware-fast transcode), reserving the cap for
  # genuinely-remote viewers arriving through Cloudflare.
  @max_streaming_bitrate 8_000_000

  def hls_url(item_id, auth, _audio_stream_index \\ nil) do
    query = URI.encode_query(transcode_params(item_id, auth, nil))
    "#{public_url()}/Videos/#{item_id}/master.m3u8?#{query}"
  end

  # Shared transcode params for both the direct HLS URL (web `<track>`
  # player) and the rewritten manifest (native players). When
  # `subtitle_index` is given, Jellyfin includes the item's subtitle
  # streams as in-manifest HLS renditions (SubtitleMethod=Hls); nil
  # omits subtitles entirely.
  defp transcode_params(item_id, auth, subtitle_index) do
    session_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    # Video bitrate target — leaves ~500 Kbps headroom for audio
    # under the total stream cap.
    video_bitrate = @max_streaming_bitrate - 500_000

    base = %{
      "api_key" => auth.token,
      "MediaSourceId" => item_id,
      "PlaySessionId" => session_id,
      "DeviceId" => "aviary",
      "VideoCodec" => "h264",
      "AudioCodec" => "aac",
      "SegmentContainer" => "ts",
      # Without Static=false, Jellyfin's HLS endpoint defaults to a
      # DirectStream path (video copy + audio transcode) and silently
      # bypasses the bitrate cap. The "FFmpeg.DirectStream-..."
      # filenames in jellyfin/log/ are the giveaway. Static=false
      # tells Jellyfin "don't take the copy shortcut"; VideoBitRate
      # then nails the encoder to a specific output bitrate so the
      # cap actually bites.
      "Static" => "false",
      "VideoBitRate" => Integer.to_string(video_bitrate),
      "MaxStreamingBitrate" => Integer.to_string(@max_streaming_bitrate),
      # Stereo cap stays at 2 channels. An earlier change bumped this
      # to 6 + added `eac3,ac3` to the codec list to enable household
      # surround for Lovesac/5.1 setups — but Jellyfin's playback
      # decision pipeline flipped some titles into a transcode path
      # the browser couldn't fulfill, killing playback. The surround
      # work needs a more careful re-introduction (probably matching
      # per-source codec capabilities + a fallback chain), so it's
      # reverted to the known-working minimum.
      "MaxAudioChannels" => "2",
      "TranscodingMaxAudioChannels" => "2"
    }

    case subtitle_index do
      nil ->
        base

      idx ->
        Map.merge(base, %{
          "SubtitleStreamIndex" => Integer.to_string(idx),
          "SubtitleMethod" => "Hls"
        })
    end
  end

  @doc """
  Returns a rewritten HLS master playlist as a string (or `:error`),
  carrying the household's subtitle policy the native players honor:
  English-only, off by default.

  Jellyfin's own master playlist can't express that. Asking for the
  English track makes Jellyfin emit EVERY subtitle language as a
  rendition and flag the requested one `DEFAULT=YES` (auto-on). So we
  fetch it, keep only the English subtitle line forced to
  `DEFAULT=NO,AUTOSELECT=NO` (present but off until the viewer picks
  it), drop the other languages, and rewrite the now-relative
  variant/subtitle URIs to absolute public Jellyfin URLs — the client
  still streams segments straight from Jellyfin, so aviary only ever
  proxies this small text playlist, never the video.
  """
  def hls_manifest(item_id, auth) do
    subtitle_index =
      case subtitle_streams(item_id, auth) do
        [%{index: idx} | _] -> idx
        _ -> nil
      end

    query = URI.encode_query(transcode_params(item_id, auth, subtitle_index))
    url = "#{base_url()}/Videos/#{item_id}/master.m3u8?#{query}"

    case Req.get(url,
           headers: [{"x-emby-token", auth.token}],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, rewrite_manifest(body, item_id)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp rewrite_manifest(body, item_id) do
    prefix = "#{public_url()}/Videos/#{item_id}/"

    body
    |> String.split("\n")
    |> Enum.flat_map(&rewrite_manifest_line(&1, prefix))
    |> Enum.join("\n")
  end

  # Subtitle rendition lines: keep only the English one, force it off by
  # default, and absolutize its URI. Every other language is dropped.
  defp rewrite_manifest_line("#EXT-X-MEDIA:TYPE=SUBTITLES" <> _ = line, prefix) do
    if String.contains?(line, ~s(LANGUAGE="eng")) do
      forced_off =
        line
        |> String.replace("DEFAULT=YES", "DEFAULT=NO")
        |> String.replace("AUTOSELECT=YES", "AUTOSELECT=NO")

      [absolutize_uri(forced_off, prefix)]
    else
      []
    end
  end

  # A bare relative line (no leading #) is the variant playlist URI —
  # make it absolute so the client fetches it straight from Jellyfin.
  # Everything else (tags, blanks) passes through untouched.
  defp rewrite_manifest_line(line, prefix) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> [line]
      String.starts_with?(trimmed, "#") -> [line]
      true -> [prefix <> trimmed]
    end
  end

  defp absolutize_uri(line, prefix) do
    Regex.replace(~r/URI="([^"]+)"/, line, fn _, uri -> ~s(URI="#{prefix}#{uri}") end)
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
