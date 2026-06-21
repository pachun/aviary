defmodule Aviary.Repo.Migrations.CreatePendingDeletions do
  use Ecto.Migration

  def change do
    create table(:pending_deletions) do
      # tmdb_id is the household-wide key (one show ⇄ one tmdb_id), so
      # there's at most one pending_deletion per show. Re-add of any
      # subscriber drops this row to cancel; if the row doesn't exist,
      # nothing to cancel — the add is a no-op against this table.
      add :tmdb_id, :string, null: false
      add :scheduled_for, :utc_datetime_usec, null: false
      # "kind" so we can route to Sonarr (show) vs Radarr (movie) at
      # deletion time without re-deriving the type.
      add :kind, :string, null: false
      # Free-form context for the audit trail. Today the only value is
      # "all_subscribers_removed"; leaving it as a string so future
      # reasons (manual schedule, disk-pressure sweep, etc.) don't
      # require a migration.
      add :reason, :string

      timestamps()
    end

    create unique_index(:pending_deletions, [:tmdb_id])
    create index(:pending_deletions, [:scheduled_for])
  end
end
