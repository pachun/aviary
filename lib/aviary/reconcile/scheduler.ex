defmodule Aviary.Reconcile.Scheduler do
  @moduledoc """
  Runs `Aviary.Reconcile` on a timer as well as on Sonarr's webhooks.

  The webhook path only fires on Sonarr's own health edges. Sonarr never
  learns that an indexer which was refusing grabs (a tracker blocking
  downloads, a news server missing every article) has started serving
  again, so a monitored episode whose every release failed sits
  "Searching" forever. A daily pass re-fires the searches so the next
  working release gets picked up without anyone tapping the episode.
  """

  use GenServer
  require Logger

  @interval_ms 24 * 60 * 60 * 1000
  @initial_delay_ms 5 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next_pass(@initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    schedule_next_pass(@interval_ms)
    {:noreply, state}
  end

  defp schedule_next_pass(delay_ms) do
    Process.send_after(self(), :reconcile, delay_ms)
  end

  defp reconcile do
    Logger.info("reconcile scheduler: running daily pass")

    try do
      Aviary.Reconcile.run()
    rescue
      e -> Logger.warning("reconcile scheduler raised: #{inspect(e)}")
    end
  end
end
