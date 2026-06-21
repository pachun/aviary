defmodule Aviary.Deletions.PendingDeletion do
  @moduledoc """
  A scheduled future deletion of a downloaded series or movie from
  the tank. Created when the last household subscriber removes a
  show/movie from their library AND every file was downloaded via
  Usenet (so deletion doesn't break a torrent seed). Re-add by any
  user deletes the row and cancels.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "pending_deletions" do
    field :tmdb_id, :string
    field :scheduled_for, :utc_datetime_usec
    # "show" | "movie" — dictates which arr handles deletion.
    field :kind, :string
    field :reason, :string

    timestamps()
  end

  def changeset(pd, attrs) do
    pd
    |> cast(attrs, [:tmdb_id, :scheduled_for, :kind, :reason])
    |> validate_required([:tmdb_id, :scheduled_for, :kind])
    |> validate_inclusion(:kind, ["show", "movie"])
    |> unique_constraint(:tmdb_id)
  end
end
