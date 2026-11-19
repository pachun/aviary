defmodule AviaryWeb.API.NhlTeam do
  @moduledoc """
  The JSON shape of one NHL team's page for the tvOS client.
  """

  def serialize(team) do
    %{
      id: team.id,
      name: team.name,
      nickname: team.nickname,
      logo: logo(team.id),
      standing: standing(team.standing),
      nextGame: team.next_game && game(team.next_game),
      recentGames: Enum.map(team.recent_games, &game/1),
      lines: team.lines && lines(team.lines),
      roster: Enum.map(team.roster, &player/1),
      injuries: Enum.map(team.injuries, &injury/1),
      scoringLeaders: Enum.map(team.scoring_leaders, &scorer/1),
      goalies: Enum.map(team.goalies, &goalie/1)
    }
  end

  defp logo(nil), do: nil
  defp logo(team_id), do: "/api/v1/nhl/logos/#{team_id}?background=dark"

  defp standing(standing) do
    %{
      division: standing.division,
      rank: standing.rank,
      gamesPlayed: standing.games_played,
      wins: standing.wins,
      losses: standing.losses,
      overtimeLosses: standing.overtime_losses,
      points: standing.points,
      goalDifference: standing.goal_difference,
      lastTen: standing.last_ten,
      streak: standing.streak
    }
  end

  defp game(game) do
    %{
      startsAt: game.starts_at,
      atHome: game.at_home,
      finished: game.finished,
      opponent: %{nickname: game.opponent.nickname, logo: logo(game.opponent.id)},
      score: game.score || nil,
      opponentScore: game.opponent_score || nil,
      decidedIn: game.decided_in || nil
    }
  end

  defp lines(lines) do
    %{
      asOf: lines.as_of,
      forwards: groups(lines.forwards),
      defense: groups(lines.defense),
      goalies: Enum.map(lines.goalies, &player/1),
      powerPlay: groups(lines.power_play),
      penaltyKill: groups(lines.penalty_kill)
    }
  end

  defp groups(groups), do: Enum.map(groups, fn group -> Enum.map(group, &player/1) end)

  defp player(player) do
    %{
      name: player.name,
      number: player.number,
      position: player.position,
      headshot: player.headshot
    }
  end

  defp injury(injury) do
    %{
      player: player(injury.player),
      status: injury.status,
      injury: injury.injury,
      expectedBack: injury.expected_back,
      note: injury.note
    }
  end

  defp scorer(scorer) do
    %{
      player: player(scorer.player),
      gamesPlayed: scorer.games_played,
      goals: scorer.goals,
      assists: scorer.assists,
      points: scorer.points
    }
  end

  defp goalie(goalie) do
    %{
      player: player(goalie.player),
      gamesStarted: goalie.games_started,
      wins: goalie.wins,
      losses: goalie.losses,
      overtimeLosses: goalie.overtime_losses,
      savePercentage: goalie.save_percentage,
      goalsAgainstAverage: goalie.goals_against_average
    }
  end
end
