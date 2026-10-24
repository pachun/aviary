import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aviary, AviaryWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "abw3OLqPInrYFiFxxHeZPZHM+4KCY0nu3xe7+RxLPs80jQn46/rnm0Pzv/qwFs1Q",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Route the NHL scraper through Req.Test so specs stub slapstreams.com
config :aviary, :nhl_req_options, plug: {Req.Test, Aviary.Nhl}
config :aviary, Aviary.Nhl.Site, pause_ms: 0
config :aviary, Aviary.Nhl.Schedule, refresh_on_its_own: false

# The downloaders and Jellyfin are stubbed the same way; their addresses
# are set in test/test_helper.exs, after config/runtime.exs has run
config :aviary,
  sonarr_req_options: [plug: {Req.Test, Aviary.Sonarr}],
  sabnzbd_req_options: [plug: {Req.Test, Aviary.Sabnzbd}],
  jellyfin_req_options: [plug: {Req.Test, Aviary.Jellyfin}],
  jellyseerr_req_options: [plug: {Req.Test, Aviary.Jellyseerr}]

config :aviary, Aviary.Repo,
  database: Path.join(System.tmp_dir!(), "aviary-test-#{System.pid()}.db"),
  pool_size: 1
