defmodule Aviary.Recommendations.Recommendation do
  @moduledoc """
  A single recommendation made by one household member to another.
  Unique on (from_user_id, to_user_id, tmdb_id, kind) so re-sends are
  idempotent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "recommendations" do
    field :from_user_id, :string
    field :to_user_id, :string
    field :tmdb_id, :string
    field :kind, :string

    timestamps()
  end

  def changeset(rec, attrs) do
    rec
    |> cast(attrs, [:from_user_id, :to_user_id, :tmdb_id, :kind])
    |> validate_required([:from_user_id, :to_user_id, :tmdb_id, :kind])
    |> validate_inclusion(:kind, ["show", "movie"])
    |> unique_constraint([:from_user_id, :to_user_id, :tmdb_id, :kind])
  end
end
