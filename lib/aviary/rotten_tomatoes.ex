defmodule Aviary.RottenTomatoes do
  @moduledoc """
  Fetches Rotten Tomatoes critic + audience scores for movies and shows.
  RT no longer exposes a usable public API, so we scrape the page's
  embedded JSON. This is fragile to RT changing their site; if scores
  stop appearing, the regexes in extract_score/2 are the first thing
  to look at.

  Caching: ETS table owned by this process, 24h TTL per entry. Cache
  misses fetch from RT; successful fetches and not-found responses are
  both cached so we don't hammer RT for items that have no RT page.

  Resolving the RT page is two-tiered. When the caller passes an IMDb
  id we ask Wikidata for the title's Rotten Tomatoes ID (property
  P1258) — the exact canonical path, including the internal-numeric-id
  slugs (e.g. `/m/1044522-firm` for The Firm) that can't be derived
  from the title. Without an IMDb id, or when Wikidata has no mapping,
  we fall back to guessing the slug from the title: lowercased,
  `&`→"and", apostrophes dropped, other punctuation runs collapsed to
  underscores, with a `<slug>_<year>` retry for titles RT disambiguates
  by year. Items we can't resolve either way return nil.
  """
  use GenServer
  require Logger

  @table :rotten_tomatoes_cache
  @wikidata_table :rotten_tomatoes_wikidata_cache
  @ttl_seconds 24 * 60 * 60
  # imdb→RT-path mappings barely change; cache them for a month
  # (misses included, so we don't re-query Wikidata for every render).
  @wikidata_ttl_seconds 30 * 24 * 60 * 60
  @rt_base "https://www.rottentomatoes.com"
  @ua "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  ## Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Look up cached scores or fetch fresh from RT. Returns
  `%{critic: integer(), audience: integer()}` when both are present, or
  `nil` (item has no RT page, only one score, or fetch failed).
  """
  def fetch(title, type, year \\ nil, imdb_id \\ nil) when type in [:movie, :tv] do
    key = {imdb_id, String.downcase(title), year, type}
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, scores, ts}] when now - ts < @ttl_seconds ->
        scores

      _ ->
        case resolve_and_scrape(title, type, year, imdb_id) do
          %{} = scores ->
            :ets.insert(@table, {key, scores, now})
            scores

          nil ->
            # Don't cache misses. A nil here could mean "no RT page
            # for this title" (legitimate, would benefit from caching)
            # OR "transient failure: scraper got rate-limited / Finch
            # pool was exhausted / HTML changed momentarily" (NOT
            # something we want to cache for 24h). Erring on the side
            # of "retry next time" trades a little extra work for not
            # showing blank badges across an entire Discover row when
            # one page load got unlucky.
            nil
        end
    end
  rescue
    # Scores are auxiliary — never let an RT lookup take down the page
    # that embeds them (e.g. the cache tables not yet existing right
    # after a hot code reload, before the GenServer re-inits).
    e ->
      Logger.warning("RottenTomatoes.fetch crashed: #{inspect(e)}")
      nil
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@wikidata_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internals

  # Prefer the exact canonical page. Wikidata's Rotten Tomatoes ID
  # (P1258), keyed off the title's IMDb id, gives the precise path —
  # including the internal-numeric-id slugs (e.g. "m/1044522-firm") that
  # can't be guessed from the title. Only with no IMDb id or no P1258
  # mapping do we fall back to slug-guessing.
  defp resolve_and_scrape(title, type, year, imdb_id) do
    case rt_path(imdb_id) do
      nil -> scrape(title, type, year)
      path -> scrape_url("#{@rt_base}/#{path}")
    end
  end

  # Try each candidate slug in order, taking the first that yields both
  # scores. The base slug handles the mainstream catalog; the
  # `<slug>_<year>` variant catches titles RT disambiguates by year —
  # either a same-titled older entry stealing the plain slug (e.g.
  # "the_fugitive" serves a 1910 silent short, not the 1993 film) or a
  # 301 to the canonical URL.
  defp scrape(title, type, year) do
    base = slugify(title)

    [base, year && "#{base}_#{year}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(fn slug -> scrape_url(base_url(type) <> slug) end)
  end

  defp scrape_url(url) do
    case Req.get(url, headers: [{"user-agent", @ua}], receive_timeout: 8_000) do
      {:ok, %Req.Response{status: 200, body: html}} ->
        critic = extract_score(html, "criticsScore")
        audience = extract_score(html, "audienceScore")

        if critic && audience do
          %{critic: critic, audience: audience}
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("RottenTomatoes fetch failed for #{inspect(url)}: #{inspect(e)}")
      nil
  end

  # imdb_id → RT path ("m/…" or "tv/…") via Wikidata P1258, cached long.
  # nil (no mapping) is cached too, so we don't re-query every render.
  defp rt_path(imdb_id) when is_binary(imdb_id) do
    if Regex.match?(~r/^tt\d+$/, imdb_id) do
      now = System.system_time(:second)

      case :ets.lookup(@wikidata_table, imdb_id) do
        [{^imdb_id, path, ts}] when now - ts < @wikidata_ttl_seconds ->
          path

        _ ->
          path = wikidata_rt_path(imdb_id)
          :ets.insert(@wikidata_table, {imdb_id, path, now})
          path
      end
    end
  end

  defp rt_path(_), do: nil

  # Ask Wikidata for the entity whose IMDb id (P345) matches, and return
  # its Rotten Tomatoes ID (P1258) — e.g. "m/1044522-firm", "tv/the_bear".
  defp wikidata_rt_path(imdb_id) do
    query =
      ~s|SELECT ?rt WHERE { ?item wdt:P345 "#{imdb_id}". ?item wdt:P1258 ?rt. } LIMIT 1|

    case Req.get("https://query.wikidata.org/sparql",
           params: [query: query, format: "json"],
           headers: [{"user-agent", @ua}, {"accept", "application/sparql-results+json"}],
           receive_timeout: 8_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_rt_path(body)
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Wikidata RT lookup failed for #{imdb_id}: #{inspect(e)}")
      nil
  end

  defp parse_rt_path(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_rt_path(decoded)
      _ -> nil
    end
  end

  defp parse_rt_path(%{"results" => %{"bindings" => [%{"rt" => %{"value" => path}} | _]}}),
    do: path

  defp parse_rt_path(_), do: nil

  defp base_url(:movie), do: "#{@rt_base}/m/"
  defp base_url(:tv), do: "#{@rt_base}/tv/"

  defp extract_score(html, key) do
    # The embedded JSON has the shape
    #   "criticsScore":{...,"score":"91",...}
    # and similarly for audienceScore. We don't bother parsing the
    # whole document — a non-greedy regex up to the score field is
    # enough and resilient to other adjacent fields being added.
    pattern = ~r/"#{key}":\{[^{}]*?"score":"(\d+)"/

    case Regex.run(pattern, html) do
      [_, score] -> String.to_integer(score)
      _ -> nil
    end
  end

  # Mirror RT's slug rule rather than just stripping punctuation: "&"
  # becomes "and" (fast_and_furious), apostrophes are dropped
  # (oceans_eleven), and every other run of non-alphanumerics collapses
  # to a single underscore (bat_21, spider_man, mission_impossible,
  # wall_e). The old strip-everything rule missed all of those.
  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end
end
