defmodule Aviary.Nav do
  @moduledoc """
  Decides which top-level nav tabs are visible for the current user
  and where "/" should land them.

  Discover and Search are always visible — both are entry points
  that work even for a brand-new user with nothing in their library.
  Home, Shows, and Movies are conditional on whether their sections
  would actually have anything to render; an empty tab is worse than
  no tab.

  All four underlying fetches happen in parallel via Task.await_many,
  so the wall-clock is bounded by the slowest single one (typically
  the Upcoming computation, which does an extra Jellyseerr round-trip
  per series the user has touched).
  """

  alias Aviary.{Catalog, Home, Upcoming}

  @doc """
  Returns `%{home: bool, shows: bool, movies: bool, discover: true,
  search: true}` for the given user. Discover and Search stay true
  even when the others would be hidden — they're the always-on entry
  points.
  """
  def visibility(user) do
    [home_items, upcoming, shows, movies, recs] =
      Task.await_many(
        [
          Task.async(fn -> Home.continue_watching(user) end),
          Task.async(fn -> Upcoming.releases(user) end),
          # Both list_shows and list_movies are filtered by
          # library_entries (per-user), so the Shows / Movies tabs
          # each appear only when THIS user has at least one of that
          # kind — same gate the library page applies.
          Task.async(fn -> Catalog.list_shows(user) end),
          Task.async(fn -> Catalog.list_movies(user) end),
          # Family Recommended row also gates Home visibility. Filter
          # by "not in library" so a Home tab doesn't appear just
          # because every active rec is for a show the user already
          # has (those would be hidden from the row anyway).
          Task.async(fn ->
            Aviary.Recommendations.list_active_for_user_excluding_library(user.id)
          end)
        ],
        15_000
      )

    %{
      discover: true,
      search: true,
      home: home_items != [] or upcoming != [] or recs != [],
      shows: shows != [],
      movies: movies != []
    }
  end

  @doc """
  First-visible path. Used by the root `/` redirect so a new user with
  no content lands on /discover instead of staring at an empty /home.
  """
  def landing_path(%{home: true}), do: "/home"
  def landing_path(%{shows: true}), do: "/library?type=shows"
  def landing_path(%{movies: true}), do: "/library?type=movies"
  def landing_path(_), do: "/discover"

  @doc """
  Recompute nav_visibility for the current_user and re-assign on the
  socket. Use at moments where a library_entries mutation (add /
  remove / play-implies-add) inside a LiveView session could have
  flipped Home / Shows / Movies tabs into/out of visibility, but the
  initial visibility assigned by `AviaryWeb.UserAuth` on_mount is
  now stale. Most common case: a user with empty library plays
  something — library_entries gets a new row, but the nav assign
  doesn't reflect it until navigation triggers a fresh mount.
  """
  def refresh_visibility(socket) do
    Phoenix.Component.assign(
      socket,
      :nav_visibility,
      visibility(socket.assigns.current_user)
    )
  end
end
