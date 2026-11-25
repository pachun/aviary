defmodule Aviary.Reconcile.Scheduler do
  @moduledoc """
  Runs `Aviary.Reconcile` on a timer as well as on Sonarr's webhooks.

  The webhook path only fires on Sonarr's own health edges. Sonarr never
  learns that an indexer which was refusing grabs (a tracker blocking
  downloads, a news server missing every article) has started serving
  again, so a monitored episode whose every release failed sits
  "Searching" forever. A daily pass re-fires the searches so the next
  working release gets picked up without anyone tapping the episode.
  The pass fires every missing episode's search at once, which keeps
  Sonarr busy for a while, so it runs in the small hours on the local
  clock — never minutes after a restart, where each deploy would queue
  another full set ahead of whatever someone just asked to watch.

  A finished download Sonarr or Radarr won't import sits in the queue
  forever too, and the webhooks never fire for it. A sweep every few
  minutes clears those so a show never shows "stuck" for longer than
  it takes to grab the next release.

  When every release Sonarr accepts for an episode has failed, the
  daily pass can't help: there is nothing left for Sonarr to grab. A
  last-resort pass follows it and grabs the best release the quality
  profile rejects. Each sweep does the same for episodes whose download
  failed within the last hour, so an episode Sonarr has just run out of
  releases for, or whose last-resort release was gone too, gets the
  next one within minutes.
  """

  use GenServer
  require Logger

  @daily_pass_time ~T[04:00:00]
  @seconds_per_day 24 * 60 * 60
  @ms_per_second 1000
  @sweep_interval_ms 10 * 60 * 1000
  @first_sweep_delay_ms 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next_pass()
    schedule_next_sweep(@first_sweep_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    fill_in_more_like_this_rows()
    schedule_next_pass()
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    sweep()
    schedule_next_sweep(@sweep_interval_ms)
    {:noreply, state}
  end

  defp schedule_next_pass do
    Process.send_after(self(), :reconcile, ms_until_daily_pass(Aviary.LocalTime.now()))
  end

  @doc "Milliseconds from `now` (local wall-clock time) until the next daily pass."
  def ms_until_daily_pass(%NaiveDateTime{} = now) do
    todays_pass = NaiveDateTime.new!(NaiveDateTime.to_date(now), @daily_pass_time)
    seconds_until_todays_pass = NaiveDateTime.diff(todays_pass, now)

    seconds_until_pass =
      if seconds_until_todays_pass > 0,
        do: seconds_until_todays_pass,
        else: seconds_until_todays_pass + @seconds_per_day

    seconds_until_pass * @ms_per_second
  end

  defp schedule_next_sweep(delay_ms) do
    Process.send_after(self(), :sweep, delay_ms)
  end

  defp reconcile do
    Logger.info("reconcile scheduler: running daily pass")

    try do
      Aviary.Reconcile.run()
      Aviary.Reconcile.grab_last_resort_releases()
    rescue
      e -> Logger.warning("reconcile scheduler raised: #{inspect(e)}")
    end
  end

  defp fill_in_more_like_this_rows do
    Task.Supervisor.start_child(Aviary.TaskSupervisor, &Aviary.MoreLikeThis.fill_in_library/0)
  end

  defp sweep do
    try do
      Aviary.Reconcile.sweep_stuck_downloads()
      Aviary.Reconcile.grab_last_resort_releases_after_recent_failures()
    rescue
      e -> Logger.warning("reconcile sweep raised: #{inspect(e)}")
    end
  end
end
