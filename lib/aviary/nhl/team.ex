defmodule Aviary.Nhl.Team do
  @moduledoc """
  One NHL team's page: where it stands, when it plays, who is on each
  line, who is hurt and who is scoring.

  Nothing here comes from one place. The league's public API gives the
  roster with photos, the schedule and the scoring. Line combinations
  are read out of DailyFaceoff's team page, which has no API, so a
  change to that page costs the lines and the page falls back to the
  roster by position. Injuries come from ESPN's public feed, whose
  return dates are estimates.
  """

  alias Aviary.Cache
  alias Aviary.Nhl.Standings

  @league_api "https://api-web.nhle.com/v1"
  @lines_site "https://www.dailyfaceoff.com/teams"
  @injuries_url "https://site.api.espn.com/apis/site/v2/sports/hockey/nhl/injuries"
  @browser_user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @request_timeout_ms 10_000
  @sources_at_once 5
  @fresh_ms :timer.minutes(15)
  @stale_ms :timer.hours(6)
  @regular_season 2
  @playoffs 3
  @finished_states ["OFF", "FINAL"]
  @recent_games_shown 5
  @scoring_leaders_shown 5
  @page_data ~r{<script id="__NEXT_DATA__"[^>]*>(.*?)</script>}s
  @forward_lines ["f1", "f2", "f3", "f4"]
  @defense_pairs ["d1", "d2", "d3"]
  @power_play_units ["pp1", "pp2"]
  @penalty_kill_units ["pk1", "pk2"]
  @goalies "g"
  @left_to_right %{"lw" => 0, "c" => 1, "rw" => 2, "ld" => 0, "rd" => 1, "g1" => 0, "g2" => 1}

  @doc """
  `{:ok, team}` for a team id from `Aviary.Nhl.Standings`, or `:error`
  for an unknown team or when the league doesn't answer. A source that
  fails on its own leaves its part of the page empty.
  """
  def fetch(team_id) when is_binary(team_id) do
    with {:ok, teams} <- Standings.teams(),
         %{} = standing <- Enum.find(teams, &(&1.id == team_id)) do
      case Cache.swr({:nhl, :team, team_id}, @fresh_ms, @stale_ms, fn ->
             {:ok, gathered(standing, teams)}
           end) do
        {:ok, _team} = found -> found
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  def fetch(_team_id), do: :error

  defp gathered(standing, teams) do
    abbreviation = standing.abbreviation

    [roster, schedule, scoring, lines_page, injuries] =
      [
        fn -> league("/roster/#{abbreviation}/current") end,
        fn -> league("/club-schedule-season/#{abbreviation}/now") end,
        fn -> league("/club-stats/#{abbreviation}/now") end,
        fn -> lines_page(standing.id) end,
        fn -> injuries() end
      ]
      |> Task.async_stream(& &1.(),
        max_concurrency: @sources_at_once,
        timeout: 2 * @request_timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {:ok, found}} -> found
        _ -> nil
      end)

    players = players(roster)
    games = games(schedule, abbreviation, teams)

    %{
      id: standing.id,
      name: standing.name,
      nickname: standing.nickname,
      standing: standing,
      next_game: Enum.find(games, &(not &1.finished)),
      recent_games:
        games |> Enum.filter(& &1.finished) |> Enum.take(-@recent_games_shown) |> Enum.reverse(),
      lines: lines(lines_page, players),
      roster: players,
      injuries: team_injuries(injuries, standing, players),
      scoring_leaders: scoring_leaders(scoring),
      goalies: goalie_records(scoring)
    }
  end

  defp players(%{} = roster) do
    for {group, position} <- [{"forwards", nil}, {"defensemen", "D"}, {"goalies", "G"}],
        listed <- Map.get(roster, group, []) do
      %{
        name: full_name(listed),
        number: listed["sweaterNumber"],
        position: position || listed["positionCode"],
        headshot: listed["headshot"]
      }
    end
  end

  defp players(_roster), do: []

  defp full_name(%{"firstName" => %{"default" => first}, "lastName" => %{"default" => last}}),
    do: "#{first} #{last}"

  defp full_name(_listed), do: nil

  defp games(%{"games" => listed}, abbreviation, teams) when is_list(listed) do
    listed
    |> Enum.filter(&(&1["gameType"] in [@regular_season, @playoffs]))
    |> Enum.map(&game(&1, abbreviation, teams))
  end

  defp games(_schedule, _abbreviation, _teams), do: []

  defp game(listed, abbreviation, teams) do
    at_home = get_in(listed, ["homeTeam", "abbrev"]) == abbreviation
    {own, other} = if at_home, do: {"homeTeam", "awayTeam"}, else: {"awayTeam", "homeTeam"}
    finished = listed["gameState"] in @finished_states
    opponent = Enum.find(teams, &(&1.abbreviation == get_in(listed, [other, "abbrev"])))

    %{
      starts_at: listed["startTimeUTC"],
      at_home: at_home,
      finished: finished,
      opponent: %{
        id: opponent && opponent.id,
        nickname: get_in(listed, [other, "commonName", "default"])
      },
      score: finished && get_in(listed, [own, "score"]),
      opponent_score: finished && get_in(listed, [other, "score"]),
      decided_in: finished && get_in(listed, ["gameOutcome", "lastPeriodType"])
    }
  end

  defp lines(%{"players" => listed} = combinations, players) when is_list(listed) do
    in_group = Enum.group_by(listed, & &1["groupIdentifier"])

    group = fn id ->
      in_group
      |> Map.get(id, [])
      |> Enum.sort_by(
        &Map.get(@left_to_right, &1["positionIdentifier"], &1["positionIdentifier"])
      )
      |> Enum.map(&lined_up(&1, players))
    end

    groups = fn ids -> ids |> Enum.map(group) |> Enum.reject(&(&1 == [])) end

    case groups.(@forward_lines) do
      [] ->
        nil

      forwards ->
        %{
          as_of: combinations["sourceName"],
          forwards: forwards,
          defense: groups.(@defense_pairs),
          goalies: group.(@goalies),
          power_play: groups.(@power_play_units),
          penalty_kill: groups.(@penalty_kill_units)
        }
    end
  end

  defp lines(_combinations, _players), do: nil

  defp lined_up(listed, players) do
    on_roster =
      Enum.find(players, &(&1.number == listed["jerseyNumber"])) ||
        Enum.find(players, &same_person?(&1.name, listed["name"]))

    %{
      name: listed["name"],
      number: listed["jerseyNumber"] || (on_roster && on_roster.number),
      position: on_roster && on_roster.position,
      headshot: (on_roster && on_roster.headshot) || listed["fantasydataFaceUrl"]
    }
  end

  defp team_injuries(%{"injuries" => by_team}, standing, players) when is_list(by_team) do
    by_team
    |> Enum.find(%{}, &same_person?(&1["displayName"], standing.name))
    |> Map.get("injuries", [])
    |> Enum.map(fn listed ->
      name = get_in(listed, ["athlete", "displayName"])
      on_roster = Enum.find(players, &same_person?(&1.name, name))

      %{
        player: %{
          name: name,
          number: on_roster && on_roster.number,
          position:
            (on_roster && on_roster.position) ||
              get_in(listed, ["athlete", "position", "abbreviation"]),
          headshot:
            (on_roster && on_roster.headshot) || get_in(listed, ["athlete", "headshot", "href"])
        },
        status: listed["status"],
        injury: get_in(listed, ["details", "type"]),
        expected_back: get_in(listed, ["details", "returnDate"]),
        note: listed["shortComment"]
      }
    end)
  end

  defp team_injuries(_injuries, _standing, _players), do: []

  defp scoring_leaders(%{"skaters" => skaters}) when is_list(skaters) do
    skaters
    |> Enum.sort_by(&{-(&1["points"] || 0), -(&1["goals"] || 0)})
    |> Enum.take(@scoring_leaders_shown)
    |> Enum.map(fn listed ->
      %{
        player: %{
          name: full_name(listed),
          number: nil,
          position: listed["positionCode"],
          headshot: listed["headshot"]
        },
        games_played: listed["gamesPlayed"],
        goals: listed["goals"],
        assists: listed["assists"],
        points: listed["points"]
      }
    end)
  end

  defp scoring_leaders(_scoring), do: []

  defp goalie_records(%{"goalies" => goalies}) when is_list(goalies) do
    goalies
    |> Enum.sort_by(&(-(&1["gamesStarted"] || 0)))
    |> Enum.map(fn listed ->
      %{
        player: %{
          name: full_name(listed),
          number: nil,
          position: "G",
          headshot: listed["headshot"]
        },
        games_started: listed["gamesStarted"],
        wins: listed["wins"],
        losses: listed["losses"],
        overtime_losses: listed["overtimeLosses"],
        save_percentage: listed["savePercentage"],
        goals_against_average: listed["goalsAgainstAverage"]
      }
    end)
  end

  defp goalie_records(_scoring), do: []

  defp same_person?(a, b) when is_binary(a) and is_binary(b), do: comparable(a) == comparable(b)
  defp same_person?(_a, _b), do: false

  defp comparable(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/[^A-Za-z]/u, "")
    |> String.downcase()
  end

  defp league(path), do: json(@league_api <> path)

  defp injuries do
    Cache.fetch({:nhl, :injuries}, @fresh_ms, fn -> json(@injuries_url) end)
  end

  defp lines_page(team_id) do
    with {:ok, html} when is_binary(html) <-
           get("#{@lines_site}/#{team_id}/line-combinations",
             headers: [{"user-agent", @browser_user_agent}]
           ),
         [_, data] <- Regex.run(@page_data, html),
         {:ok, %{"props" => %{"pageProps" => %{"combinations" => %{} = combinations}}}} <-
           Jason.decode(data) do
      {:ok, combinations}
    else
      _ -> :error
    end
  end

  defp json(url) do
    case get(url, []) do
      {:ok, %{} = body} -> {:ok, body}
      _ -> :error
    end
  end

  defp get(url, options) do
    options =
      [receive_timeout: @request_timeout_ms, retry: false]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:aviary, :nhl_team_req_options, []))

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
