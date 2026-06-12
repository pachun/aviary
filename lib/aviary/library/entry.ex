defmodule Aviary.Library.Entry do
  @moduledoc """
  A per-user library membership: "user X cares about show Y."

  Aviary's library is purely *aviary-side* state — it's the user's
  declared interest in a show, independent of whether the show's
  files are downloaded yet. Download state is Sonarr's concern;
  watch state is Jellyfin's concern. This schema is the one piece
  aviary owns: which household members are following which shows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "library_entries" do
    field :jellyfin_user_id, :string
    field :tmdb_id, :string

    timestamps(updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:jellyfin_user_id, :tmdb_id])
    |> validate_required([:jellyfin_user_id, :tmdb_id])
    |> validate_length(:jellyfin_user_id, is: 32)
    |> unique_constraint([:jellyfin_user_id, :tmdb_id])
  end
end
