defmodule Aviary.NhlTeamTest do
  use ExUnit.Case, async: false

  alias Aviary.Nhl.Team

  setup :set_req_test_to_shared

  setup do
    Aviary.Cache.invalidate({:nhl, :standings})
    Aviary.Cache.invalidate({:nhl, :injuries})
    Aviary.Cache.invalidate_match({:nhl, :team, :_})

    Req.Test.stub(Aviary.Nhl.Standings, fn conn ->
      Req.Test.json(conn, %{
        "standings" => [
          standing("Edmonton Oilers", "Oilers", "EDM"),
          standing("Florida Panthers", "Panthers", "FLA")
        ]
      })
    end)

    :ok
  end

  test "puts each player on his line, left to right, with his league photo" do
    stub_sources(
      lines: [
        lined("Zach Hyman", 18, "f1", "rw"),
        lined("Connor McDavid", 97, "f1", "c"),
        lined("Colton Dach", 34, "f1", "lw"),
        lined("Evan Bouchard", 2, "d1", "rd"),
        lined("Mattias Ekholm", 14, "d1", "ld"),
        lined("Devon Levi", 27, "g", "g1"),
        lined("Connor McDavid", 97, "pp1", "sk1")
      ],
      roster: %{
        "forwards" => [rostered("Connor", "McDavid", 97, "C"), rostered("Zach", "Hyman", 18, "R")],
        "defensemen" => [rostered("Evan", "Bouchard", 2, "D")],
        "goalies" => []
      }
    )

    assert {:ok, %{lines: lines}} = Team.fetch("edmonton-oilers")
    assert lines.as_of == "Last Game (2026-11-17)"

    assert [
             [
               %{name: "Colton Dach"},
               %{name: "Connor McDavid", headshot: "mcdavid.png", position: "C"},
               %{name: "Zach Hyman"}
             ]
           ] =
             lines.forwards

    assert [[%{name: "Mattias Ekholm"}, %{name: "Evan Bouchard", number: 2}]] = lines.defense
    assert [%{name: "Devon Levi"}] = lines.goalies
    assert [[%{name: "Connor McDavid"}]] = lines.power_play
    assert lines.penalty_kill == []
  end

  test "shows the roster and no lines when the lines page can't be read" do
    stub_sources(
      lines: :unreadable,
      roster: %{"forwards" => [rostered("Connor", "McDavid", 97, "C")]}
    )

    assert {:ok, %{lines: nil, roster: [%{name: "Connor McDavid", number: 97}]}} =
             Team.fetch("edmonton-oilers")
  end

  test "lists who is out, why, and when he is expected back" do
    stub_sources(
      roster: %{"forwards" => [rostered("Matt", "Savoie", 22, "C")]},
      injuries: [
        %{
          "displayName" => "Edmonton Oilers",
          "injuries" => [
            %{
              "athlete" => %{"displayName" => "Matt Savoie"},
              "status" => "Injured Reserve",
              "shortComment" => "Savoie (lower body) was shifted to long-term injured reserve.",
              "details" => %{"type" => "Lower Body", "returnDate" => "2026-11-24"}
            }
          ]
        },
        %{
          "displayName" => "Florida Panthers",
          "injuries" => [%{"athlete" => %{"displayName" => "Someone Else"}}]
        }
      ]
    )

    assert {:ok, %{injuries: [out]}} = Team.fetch("edmonton-oilers")

    assert %{
             player: %{name: "Matt Savoie", number: 22, headshot: "savoie.png"},
             status: "Injured Reserve",
             injury: "Lower Body",
             expected_back: "2026-11-24"
           } = out
  end

  test "gives the next game and the latest results, newest first" do
    stub_sources(
      games: [
        played("2026-11-10T00:00:00Z", {"EDM", 1}, {"FLA", 2}, "OT"),
        played("2026-11-18T00:00:00Z", {"FLA", 2}, {"EDM", 5}, "REG"),
        %{
          "gameType" => 2,
          "gameState" => "FUT",
          "startTimeUTC" => "2026-11-20T00:30:00Z",
          "awayTeam" => side("FLA", nil),
          "homeTeam" => side("EDM", nil)
        },
        %{
          "gameType" => 1,
          "gameState" => "OFF",
          "startTimeUTC" => "2026-09-20T00:00:00Z",
          "awayTeam" => side("FLA", 9),
          "homeTeam" => side("EDM", 0)
        }
      ]
    )

    assert {:ok, %{next_game: next, recent_games: [latest, earlier]}} =
             Team.fetch("edmonton-oilers")

    assert %{
             starts_at: "2026-11-20T00:30:00Z",
             at_home: true,
             opponent: %{id: "florida-panthers", nickname: "Panthers"}
           } = next

    assert %{at_home: true, score: 5, opponent_score: 2, decided_in: "REG"} = latest
    assert %{at_home: false, score: 1, opponent_score: 2, decided_in: "OT"} = earlier
  end

  test "ranks the scorers by points" do
    stub_sources(
      scoring: %{
        "skaters" => [scorer("Leon", "Draisaitl", 21, 23), scorer("Connor", "McDavid", 13, 42)],
        "goalies" => [
          %{
            "firstName" => %{"default" => "Devon"},
            "lastName" => %{"default" => "Levi"},
            "gamesStarted" => 11,
            "wins" => 10,
            "losses" => 1,
            "overtimeLosses" => 0,
            "savePercentage" => 0.906
          }
        ]
      }
    )

    assert {:ok,
            %{
              scoring_leaders: [%{player: %{name: "Connor McDavid"}, points: 55}, %{points: 44}],
              goalies: [%{wins: 10, save_percentage: 0.906}]
            }} =
             Team.fetch("edmonton-oilers")
  end

  test "is an error for a team that doesn't exist" do
    stub_sources([])
    assert Team.fetch("hartford-whalers") == :error
  end

  defp standing(name, nickname, abbreviation) do
    %{
      "teamName" => %{"default" => name},
      "teamCommonName" => %{"default" => nickname},
      "teamAbbrev" => %{"default" => abbreviation},
      "divisionName" => "Pacific",
      "conferenceName" => "Western",
      "divisionSequence" => 1
    }
  end

  defp lined(name, number, group, position) do
    %{
      "name" => name,
      "jerseyNumber" => number,
      "groupIdentifier" => group,
      "positionIdentifier" => position
    }
  end

  defp rostered(first, last, number, position) do
    %{
      "firstName" => %{"default" => first},
      "lastName" => %{"default" => last},
      "sweaterNumber" => number,
      "positionCode" => position,
      "headshot" => String.downcase(last) <> ".png"
    }
  end

  defp scorer(first, last, goals, assists) do
    %{
      "firstName" => %{"default" => first},
      "lastName" => %{"default" => last},
      "goals" => goals,
      "assists" => assists,
      "points" => goals + assists
    }
  end

  defp side(abbreviation, score) do
    %{
      "abbrev" => abbreviation,
      "score" => score,
      "commonName" => %{"default" => if(abbreviation == "FLA", do: "Panthers", else: "Oilers")}
    }
  end

  defp played(starts_at, away, home, decided_in) do
    {away_team, away_score} = away
    {home_team, home_score} = home

    %{
      "gameType" => 2,
      "gameState" => "OFF",
      "startTimeUTC" => starts_at,
      "awayTeam" => side(away_team, away_score),
      "homeTeam" => side(home_team, home_score),
      "gameOutcome" => %{"lastPeriodType" => decided_in}
    }
  end

  defp stub_sources(sources) do
    Req.Test.stub(Team, fn conn ->
      case {conn.host, conn.path_info} do
        {"api-web.nhle.com", ["v1", "roster" | _]} ->
          Req.Test.json(conn, Keyword.get(sources, :roster, %{}))

        {"api-web.nhle.com", ["v1", "club-schedule-season" | _]} ->
          Req.Test.json(conn, %{"games" => Keyword.get(sources, :games, [])})

        {"api-web.nhle.com", ["v1", "club-stats" | _]} ->
          Req.Test.json(conn, Keyword.get(sources, :scoring, %{}))

        {"site.api.espn.com", _} ->
          Req.Test.json(conn, %{"injuries" => Keyword.get(sources, :injuries, [])})

        {"www.dailyfaceoff.com", _} ->
          case Keyword.get(sources, :lines, []) do
            :unreadable -> Req.Test.html(conn, "<html>redesigned</html>")
            players -> Req.Test.html(conn, lines_page(players))
          end
      end
    end)
  end

  defp lines_page(players) do
    data = %{
      props: %{
        pageProps: %{combinations: %{sourceName: "Last Game (2026-11-17)", players: players}}
      }
    }

    ~s|<html><script id="__NEXT_DATA__" type="application/json">#{Jason.encode!(data)}</script></html>|
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)
end
