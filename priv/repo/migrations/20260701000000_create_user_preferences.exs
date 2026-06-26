defmodule Aviary.Repo.Migrations.CreateUserPreferences do
  use Ecto.Migration

  def change do
    create table(:user_preferences) do
      add :jellyfin_user_id, :string, null: false
      # Whether English subtitles start on when the user begins a title.
      # Flips implicitly when they change subtitles mid-playback.
      add :subtitles_default, :boolean, null: false, default: false

      timestamps()
    end

    # One preferences row per user — upserted on change.
    create unique_index(:user_preferences, [:jellyfin_user_id])
  end
end
