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
  `:cached_valid` — recently probed and OK; skip the network call.
  `:not_cached` — caller should probe and call mark_valid/1 on success.
  """
  def status(token) do
    case :ets.lookup(@table, token) do
      [{^token, valid_until}] ->
        if System.monotonic_time(:millisecond) < valid_until,
          do: :cached_valid,
          else: :not_cached

      _ ->
        :not_cached
    end
  end

  def mark_valid(token) do
    valid_until = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {token, valid_until})
    :ok
  end

  def invalidate(token) do
    :ets.delete(@table, token)
    :ok
  end

  ## GenServer

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
