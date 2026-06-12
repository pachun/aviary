defmodule Aviary.Library do
  @moduledoc """
  Per-user library membership — "which shows is each household member
  interested in." A separate concern from watch history, download
  state, or what's surfaced on Home — those each have their own
  source of truth (Jellyfin, Sonarr, derived in `Aviary.Home`).

  Every play action (Watch a show, Watch a season, Play an episode)
  auto-adds the show — pressing any action button is taken as a
  commitment signal. There's no removal path yet; the X on Continue
  Watching resets Jellyfin watch state, it does not touch this
  table. Consumers today: `Aviary.Upcoming` (filters the user's
  upcoming-episode feed to shows they care about).

  Stays small on purpose: no schema for users (Jellyfin owns identity),
  no schema for shows (TMDB owns metadata), no schema for downloads
  (Sonarr owns state). Just the join.
  """

  import Ecto.Query
  alias Aviary.Library.Entry
  alias Aviary.Repo

  @doc """
  Adds a show to a user's library. Idempotent — no error if it already
  exists. Returns `:ok` either way.
  """
  def add(user_id, tmdb_id) when is_binary(user_id) and is_binary(tmdb_id) do
    %Entry{}
    |> Entry.changeset(%{jellyfin_user_id: user_id, tmdb_id: tmdb_id})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:jellyfin_user_id, :tmdb_id]
    )

    :ok
  end

  def add(user_id, tmdb_id) when is_integer(tmdb_id), do: add(user_id, to_string(tmdb_id))

  @doc """
  Removes a show from a user's library. Idempotent — no error if the
  entry never existed.
  """
  def remove(user_id, tmdb_id) when is_binary(user_id) and is_binary(tmdb_id) do
    from(e in Entry,
      where: e.jellyfin_user_id == ^user_id and e.tmdb_id == ^tmdb_id
    )
    |> Repo.delete_all()

    :ok
  end

  def remove(user_id, tmdb_id) when is_integer(tmdb_id), do: remove(user_id, to_string(tmdb_id))

  @doc """
  Lists a user's library as a list of TMDB ids ordered by when they
  added each (most recently added first). Used to seed Home's
  Continue Watching candidate set + Upcoming's "shows you care about"
  filter.
  """
  def list_tmdb_ids(user_id) when is_binary(user_id) do
    from(e in Entry,
      where: e.jellyfin_user_id == ^user_id,
      order_by: [desc: e.inserted_at],
      select: e.tmdb_id
    )
    |> Repo.all()
  end

  @doc """
  Returns true if a specific user has a given show in their library.
  """
  def member?(user_id, tmdb_id) when is_binary(user_id) and is_binary(tmdb_id) do
    from(e in Entry,
      where: e.jellyfin_user_id == ^user_id and e.tmdb_id == ^tmdb_id,
      select: 1
    )
    |> Repo.exists?()
  end

  def member?(user_id, tmdb_id) when is_integer(tmdb_id),
    do: member?(user_id, to_string(tmdb_id))

  @doc """
  Returns the list of user ids who have a show in their library.
  Reserved for the eventual "should Sonarr keep monitoring this" check
  when we get to the unmonitor question — if a show has zero library
  entries left across the household, it's a candidate for cleanup.
  """
  def subscribers(tmdb_id) when is_binary(tmdb_id) do
    from(e in Entry,
      where: e.tmdb_id == ^tmdb_id,
      select: e.jellyfin_user_id
    )
    |> Repo.all()
  end

  def subscribers(tmdb_id) when is_integer(tmdb_id), do: subscribers(to_string(tmdb_id))
end
