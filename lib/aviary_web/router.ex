defmodule AviaryWeb.Router do
  use AviaryWeb, :router

  import AviaryWeb.UserAuth,
    only: [
      fetch_current_user: 2,
      redirect_if_user_is_authenticated: 2,
      require_authenticated_user: 2
    ]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AviaryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  ## Public — login form / submit / logout

  scope "/", AviaryWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", AviaryWeb do
    pipe_through :browser

    delete "/logout", SessionController, :delete
  end

  ## Authenticated routes — everything else

  scope "/", AviaryWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home

    live_session :authenticated,
      on_mount: [{AviaryWeb.UserAuth, :require_authenticated}] do
      live "/home", HomeLive, :index
      live "/discover", DiscoverLive, :index
      live "/library", LibraryLive, :index
      live "/shows/:id", ShowsDetailLive, :show
      live "/movies/:id", MoviesDetailLive, :show
    end

    get "/image/:item_id", ImageController, :show
  end

  if Application.compile_env(:aviary, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AviaryWeb.Telemetry
    end
  end
end
