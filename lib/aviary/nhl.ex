defmodule Aviary.Nhl do
  @moduledoc """
  Today's NHL games and their live streams, sourced from slapstreams.com.

  The site is scraped, not queried: the schedule is a table on the
  homepage, each game's watch page lists up to four feed buttons, and
  each feed is a player frame that asks a lookup endpoint for a signed
  CDN URL. That URL lives about two minutes and redirects to the media
  playlist on a second host, whose segment paths are relative. So aviary
  serves the playlist itself: it resolves the media playlist URL once,
  keeps it while it works, rewrites the segment paths to absolute, and
  resolves again when the upstream stops answering. The Apple TV reloads
  the playlist from aviary every few seconds and fetches video straight
  from the upstream host.

  Everything here degrades to "no games" or `{:error, reason}`. The
  home page and nav gate on the result, so a site outage or a markup
  change must never raise into them.
  """
  require Logger

  alias Aviary.Cache
  alias Aviary.Nhl.Page

  @site "https://slapstreams.com"
  # The site's bot check challenges any client that claims to be a
  # browser but doesn't behave like one, and answered aviary's Chrome
  # user agent with a reCAPTCHA page from every address, home and VPN
  # alike. Plain command-line identities pass, so this is the one
  # aviary sends.
  @user_agent "curl/8.10.1"
  @request_timeout_ms 8_000
  @schedule_fresh_ms :timer.minutes(2)
  @schedule_stale_ms :timer.minutes(30)
  @feeds_fresh_ms :timer.minutes(10)
  @feeds_stale_ms :timer.hours(6)
  @media_url_ttl_ms :timer.hours(6)
  @logo_ttl_ms :timer.hours(24)
  @ban_hold_off_ms :timer.minutes(20)
  @logo_cdn_sets %{
    light: "https://a.espncdn.com/i/teamlogos/nhl/500",
    dark: "https://a.espncdn.com/i/teamlogos/nhl/500-dark"
  }
  @logo_cdn_abbreviations %{
    "anaheim-ducks" => "ana",
    "boston-bruins" => "bos",
    "buffalo-sabres" => "buf",
    "calgary-flames" => "cgy",
    "carolina-hurricanes" => "car",
    "chicago-blackhawks" => "chi",
    "colorado-avalanche" => "col",
    "columbus-blue-jackets" => "cbj",
    "dallas-stars" => "dal",
    "detroit-red-wings" => "det",
    "edmonton-oilers" => "edm",
    "florida-panthers" => "fla",
    "los-angeles-kings" => "la",
    "minnesota-wild" => "min",
    "montreal-canadiens" => "mtl",
    "nashville-predators" => "nsh",
    "new-jersey-devils" => "nj",
    "new-york-islanders" => "nyi",
    "new-york-rangers" => "nyr",
    "ottawa-senators" => "ott",
    "philadelphia-flyers" => "phi",
    "pittsburgh-penguins" => "pit",
    "san-jose-sharks" => "sj",
    "seattle-kraken" => "sea",
    "st-louis-blues" => "stl",
    "tampa-bay-lightning" => "tb",
    "toronto-maple-leafs" => "tor",
    "utah-hockey-club" => "utah",
    "utah-mammoth" => "utah",
    "vancouver-canucks" => "van",
    "vegas-golden-knights" => "vgk",
    "washington-capitals" => "wsh",
    "winnipeg-jets" => "wpg"
  }
  @feed_id ~r{^[a-z0-9_-]+$}
  @quoted_uri ~r{URI="([^"]+)"}

  @doc """
  Today's games in schedule order, each with its feeds:
  `%{id, time, away_team, home_team, feeds: [%{id, label}]}`, where each
  team is `%{id, name, nickname, logo}`. Empty on any failure.
  """
  def games do
    Cache.swr({:nhl, :games}, @schedule_fresh_ms, @schedule_stale_ms, &fetch_games/0)
  end

  @doc """
  A team's PNG logo as `{:ok, png}`, fetched from ESPN's CDN and kept for
  a day. `background` picks the set drawn for a light or a dark surface;
  the dark set swaps navy wordmarks like the Capitals' for ones that
  read on a dark screen. `:error` for a slug that isn't an NHL team or
  when the CDN doesn't answer.
  """
  def logo(team_id, background \\ :light) do
    with {:ok, abbreviation} <- Map.fetch(@logo_cdn_abbreviations, team_id),
         {:ok, cdn} <- Map.fetch(@logo_cdn_sets, background) do
      Cache.fetch({:nhl, :logo, background, team_id}, @logo_ttl_ms, fn ->
        get_body("#{cdn}/#{abbreviation}.png")
      end)
    end
  end

  @doc """
  The current media playlist for one feed of one game, with every
  segment path made absolute so it plays from anywhere:
  `{:ok, m3u8}`, `{:error, :not_live}` when the feed exists but hasn't
  started broadcasting, or `{:error, :unavailable}` for an unknown game
  or feed, or a site failure.
  """
  def playlist(game_id, feed_id, rewrite_media_url \\ &Function.identity/1) do
    if known_feed?(game_id, feed_id) do
      playlist_from_media_url(game_id, feed_id, rewrite_media_url, _retries_left = 1)
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Fetches one media file (a segment or a key) of a feed on the viewer's
  behalf, for players that can't reach the media host themselves: iOS
  Safari's native player sends the page as Referer, which the host
  rejects. Only URLs on the feed's own media host are relayed, so this
  can't be used as a general proxy. `{:ok, %{body, content_type}}` or
  `:error`.
  """
  def segment(game_id, feed_id, url) do
    with true <- known_feed?(game_id, feed_id),
         {:ok, media_url} <- cached_media_url(game_id, feed_id),
         true <- same_host?(url, media_url),
         {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) <-
           request(url, referer: nil) do
      {:ok, %{body: body, content_type: content_type(response)}}
    else
      _ -> :error
    end
  end

  defp known_feed?(game_id, feed_id) do
    Regex.match?(@feed_id, feed_id) and feed_id in feed_ids(game_id)
  end

  defp same_host?(url, other_url), do: URI.parse(url).host == URI.parse(other_url).host

  defp content_type(%Req.Response{} = response) do
    case Req.Response.get_header(response, "content-type") do
      [type | _] -> type
      [] -> "application/octet-stream"
    end
  end

  defp cached_media_url(game_id, feed_id) do
    Cache.fetch({:nhl, :media_url, feed_id}, @media_url_ttl_ms, fn ->
      resolve_media_url(game_id, feed_id)
    end)
  end

  defp playlist_from_media_url(game_id, feed_id, rewrite_media_url, retries_left) do
    key = {:nhl, :media_url, feed_id}

    with {:ok, url} <- cached_media_url(game_id, feed_id),
         {:ok, body} when body != "" <- get_body(url) do
      {:ok, absolutize(body, url, rewrite_media_url)}
    else
      {:error, :not_live} ->
        Cache.invalidate(key)
        {:error, :not_live}

      _ when retries_left > 0 ->
        Cache.invalidate(key)
        playlist_from_media_url(game_id, feed_id, rewrite_media_url, retries_left - 1)

      _ ->
        Cache.invalidate(key)
        {:error, :unavailable}
    end
  end

  defp resolve_media_url(game_id, feed_id) do
    with false <- site_banned_us?(),
         {:ok, frame_html} <- get_body(frame_url(feed_id), referer: watch_page_url(game_id)),
         {:ok, params} <- Page.lookup_params(frame_html),
         {:ok, signed_url} <- lookup_signed_url(params, feed_id),
         {:ok, response} <- request(signed_url, redirect: false) do
      case response do
        %Req.Response{status: 302, headers: %{"location" => [media_url]}} -> {:ok, media_url}
        %Req.Response{status: 200, body: ""} -> {:error, :not_live}
        %Req.Response{status: 200} -> {:ok, signed_url}
        other -> log_failure("signed playlist", other)
      end
    end
  end

  defp absolutize(playlist, base_url, rewrite_media_url) do
    resolve = fn uri -> uri |> absolute(base_url) |> rewrite_media_url.() end

    playlist
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "#" <> _ = tag ->
        Regex.replace(@quoted_uri, tag, fn _, uri -> ~s(URI="#{resolve.(uri)}") end)

      "" ->
        ""

      uri ->
        resolve.(String.trim(uri))
    end)
  end

  defp absolute(uri, base_url), do: base_url |> URI.merge(uri) |> URI.to_string()

  # Team pages are fetched one at a time on purpose. The site runs
  # behind LiteSpeed, which answers a burst of simultaneous connections
  # from one address with a reCAPTCHA page for everything that follows,
  # and a cold start used to open a dozen at once.
  defp fetch_games do
    with false <- site_banned_us?(),
         {:ok, html} <- get_body(@site <> "/") do
      html
      |> Page.games()
      |> Enum.filter(&scheduled_today?/1)
      |> Enum.map(&Map.put(&1, :feeds, named_feeds(&1)))
      |> Enum.map(&Map.delete(&1, :date))
    else
      _ -> []
    end
  end

  defp scheduled_today?(%{date: nil}), do: true
  defp scheduled_today?(%{date: date}), do: Date.compare(date, Aviary.LocalTime.today()) == :eq

  # The site labels feeds by broadcaster side (HOME, AWAY) and then
  # LINK 3, LINK 4. Viewers pick by team, so the two sides take the
  # teams' nicknames, away first to match "Rangers @ Red Wings", and the
  # rest become backups.
  defp named_feeds(game) do
    feeds = feeds(game.id)
    away = Enum.filter(feeds, &(&1.label == "AWAY"))
    home = Enum.filter(feeds, &(&1.label == "HOME"))
    backups = feeds -- (away ++ home)

    Enum.map(away, &%{&1 | label: game.away_team.nickname}) ++
      Enum.map(home, &%{&1 | label: game.home_team.nickname}) ++
      Enum.with_index(backups, fn feed, index -> %{feed | label: backup_label(index)} end)
  end

  defp backup_label(0), do: "Backup"
  defp backup_label(index), do: "Backup #{index + 1}"

  defp feeds(game_id) do
    Cache.swr({:nhl, :feeds, game_id}, @feeds_fresh_ms, @feeds_stale_ms, fn ->
      case get_body(watch_page_url(game_id)) do
        {:ok, html} -> Page.feeds(html)
        _ -> []
      end
    end)
  end

  defp feed_ids(game_id) do
    case Enum.find(games(), &(&1.id == game_id)) do
      %{feeds: feeds} -> Enum.map(feeds, & &1.id)
      nil -> []
    end
  end

  defp lookup_signed_url(params, feed_id) do
    case request(@site <> "/stream/check_stream.php", params: params, referer: frame_url(feed_id)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> url_from_json(body)
      other -> log_failure("stream lookup", other)
    end
  end

  defp url_from_json(body) do
    case Jason.decode(body) do
      {:ok, %{"url" => url}} when is_binary(url) -> {:ok, url}
      _ -> :error
    end
  end

  defp get_body(url, options \\ []) do
    case request(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 403}} = refusal ->
        if String.starts_with?(url, @site), do: remember_ban()
        log_failure(url, refusal)

      other ->
        log_failure(url, other)
    end
  end

  # LiteSpeed bans an address that keeps connecting while banned, and
  # the ban lasts longer each time, so once the site answers 403 nothing
  # touches it again for a while. Playlists already resolved keep
  # playing; they don't go through the site.
  defp site_banned_us?, do: Cache.fetch({:nhl, :banned}, @ban_hold_off_ms, fn -> false end)

  defp remember_ban do
    Cache.invalidate({:nhl, :banned})
    Cache.fetch({:nhl, :banned}, @ban_hold_off_ms, fn -> true end)
  end

  defp log_failure(what, outcome) do
    Logger.warning("nhl: #{what} failed: #{inspect(outcome, limit: 5, printable_limit: 200)}")
    :error
  end

  defp request(url, options) do
    {referer, options} = Keyword.pop(options, :referer, @site <> "/")
    referer_header = if referer, do: [{"referer", referer}], else: []

    [
      url: url,
      headers: [{"user-agent", @user_agent} | referer_header],
      receive_timeout: @request_timeout_ms,
      retry: false,
      decode_body: false
    ]
    |> Keyword.merge(proxy_options(url))
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:aviary, :nhl_req_options, []))
    |> Req.new()
    |> Req.request()
  rescue
    error -> {:error, error}
  end

  # Only the stream site itself goes through the proxy. The CDN and the
  # media host hand out tokens the Apple TV then uses from the
  # household's own address, so those requests leave from the same
  # address the TV will.
  defp proxy_options(url) do
    with true <- String.starts_with?(url, @site),
         proxy_url when is_binary(proxy_url) <- Application.get_env(:aviary, :nhl_proxy_url),
         %URI{host: host, port: port} when is_binary(host) <- URI.parse(proxy_url) do
      [connect_options: [proxy: {:http, host, port, []}]]
    else
      _ -> []
    end
  end

  defp watch_page_url(game_id), do: "#{@site}/#{game_id}-live/"
  defp frame_url(feed_id), do: "#{@site}/stream/#{feed_id}.html"
end
