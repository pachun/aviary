defmodule Aviary.RecentSearches.Entry do
  @moduledoc """
  A per-user committed search: "user X searched for 'silo' and
  clicked through to a result."

  Only commitment signals (a navigation off the search results into
  a detail page) land here. Intermediate debounce fires like
  "you've got mai" never get recorded because the user never
  clicked them. See `Aviary.RecentSearches` for the recording side.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "recent_searches" do
    field :jellyfin_user_id, :string
    field :query, :string
    field :searched_at, :utc_datetime_usec
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:jellyfin_user_id, :query, :searched_at])
    |> validate_required([:jellyfin_user_id, :query, :searched_at])
    |> validate_length(:jellyfin_user_id, is: 32)
    |> unique_constraint([:jellyfin_user_id, :query])
  end
end
