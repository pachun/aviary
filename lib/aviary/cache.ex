defmodule Aviary.Cache do
  @moduledoc """
  General-purpose ETS-backed cache with TTL + stale-while-revalidate
  semantics. The cache is filled by callers — there's no warming,
  no preload, no remote sync — and it's process-local to this BEAM
  node.

  Two main APIs:

    * `fetch/3` — simple TTL. Cache hit returns the cached value;
      miss/expired computes and stores. No staleness window.

    * `swr/4` — stale-while-revalidate. Cache hit within fresh TTL
      returns immediately. Hit past fresh but within stale TTL
      returns the cached value AND kicks off a background refresh
      (so the next caller gets fresh data). Past stale TTL is
      treated as a miss.

  Use `swr` for anything where "a few seconds of staleness is fine,
  but a slow page mount isn't." Use `fetch` for things where you
  want a hard "this is fresh" guarantee within the window.

  Invalidation: `invalidate/1` for a single key, `invalidate_match/1`
  for a key pattern (e.g. "all list_episodes entries for a user"
  after that user marks an episode played).

  Pattern mirrors `Aviary.RottenTomatoes` and `Aviary.TokenCache` —
  GenServer owns the ETS table for restart cleanup, reads go
  straight to public ETS so they don't queue on the GenServer.
  """
  use GenServer
  require Logger

  @table __MODULE__
  @sweep_ms 60_000

  ## Public API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Return cached value if within `ttl_ms`, else compute via `fun`,
  store, and return. `fun` is invoked synchronously on miss.
  """
  def fetch(key, ttl_ms, fun) when is_function(fun, 0) do
    now = monotonic()

    case :ets.lookup(@table, key) do
      [{^key, value, fresh_until, _stale_until}] when now < fresh_until ->
        value

      _ ->
        compute_and_store(key, ttl_ms, ttl_ms, fun)
    end
  end

  @doc """
  Stale-while-revalidate:
    * fresh hit (within `fresh_ttl_ms`) → return cached value
    * stale hit (within `stale_ttl_ms`) → return cached value AND
      kick off a background refresh (one per key — duplicate
      stale-window callers in the same instant may all fire
      refreshes; acceptable)
    * miss / expired → compute synchronously and store
  """
  def swr(key, fresh_ttl_ms, stale_ttl_ms, fun)
      when is_function(fun, 0) and stale_ttl_ms >= fresh_ttl_ms do
    now = monotonic()

    case :ets.lookup(@table, key) do
      [{^key, value, fresh_until, _stale_until}] when now < fresh_until ->
        value

      [{^key, value, _fresh_until, stale_until}] when now < stale_until ->
        Task.start(fn ->
          try do
            compute_and_store(key, fresh_ttl_ms, stale_ttl_ms, fun)
          rescue
            e -> Logger.warning("cache swr refresh raised key=#{inspect(key)} error=#{inspect(e)}")
          end
        end)

        value

      _ ->
        compute_and_store(key, fresh_ttl_ms, stale_ttl_ms, fun)
    end
  end

  @doc """
  Delete a single key. Idempotent — no error if absent.
  """
  def invalidate(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Delete every entry whose KEY matches the given ETS match pattern.
  Use `:_` for wildcards on a tuple key. Example:

      Aviary.Cache.invalidate_match({:jellyfin_list_episodes, :_, "auth-id"})
  """
  def invalidate_match(key_pattern) do
    :ets.match_delete(@table, {key_pattern, :_, :_, :_})
    :ok
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = monotonic()

    # Delete entries whose stale_until has passed. Match spec is
    # `{key, value, fresh_until, stale_until}` and we filter on
    # `stale_until < now`.
    match_spec = [{{:_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
    schedule_sweep()
    {:noreply, state}
  end

  ## Internals

  defp compute_and_store(key, fresh_ttl_ms, stale_ttl_ms, fun) do
    value = fun.()
    now = monotonic()
    :ets.insert(@table, {key, value, now + fresh_ttl_ms, now + stale_ttl_ms})
    value
  end

  defp monotonic, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
