defmodule Aviary.Repo.Migrations.CreateRecommendations do
  use Ecto.Migration

  def change do
    create table(:recommendations) do
      add :from_user_id, :string, null: false
      add :to_user_id, :string, null: false
      add :tmdb_id, :string, null: false
      # "show" | "movie" — tmdb_id is namespaced per type at TMDB
      # (a show with id N and a movie with id N are distinct), so
      # the kind is needed to disambiguate when looking the item up.
      add :kind, :string, null: false

      timestamps()
    end

    # Idempotent re-sends: when Chris recommends Dutton Ranch to me a
    # second time, the existing row is updated rather than duplicated.
    create unique_index(:recommendations, [:from_user_id, :to_user_id, :tmdb_id, :kind])

    # Home page row + detail-page badge both query "what's active for
    # me?" — indexing on to_user_id keeps that single-digit-ms.
    create index(:recommendations, [:to_user_id])

    create table(:dismissed_recommendations) do
      add :user_id, :string, null: false
      add :tmdb_id, :string, null: false
      add :kind, :string, null: false
      add :dismissed_at, :utc_datetime_usec, null: false
    end

    # Per-item dismissal: once a user clicks X on an item, no future
    # recommendation of that same item (from anyone) shows for them.
    create unique_index(:dismissed_recommendations, [:user_id, :tmdb_id, :kind])
  end
end
