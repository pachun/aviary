defmodule AviaryWeb.BrandController do
  @moduledoc """
  Serves the PWA web app manifest dynamically so its name, short name,
  and description track the per-instance brand config (the same
  `TAB_TITLE` / `HOME_SCREEN_TITLE` / `SITE_DESCRIPTION` the rest of
  the app reads) instead of being frozen in a static JSON file.

  Public and unauthenticated: the browser fetches the manifest before
  the user signs in, so this route sits outside the auth pipelines.
  """
  use AviaryWeb, :controller

  alias AviaryWeb.Layouts

  @doc """
  Render the web app manifest with the live brand values. Served as
  `application/manifest+json` (the spec MIME) — encoded by hand rather
  than via `json/2` so the content type isn't overridden to
  `application/json`.
  """
  def manifest(conn, _params) do
    body =
      Jason.encode!(%{
        "name" => Layouts.tab_title(),
        "short_name" => Layouts.home_screen_title(),
        "description" => Layouts.site_description(),
        "start_url" => "/",
        "scope" => "/",
        "display" => "standalone",
        "background_color" => "#F2F0E7",
        "theme_color" => "#F2F0E7",
        "orientation" => "portrait",
        "icons" => [
          %{
            "src" => "/images/apple-touch-icon.png",
            "sizes" => "180x180",
            "type" => "image/png",
            "purpose" => "any"
          }
        ]
      })

    conn
    |> put_resp_content_type("application/manifest+json")
    |> send_resp(200, body)
  end
end
