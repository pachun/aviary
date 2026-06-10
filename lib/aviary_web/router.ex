defmodule AviaryWeb.Router do
  use AviaryWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AviaryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AviaryWeb do
    pipe_through :browser

    # Root is Shows — there's no "home" page. Single source of truth
    # for the section nav: the masthead links here and the user's
    # mental model is "I opened Aviary, here are the shows."
    # Bare root just redirects to /shows so there's exactly one
    # canonical URL per section. The nav link in the masthead points
    # at /shows directly; iOS's PWA scope check then sees consistent
    # URLs whether the user landed via the home-screen icon or any
    # in-app nav. The redirect is for direct visits / shared links.
    get "/", PageController, :home

    live "/shows", ShowsLive, :index
    live "/movies", MoviesLive, :index
    live "/movies/:id", MoviesDetailLive, :show

    # Poster image proxy — keeps Jellyfin's URL + API key server-side.
    get "/image/:item_id", ImageController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", AviaryWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:aviary, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AviaryWeb.Telemetry
    end
  end
end
