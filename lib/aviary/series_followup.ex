defmodule Aviary.SeriesFollowup do
  @moduledoc """
  Queues the rest of a show once someone starts watching one episode.

  The chosen episode is grabbed on its own first (`Sonarr.watch_episode/3`)
  and `Aviary.SkipTheLine` raises it to SABnzbd's high priority. The rest
  of the series is searched for right away, without waiting for that
  episode to download or import: Sonarr hands TV grabs to SABnzbd at low
  priority, so the back catalog downloads only after every chosen
  episode and every movie in line.

  Shows whose episodes stand alone (game shows, talk shows, news; see
  `Sonarr.standalone_episodes?/1`) never broaden: one tap downloads one
  episode and that is the end of it.
  """

  require Logger

  alias Aviary.Sonarr

  @doc """
  Searches, in the background, for every missing episode of the show.
  Returns the background task's pid, or `:standalone_episodes` when the
  show's episodes stand alone and nothing more is queued.
  """
  def queue_the_rest(tmdb_id) do
    if Sonarr.standalone_episodes?(tmdb_id) do
      Logger.info("series_followup not broadening; episodes stand alone tmdb_id=#{tmdb_id}")
      :standalone_episodes
    else
      Task.start(fn ->
        Logger.info("series_followup queueing the rest of the series tmdb_id=#{tmdb_id}")
        Sonarr.watch_show(tmdb_id)
      end)
    end
  end
end
