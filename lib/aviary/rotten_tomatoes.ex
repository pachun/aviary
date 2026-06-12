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

  Slug generation is the lookup mechanism — RT URLs are
  `/m/<slug>` for movies and `/tv/<slug>` for shows where `<slug>` is
  the lowercased title with non-word chars stripped and spaces turned
  into underscores. Works for the mainstream catalog; obscure or
  ambiguously-titled items may slug-miss and just return nil.
  """
  use GenServer
  require Logger

  @table :rotten_tomatoes_cache
  @ttl_seconds 24 * 60 * 60
  @ua "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  ## Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Look up cached scores or fetch fresh from RT. Returns
  `%{critic: integer(), audience: integer()}` when both are present, or
  `nil` (item has no RT page, only one score, or fetch failed).
  """
  def fetch(title, type) when type in [:movie, :tv] do
    key = {String.downcase(title), type}
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, scores, ts}] when now - ts < @ttl_seconds ->
        scores

      _ ->
        case scrape(title, type) do
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
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  ## Internals

  defp scrape(title, type) do
    url = base_url(type) <> slugify(title)

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
      Logger.warning("RottenTomatoes fetch failed for #{inspect(title)}: #{inspect(e)}")
      nil
  end

  defp base_url(:movie), do: "https://www.rottentomatoes.com/m/"
  defp base_url(:tv), do: "https://www.rottentomatoes.com/tv/"

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

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, "")
    |> String.replace(~r/\s+/, "_")
    |> String.trim("_")
  end
end
