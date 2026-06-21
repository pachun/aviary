defmodule Aviary.Deletions.Scheduler do
  @moduledoc """
  Background sweeper that drives `Aviary.Deletions.PendingDeletion`
  rows to their final state. Wakes every `@interval_ms` (1 hour by
  default), scans for rows whose `scheduled_for` has passed, and
  hands each to `Aviary.Deletions.execute/1`.

  No persistence beyond the rows themselves — restarts pick up
  where we left off because the rows survive.
  """

  use GenServer
  require Logger

  alias Aviary.Deletions

  # Hourly sweep. The grace window is 24h so this gives the user
  # plenty of cancel-by-re-add time + ~1h average latency on
  # actually-firing. If you want tighter latency, lower this.
  @interval_ms 60 * 60 * 1000

  # On boot, defer the first sweep by 60s so we don't compete with
  # other application-startup work (Repo warmup, Endpoint listen).
  @initial_delay_ms 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_next_sweep(@initial_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_next_sweep(@interval_ms)
    {:noreply, state}
  end

  defp schedule_next_sweep(delay_ms) do
    Process.send_after(self(), :sweep, delay_ms)
  end

  defp sweep do
    due = Deletions.due_now()

    if due != [] do
      Logger.info("deletions sweep due_count=#{length(due)}")
    end

    Enum.each(due, fn pd ->
      try do
        Deletions.execute(pd)
      rescue
        e ->
          Logger.error(
            "deletions execute_crash tmdb_id=#{pd.tmdb_id} error=#{inspect(e) |> String.slice(0, 400)}"
          )
      end
    end)
  end
end
