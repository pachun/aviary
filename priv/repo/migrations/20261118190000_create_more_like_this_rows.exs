defmodule Aviary.Repo.Migrations.CreateMoreLikeThisRows do
  use Ecto.Migration

  def change do
    create table(:more_like_this_rows) do
      add(:kind, :string, null: false)
      add(:tmdb_id, :string, null: false)
      add(:items, :text, null: false)

      timestamps()
    end

    create(unique_index(:more_like_this_rows, [:kind, :tmdb_id]))
  end
end
