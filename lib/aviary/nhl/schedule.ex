defmodule Aviary.Nhl.Schedule do
  @moduledoc """
  Keeps the NHL schedule and each game's feeds on hand, so nobody
  opening Home or the TV ever waits on the stream site, and so the site
  is only ever walked by this one process. The schedule page is read
  every few minutes and each game's team page every ten. A team page
  that stops answering keeps the feeds it last gave until it answers
  again, and a refusal from the site ends the walk until the hold-off
  lapses, with the games already gathered still listed.
  Previous-evening games survive the site's overnight schedule replacement
  until 6 a.m. local time, with their original dates and feed identities.
  """
  use GenServer

  alias Aviary.Cache
  alias Aviary.Nhl

  @schedule_every_ms :timer.minutes(5)
  @feeds_every_ms :timer.minutes(10)
  @keep_schedule_ms :timer.hours(1)

  def start_link(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, if(name, do: [name: name], else: []))
  end

  @doc """
  Walks the site now and returns once the schedule is on hand.
  """
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, :infinity)

  @impl true
  def init(options) do
    if Keyword.get(options, :refresh_on_its_own, true), do: send(self(), :refresh)
    feeds_every_ms = Keyword.get(options, :feeds_every_ms, @feeds_every_ms)

    {:ok,
     %{
       feeds_every_ms: feeds_every_ms,
       feeds_by_game: %{},
       games: [],
       local_now: Keyword.get(options, :local_now, &:calendar.local_time/0)
     }}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, walk(state)}

  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @schedule_every_ms)
    {:noreply, walk(state)}
  end

  defp walk(state) do
    local_now = state.local_now.()

    with false <- Nhl.holding_off_site?(),
         {:ok, games} <- Nhl.scrape_schedule(local_now) do
      [_today | overnight_dates] = Nhl.schedule_dates(local_now)
      overnight = Enum.filter(state.games, &(&1.date in overnight_dates))
      games = Enum.uniq_by(overnight ++ games, & &1.id)

      {games_with_feeds, feeds_by_game} =
        Enum.map_reduce(games, state.feeds_by_game, &with_feeds(&1, &2, state.feeds_every_ms))

      Cache.put({:nhl, :games}, games_with_feeds, @keep_schedule_ms)

      %{
        state
        | games: games_with_feeds,
          feeds_by_game: Map.take(feeds_by_game, Enum.map(games, & &1.id))
      }
    else
      _ -> state
    end
  end

  defp with_feeds(game, feeds_by_game, feeds_every_ms) do
    case feeds_for(game, Map.get(feeds_by_game, game.id), feeds_every_ms) do
      nil -> {Map.put(game, :feeds, []), feeds_by_game}
      kept -> {Map.put(game, :feeds, kept.feeds), Map.put(feeds_by_game, game.id, kept)}
    end
  end

  defp feeds_for(game, kept, feeds_every_ms) do
    cond do
      kept != nil and now() - kept.fetched_at < feeds_every_ms ->
        kept

      Nhl.holding_off_site?() ->
        kept

      true ->
        case Nhl.scrape_feeds(game) do
          {:ok, feeds} -> %{feeds: feeds, fetched_at: now()}
          :error -> kept
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
