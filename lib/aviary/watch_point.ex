defmodule Aviary.WatchPoint do
  @moduledoc """
  Moves a user's watch point within a show: every episode up to and
  including the chosen one becomes watched, every episode after it
  becomes unwatched. The marginalia ribbon on the web show page and the
  long press on a perch episode card both land here.

  Only episodes Jellyfin knows about carry watch state; TMDB-only
  placeholders (ids prefixed `tmdb-`) are skipped. Setting a watch point
  is an engagement signal, so the show is also added to the user's
  library when it has a TMDB id.
  """

  @jellyfin_concurrency 5
  @jellyfin_timeout_ms 5_000

  def set(show, episode_id, user) do
    episodes = Enum.flat_map(show.episodes_by_season, fn {_, eps} -> eps end)

    case Enum.find_index(episodes, &(&1.id == episode_id)) do
      nil ->
        :error

      index ->
        if show.tmdb_id, do: Aviary.Library.add(user.id, show.tmdb_id)
        write_marks(episodes, index, user)
        :ok
    end
  end

  def write_marks(episodes, index, user) do
    {watched, unwatched} = Enum.split(episodes, index + 1)

    (Enum.map(watched, &{:played, &1}) ++ Enum.map(unwatched, &{:unplayed, &1}))
    |> Enum.reject(fn {_, ep} -> tmdb_placeholder?(ep) end)
    |> Task.async_stream(
      fn
        {:played, ep} -> Aviary.Jellyfin.mark_played(ep.id, user)
        {:unplayed, ep} -> Aviary.Jellyfin.mark_unplayed(ep.id, user)
      end,
      max_concurrency: @jellyfin_concurrency,
      timeout: @jellyfin_timeout_ms,
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  defp tmdb_placeholder?(ep), do: String.starts_with?(to_string(ep.id), "tmdb-")
end
