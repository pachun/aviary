defmodule Aviary.Repo.Migrations.CreateRecentSearches do
  use Ecto.Migration

  def change do
    create table(:recent_searches) do
      # Jellyfin user id (32-char GUID). Same identity model as
      # library_entries — Jellyfin owns users, we just key off the
      # GUID.
      add :jellyfin_user_id, :string, null: false, size: 32

      # The verbatim query string. Lengths bounded by the search
      # input's practical use (titles, names), but `:text` keeps us
      # from worrying about an arbitrary upper limit.
      add :query, :text, null: false

      # When the query was most recently committed to (i.e. the
      # user clicked through to a result). Bumped on re-search via
      # the unique-on-(user, query) upsert in
      # Aviary.RecentSearches.record/2.
      add :searched_at, :utc_datetime_usec, null: false
    end

    # Per-user de-dup: re-running the same query bumps the existing
    # row's searched_at rather than creating a duplicate. The
    # context module's upsert relies on this constraint.
    create unique_index(:recent_searches, [:jellyfin_user_id, :query])

    # Hot lookup for the search page's empty state ("give me this
    # user's most-recent N queries"). Without this, the
    # ORDER BY searched_at DESC LIMIT N walks the table.
    create index(:recent_searches, [:jellyfin_user_id, :searched_at])
  end
end
