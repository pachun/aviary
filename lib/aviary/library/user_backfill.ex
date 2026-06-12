defmodule Aviary.Library.UserBackfill do
  @moduledoc """
  Per-user marker: "this user's library_entries have been seeded from
  their pre-existing Jellyfin watch history." Once present, backfill
  never runs again for that user — so a user who empties their
  library by dismissing every show doesn't have it silently rebuilt
  from history on the next request.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:jellyfin_user_id, :string, autogenerate: false}
  schema "user_backfills" do
    field :backfilled_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:jellyfin_user_id, :backfilled_at])
    |> validate_required([:jellyfin_user_id, :backfilled_at])
  end
end
