defmodule Aviary.Nhl.Site do
  @moduledoc """
  The household's one lane to the stream site. Every request to the site
  passes through this process, one at a time with a pause after each, so
  however many callers want a page at the same moment the site only ever
  sees a single unhurried request from this address. Bursts of
  simultaneous connections are what it refuses, and one refusal used to
  black out every feed for twenty minutes.
  """
  use GenServer

  @pause_between_requests_ms 500

  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @doc """
  Runs `perform` as the only request in flight to the site, once the
  pause after the previous one has passed, and returns its result.
  """
  def request(server \\ __MODULE__, perform) when is_function(perform, 0) do
    GenServer.call(server, {:request, perform}, :infinity)
  end

  @impl true
  def init(options) do
    pause_ms = Keyword.get(options, :pause_ms, @pause_between_requests_ms)
    {:ok, %{pause_ms: pause_ms, next_request_allowed_at: now()}}
  end

  @impl true
  def handle_call({:request, perform}, _from, state) do
    wait_until(state.next_request_allowed_at)
    outcome = perform.()
    {:reply, outcome, %{state | next_request_allowed_at: now() + state.pause_ms}}
  end

  defp wait_until(time) do
    remaining_ms = time - now()
    if remaining_ms > 0, do: Process.sleep(remaining_ms)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
