defmodule Aviary.Recommendations.Dismissal do
  @moduledoc """
  A recipient-side per-item dismissal. When a user clicks X on an
  item in their Family Recommended row, a row lands here. Future
  recommendations of the same item — even from a different sender —
  are silently absorbed (the row exists but is filtered from view).

  One row per (user, item) — re-dismissals are idempotent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "dismissed_recommendations" do
    field :user_id, :string
    field :tmdb_id, :string
    field :kind, :string
    field :dismissed_at, :utc_datetime_usec
  end

  def changeset(d, attrs) do
    d
    |> cast(attrs, [:user_id, :tmdb_id, :kind, :dismissed_at])
    |> validate_required([:user_id, :tmdb_id, :kind, :dismissed_at])
    |> validate_inclusion(:kind, ["show", "movie"])
    |> unique_constraint([:user_id, :tmdb_id, :kind])
  end
end
