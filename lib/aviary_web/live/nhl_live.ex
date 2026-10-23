defmodule AviaryWeb.NhlLive do
  @moduledoc """
  Tonight's NHL games, grouped by start time, each with its feeds. The
  games come from the schedule `Aviary.Nhl.Schedule` keeps on hand, so
  the page never waits on the stream site; picking a feed opens the
  player over the page.
  """
  use AviaryWeb, :live_view

  alias AviaryWeb.Components.VideoPlayer

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "NHL", watching_game: nil)
     |> assign_games()}
  end

  def handle_event("watch_game", %{"game" => game_id, "feed" => feed_id}, socket) do
    watching_game =
      with %{feeds: feeds} = game <- Enum.find(socket.assigns.games, &(&1.id == game_id)),
           %{} = feed <- Enum.find(feeds, &(&1.id == feed_id)) do
        playlist = live_playlist_path(game.id, feed.id, socket.assigns.current_user.token)

        %{
          id: "nhl-#{game.id}-#{feed.id}",
          resume_seconds: 0,
          title: "#{game.away_team.name} at #{game.home_team.name} (#{feed.label})",
          src: playlist,
          native_src: playlist
        }
      else
        _ -> nil
      end

    {:noreply, assign(socket, :watching_game, watching_game)}
  end

  def handle_event("close_player", _, socket) do
    {:noreply, assign(socket, :watching_game, nil)}
  end

  def handle_event("page_visible", _, socket), do: {:noreply, assign_games(socket)}

  # The player hook reports progress and subtitle toggles for library
  # titles. A live game has neither to remember, so both are accepted and
  # ignored rather than crashing the page mid-game.
  def handle_event("report_progress", _, socket), do: {:noreply, socket}
  def handle_event("resync_position", _, socket), do: {:noreply, socket}
  def handle_event("subtitles_changed", _, socket), do: {:noreply, socket}

  defp assign_games(socket) do
    games = Aviary.Nhl.games()

    assign(socket, games: games, start_times: start_times(games))
  end

  defp start_times(games) do
    games
    |> Enum.group_by(& &1.starts_at)
    |> Enum.sort_by(fn {starts_at, _games} -> starts_at end, &earlier_first/2)
    |> Enum.map(fn {starts_at, games} -> %{label: clock(starts_at), games: games} end)
  end

  defp earlier_first(nil, _), do: false
  defp earlier_first(_, nil), do: true
  defp earlier_first(a, b), do: DateTime.compare(a, b) != :gt

  defp clock(nil), do: "Time TBD"

  defp clock(starts_at) do
    {_date, {hour, minute, _second}} =
      starts_at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    {clock_hour, half} = twelve_hour(hour)
    "#{clock_hour}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{half}"
  end

  @noon 12

  defp twelve_hour(0), do: {12, "AM"}
  defp twelve_hour(@noon), do: {12, "PM"}
  defp twelve_hour(hour) when hour < @noon, do: {hour, "AM"}
  defp twelve_hour(hour), do: {hour - @noon, "PM"}

  defp live_playlist_path(game_id, feed_id, token) do
    "/api/v1/nhl/games/#{game_id}/feeds/#{feed_id}/playlist.m3u8?" <>
      URI.encode_query(token: token)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section="nhl"
      current_user={@current_user}
      nav_visibility={@nav_visibility}
    >
      <div id="nhl" phx-hook="RefreshWhenVisible" class="pt-2 space-y-12">
        <p :if={@games == []} class="font-sans text-muted">No games today.</p>

        <section :for={start_time <- @start_times}>
          <h2 class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-muted mb-4">
            {start_time.label}
          </h2>
          <ul class="border-t border-rule">
            <li
              :for={game <- start_time.games}
              class="grid grid-cols-[1fr_auto] items-baseline gap-4 py-3 px-2 border-b border-rule"
            >
              <span
                class="font-display text-ink text-lg leading-tight truncate"
                style="font-variation-settings: 'opsz' 14;"
              >
                {game.away_team.name} <span class="text-muted">at</span> {game.home_team.name}
              </span>
              <span class="flex gap-3 font-sans uppercase tracking-[0.18em] text-[0.7rem] whitespace-nowrap">
                <button
                  :for={feed <- game.feeds}
                  type="button"
                  phx-click="watch_game"
                  phx-value-game={game.id}
                  phx-value-feed={feed.id}
                  class="text-oxblood hover:underline cursor-pointer"
                >
                  {feed.label}
                </button>
                <span :if={game.feeds == []} class="text-muted">No feeds yet</span>
              </span>
            </li>
          </ul>
        </section>
      </div>

      <VideoPlayer.overlay
        :if={@watching_game}
        item={@watching_game}
        src={@watching_game.src}
        native_src={@watching_game.native_src}
        referrer_policy="no-referrer"
        current_user={@current_user}
        title={@watching_game.title}
      />
    </Layouts.app>
    """
  end
end
