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
  Browser-loadable poster URL for an item. Embeds the API key in the
  query string so <img src> can hit it directly without proxying.
  """
  def poster_url(item_id, opts \\ []) do
    max_width = Keyword.get(opts, :max_width, 400)

    "#{base_url()}/Items/#{item_id}/Images/Primary?api_key=#{api_key()}&maxWidth=#{max_width}"
  end

  defp get!(path, params) do
    Req.get!(base_url() <> path,
      params: params,
      headers: [{"x-emby-token", api_key()}],
      receive_timeout: 15_000
    ).body
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
