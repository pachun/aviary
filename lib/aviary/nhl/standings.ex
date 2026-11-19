defmodule Aviary.Nhl.Standings do
  @moduledoc """
  The NHL standings by division, from the league's own public API. Kept
  for a few minutes, since they only change when a game ends.
  """

  alias Aviary.Cache

  @standings_url "https://api-web.nhle.com/v1/standings/now"
  @request_timeout_ms 8_000
  @fresh_ms :timer.minutes(10)
  @stale_ms :timer.hours(6)
  @divisions_east_to_west ["Atlantic", "Metropolitan", "Central", "Pacific"]

  @doc """
  `{:ok, divisions}`, east to west, each `%{name, conference, teams}`
  with its teams in division rank, or `:error` when the league doesn't
  answer.
  """
  def divisions do
    case Cache.swr({:nhl, :standings}, @fresh_ms, @stale_ms, &fetch/0) do
      {:ok, _divisions} = found ->
        found

      _ ->
        Cache.invalidate({:nhl, :standings})
        :error
    end
  end

  defp fetch do
    options =
      Keyword.merge(
        [receive_timeout: @request_timeout_ms, retry: false],
        Application.get_env(:aviary, :nhl_standings_req_options, [])
      )

    case Req.get(@standings_url, options) do
      {:ok, %Req.Response{status: 200, body: %{"standings" => [_ | _] = teams}}} ->
        {:ok, by_division(teams)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp by_division(teams) do
    teams_in = Enum.group_by(teams, & &1["divisionName"])

    for name <- @divisions_east_to_west, [first | _] = listed <- [Map.get(teams_in, name, [])] do
      %{
        name: name,
        conference: first["conferenceName"],
        teams: listed |> Enum.sort_by(& &1["divisionSequence"]) |> Enum.map(&team/1)
      }
    end
  end

  defp team(listed) do
    name = get_in(listed, ["teamName", "default"])

    %{
      id: team_id(name),
      name: name,
      nickname: get_in(listed, ["teamCommonName", "default"]),
      rank: listed["divisionSequence"],
      games_played: listed["gamesPlayed"],
      wins: listed["wins"],
      losses: listed["losses"],
      overtime_losses: listed["otLosses"],
      points: listed["points"],
      goal_difference: listed["goalDifferential"],
      last_ten: "#{listed["l10Wins"]}-#{listed["l10Losses"]}-#{listed["l10OtLosses"]}",
      streak: streak(listed)
    }
  end

  defp streak(%{"streakCode" => code, "streakCount" => count}) when is_binary(code),
    do: "#{code}#{count}"

  defp streak(_listed), do: nil

  defp team_id(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z0-9 -]/u, "")
    |> String.downcase()
    |> String.replace(~r/\s+/, "-")
  end

  defp team_id(_name), do: nil
end
