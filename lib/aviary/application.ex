defmodule Aviary.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AviaryWeb.Telemetry,
      Aviary.Repo,
      {DNSCluster, query: Application.get_env(:aviary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Aviary.PubSub},
      Aviary.Cache,
      Aviary.RottenTomatoes,
      Aviary.TokenCache,
      # Sweeps `pending_deletions` rows hourly and asks the arrs to
      # delete on-disk media that nobody's library tracks anymore.
      # See Aviary.Deletions for the lifecycle, Aviary.Deletions.Scheduler
      # for the cadence.
      Aviary.Deletions.Scheduler,
      # Start to serve requests, typically the last entry
      AviaryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Aviary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AviaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
