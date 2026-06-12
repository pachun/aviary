defmodule Aviary.TokenCache do
  @moduledoc """
  In-memory cache for Jellyfin token validity. Without it, every HTTP
  request to an authenticated route triggers a /Users/Me probe — a
  single page load with five marquee thumbnails fires six parallel
  probes. Jellyfin doesn't love that, and a single transient 401
  drops the session.

  Marks a token "good for N seconds" after one successful probe; any
  subsequent request inside the window skips the probe entirely. An
  explicit 401/403 invalidates the cache so the user gets bounced
  immediately rather than staying "logged in" against a dead token.

  Pattern mirrors Aviary.RottenTomatoes — GenServer owns the ETS
  table for restart-cleanup semantics; reads go straight against
  public ETS so they don't queue on the GenServer.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Three states:

    * `:cached_valid` — recently probed and OK; skip the network call.
    * `:probing` — another request is already probing this token;
      trust it and return true (the cache will fill momentarily).
      Prevents the thundering-herd failure mode where a page load
      with N parallel requests all miss the cache and each issue
      their own /Users/Me probe, overwhelming Jellyfin and producing
      spurious 401s that drop the session.
    * `:not_cached` — caller should grab the probe lock and probe.
  """
  def status(token) do
    case :ets.lookup(@table, token) do
      [{^token, valid_until}] ->
        if System.monotonic_time(:millisecond) < valid_until,
          do: :cached_valid,
          else: probe_lock_status(token)

      _ ->
        probe_lock_status(token)
    end
  end

  @doc """
  Try to take the probe lock for this token. Returns `:ok` if we got
  it (and must call release_probe_lock/1 after probing), or `:locked`
  if another request already has it.
  """
  def take_probe_lock(token) do
    if :ets.insert_new(@table, {{:probe_lock, token}, lock_deadline()}) do
      :ok
    else
      :locked
    end
  end

  def release_probe_lock(token) do
    :ets.delete(@table, {:probe_lock, token})
    :ok
  end

  def mark_valid(token) do
    valid_until = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {token, valid_until})
    :ok
  end

  def invalidate(token) do
    :ets.delete(@table, token)
    :ets.delete(@table, {:probe_lock, token})
    :ok
  end

  defp probe_lock_status(token) do
    case :ets.lookup(@table, {:probe_lock, token}) do
      [{_, deadline}] ->
        if System.monotonic_time(:millisecond) < deadline,
          do: :probing,
          # Stale lock (probe died/crashed) — let the next caller retry.
          else: :not_cached

      _ ->
        :not_cached
    end
  end

  # Generous deadline — a probe should complete in well under a second,
  # but the cap protects against a leaked lock if the probing process
  # dies mid-flight without calling release. After the deadline passes,
  # the next caller treats it as :not_cached and re-locks.
  defp lock_deadline, do: System.monotonic_time(:millisecond) + 10_000

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
