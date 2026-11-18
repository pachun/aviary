defmodule Aviary.MoreLikeThis.Row do
  @moduledoc """
  The finished "More like this" row for one show or movie, kept so the
  detail page gets it without waiting on Claude, TMDB and Rotten
  Tomatoes again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "more_like_this_rows" do
    field(:kind, :string)
    field(:tmdb_id, :string)
    field(:items, {:array, :map})

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:kind, :tmdb_id, :items])
    |> validate_required([:kind, :tmdb_id, :items])
    |> unique_constraint([:kind, :tmdb_id])
  end
end
