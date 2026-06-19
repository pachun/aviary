defmodule Aviary.Nav do
  @moduledoc """
  Decides which top-level nav tabs are visible for the current user
  and where "/" should land them.

  Discover and Search are always visible — both are entry points
  that work even for a brand-new user with nothing in their library.
  Home and Library are conditional on whether their sections would
  actually have anything to render; an empty tab is worse than no
  tab.

  All four underlying fetches happen in parallel via Task.await_many,
  so the wall-clock is bounded by the slowest single one (typically
  the Upcoming computation, which does an extra Jellyseerr round-trip
  per series the user has touched).
  """

  alias Aviary.{Catalog, Home, Upcoming}

  @doc """
  Returns `%{home: bool, library: bool, discover: true, search: true}`
  for the given user. Discover and Search stay true even when
  home/library would be hidden — they're the always-on entry points.
  """
  def visibility(user) do
    [home_items, upcoming, shows, movies] =
      Task.await_many(
        [
          Task.async(fn -> Home.continue_watching(user) end),
          Task.async(fn -> Upcoming.releases(user) end),
          # Both list_shows and list_movies are filtered by
          # library_entries (per-user), so the Library tab only shows
          # when THIS user has at least one show or movie in their
          # library — same gate the Library page applies.
          Task.async(fn -> Catalog.list_shows(user) end),
          Task.async(fn -> Catalog.list_movies(user) end)
        ],
        15_000
      )

    %{
      discover: true,
      search: true,
      home: home_items != [] or upcoming != [],
      library: shows != [] or movies != []
    }
  end

  @doc """
  First-visible path. Used by the root `/` redirect so a new user with
  no content lands on /discover instead of staring at an empty /home.
  """
  def landing_path(%{home: true}), do: "/home"
  def landing_path(%{library: true}), do: "/library?type=shows"
  def landing_path(_), do: "/discover"
end
