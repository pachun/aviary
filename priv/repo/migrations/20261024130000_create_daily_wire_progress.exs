defmodule Aviary.Repo.Migrations.CreateDailyWireProgress do
  use Ecto.Migration

  def change do
    create table(:daily_wire_progress, primary_key: false) do
      add(:user_id, :string, primary_key: true)
      add(:slug, :string, primary_key: true)
      add(:position, :float, null: false, default: 0.0)
      add(:duration, :float, null: false, default: 0.0)
      add(:watched, :boolean, null: false, default: false)
      add(:session_id, :string, null: false)
      add(:sequence, :integer, null: false, default: -1)
    end
  end
end
