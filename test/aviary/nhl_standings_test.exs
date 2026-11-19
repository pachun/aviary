defmodule Aviary.NhlStandingsTest do
  use ExUnit.Case, async: false

  alias Aviary.Nhl.Standings

  setup do
    Aviary.Cache.invalidate({:nhl, :standings})
    :ok
  end

  test "lists each division east to west with its teams in rank order" do
    stub_league([
      listed("Edmonton Oilers", "Oilers", "Pacific", "Western", 1),
      listed("Boston Bruins", "Bruins", "Atlantic", "Eastern", 2),
      listed("Montréal Canadiens", "Canadiens", "Atlantic", "Eastern", 1)
    ])

    assert {:ok,
            [
              %{
                name: "Atlantic",
                conference: "Eastern",
                teams: [%{name: "Montréal Canadiens", rank: 1}, %{name: "Boston Bruins", rank: 2}]
              },
              %{name: "Pacific", conference: "Western", teams: [%{nickname: "Oilers"}]}
            ]} = Standings.divisions()
  end

  test "gives each team its record, form and the id its logo is served under" do
    stub_league([
      "St. Louis Blues"
      |> listed("Blues", "Central", "Western", 1)
      |> Map.merge(%{
        "gamesPlayed" => 23,
        "wins" => 17,
        "losses" => 3,
        "otLosses" => 3,
        "points" => 37,
        "goalDifferential" => -4,
        "l10Wins" => 8,
        "l10Losses" => 1,
        "l10OtLosses" => 1,
        "streakCode" => "W",
        "streakCount" => 6
      })
    ])

    assert {:ok, [%{teams: [blues]}]} = Standings.divisions()

    assert %{
             id: "st-louis-blues",
             games_played: 23,
             wins: 17,
             losses: 3,
             overtime_losses: 3,
             points: 37,
             goal_difference: -4,
             last_ten: "8-1-1",
             streak: "W6"
           } = blues
  end

  test "serves a logo for a team whose name carries an accent" do
    stub_league([listed("Montréal Canadiens", "Canadiens", "Atlantic", "Eastern", 1)])

    assert {:ok, [%{teams: [%{id: "montreal-canadiens"}]}]} = Standings.divisions()
  end

  test "is an error when the league doesn't answer, and asks again next time" do
    Req.Test.stub(Standings, &Plug.Conn.send_resp(&1, 503, ""))
    assert Standings.divisions() == :error

    stub_league([listed("Boston Bruins", "Bruins", "Atlantic", "Eastern", 1)])
    assert {:ok, [%{name: "Atlantic"}]} = Standings.divisions()
  end

  defp listed(name, nickname, division, conference, rank) do
    %{
      "teamName" => %{"default" => name},
      "teamCommonName" => %{"default" => nickname},
      "divisionName" => division,
      "conferenceName" => conference,
      "divisionSequence" => rank
    }
  end

  defp stub_league(teams) do
    Req.Test.stub(Standings, &Req.Test.json(&1, %{"standings" => teams}))
  end
end
