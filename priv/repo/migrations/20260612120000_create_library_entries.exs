defmodule Aviary.Repo.Migrations.CreateLibraryEntries do
  use Ecto.Migration

  def change do
    create table(:library_entries) do
      # Jellyfin user id (32-char GUID). We delegate identity to
      # Jellyfin entirely; this is the foreign-key-ish link.
      add :jellyfin_user_id, :string, null: false, size: 32

      # TMDB series id — the cross-system stable identifier that
      # Jellyfin, Sonarr, and Jellyseerr all understand. Lets us
      # join library membership to Sonarr's monitoring state and
      # Jellyseerr's metadata without surfacing Jellyfin's internal
      # GUIDs in our schema.
      add :tmdb_id, :string, null: false

      # When the user first added this show to their library. Used to
      # break ties in the "you've been watching" home page sorting.
      timestamps(updated_at: false)
    end

    # Per-user uniqueness: a user can't have the same show in their
    # library twice. The composite index also serves as a fast lookup
    # for "is user X subscribed to show Y" queries.
    create unique_index(:library_entries, [:jellyfin_user_id, :tmdb_id])

    # Reverse lookup: "who in the household cares about show Y" —
    # needed when the Sonarr unmonitor question comes up (defer'd
    # for now but worth indexing now to avoid a later migration).
    create index(:library_entries, [:tmdb_id])
  end
end
