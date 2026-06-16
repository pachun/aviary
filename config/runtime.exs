import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/aviary start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :aviary, AviaryWeb.Endpoint, server: true
end

config :aviary, AviaryWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Jellyfin integration — reads URL + API key from env vars in every
# environment. Dev: source .env.local (or use direnv) and run mix
# phx.server. Prod: depot's aviary/configure.sh writes them into the
# container's env. Either way, Aviary.Jellyfin reaches for them via
# Application.fetch_env!/2.
config :aviary,
  jellyfin_url: System.get_env("JELLYFIN_URL"),
  jellyfin_api_key: System.get_env("JELLYFIN_API_KEY"),
  # Browser-facing Jellyfin URL — must be reachable from the
  # laptop/phone running the player, not just from inside the docker
  # network. In dev, JELLYFIN_URL already points at the Tailscale
  # address so it doubles for both. In prod, JELLYFIN_URL is the
  # internal host.docker.internal but the browser still needs the
  # Tailscale URL, so JELLYFIN_PUBLIC_URL is set separately by
  # depot's configure.sh. Falls back to JELLYFIN_URL when unset.
  jellyfin_public_url:
    System.get_env("JELLYFIN_PUBLIC_URL") || System.get_env("JELLYFIN_URL"),
  # Jellyseerr feeds the release-calendar widget — next-episode air
  # dates pulled via Jellyseerr's TMDB sync. Optional; when unset,
  # the show detail page falls back to the trailer treatment in all
  # cases.
  jellyseerr_url: System.get_env("JELLYSEERR_URL"),
  jellyseerr_api_key: System.get_env("JELLYSEERR_API_KEY"),
  # Sonarr is what makes the Watch buttons actually do anything — it
  # accepts the "add this series / monitor this season / search this
  # episode" intents from aviary and runs the download. Without it,
  # Watch buttons fall through to "not in your library yet" flashes.
  sonarr_url: System.get_env("SONARR_URL"),
  sonarr_api_key: System.get_env("SONARR_API_KEY"),
  # Shared secret Sonarr's Connect webhook sends in the
  # `x-aviary-secret` header. depot's aviary configure.sh generates
  # this and persists it alongside SECRET_KEY_BASE, then registers
  # the webhook in Sonarr with the same secret. Optional in dev; if
  # unset the controller accepts any POST (suitable for local
  # bring-up before the secret exists).
  sonarr_webhook_secret: System.get_env("SONARR_WEBHOOK_SECRET")

# Database — prod lives on a mounted volume so it survives container
# rebuilds. depot's aviary/configure.sh sets DATABASE_PATH; default is
# a sensible fallback that lands in the container.
if config_env() == :prod do
  config :aviary, Aviary.Repo,
    database: System.get_env("DATABASE_PATH") || "/app/data/aviary.db",
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5")),
    journal_mode: :wal,
    cache_size: -64000
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :aviary, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :aviary, AviaryWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :aviary, AviaryWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :aviary, AviaryWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
