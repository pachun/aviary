defmodule Aviary.Repo.Migrations.CreateUserBackfills do
  use Ecto.Migration

  def change do
    # Marker row per Jellyfin user — once present, library backfill
    # never runs again for that user. Without this, a user who
    # explicitly empties their library (e.g., dismisses every show)
    # would have their watch history silently re-imported on the
    # next request and override their declared intent.
    create table(:user_backfills, primary_key: false) do
      add :jellyfin_user_id, :string, primary_key: true, size: 32, null: false
      add :backfilled_at, :utc_datetime, null: false
    end
  end
end
