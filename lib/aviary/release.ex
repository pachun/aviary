defmodule Aviary.Release do
  @moduledoc """
  Tasks runnable from the compiled prod release. Phoenix releases
  don't auto-run Ecto migrations on boot (and we don't want them to —
  release scripts that auto-migrate make rollbacks risky). depot's
  configure.sh invokes `bin/aviary eval "Aviary.Release.migrate()"`
  after `docker-compose up -d --build` so the schema's always in sync
  with the deployed code, but the call is explicit and visible in
  the deploy script.
  """
  @app :aviary

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
