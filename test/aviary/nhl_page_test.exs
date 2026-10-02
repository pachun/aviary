defmodule Aviary.Nhl.PageTest do
  use ExUnit.Case, async: true

  alias Aviary.Nhl.Page

  @fixtures Path.expand("../support/fixtures/nhl", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  describe "games/1" do
    test "reads every scheduled game and skips the date header row" do
      games = Page.games(fixture("schedule.html"))

      assert length(games) == 5

      assert hd(games) == %{
               id: "detroit-red-wings",
               time: "6:30",
               date: ~D[2026-10-02],
               away_team: %{
                 id: "new-york-rangers",
                 name: "New York Rangers",
                 nickname: "Rangers",
                 logo: "https://slapstreams.com/wp-content/uploads/2021/04/New-York-Rangers.svg"
               },
               home_team: %{
                 id: "detroit-red-wings",
                 name: "Detroit Red Wings",
                 nickname: "Red Wings",
                 logo: "https://slapstreams.com/wp-content/uploads/2021/04/Detroit-Red-Wings.svg"
               }
             }

      assert Enum.map(games, & &1.id) == [
               "detroit-red-wings",
               "carolina-hurricanes",
               "winnipeg-jets",
               "dallas-stars",
               "vegas-golden-knights"
             ]
    end

    test "returns no games for markup without the schedule table" do
      assert Page.games("<html><body>maintenance</body></html>") == []
    end

    test "keeps a game whose date text is unreadable" do
      row = """
      <tr class="singele_match_date ">
      <td class="matchtime">7:00</td>
      <td class="teamlogo"><a class="team" href="https://slapstreams.com/st-louis-blues-live/"><img src="/blues.svg"></a></td>
      <td class="teamlogo"><a class="team" href="https://slapstreams.com/utah-hockey-club-live/"><img src="/utah.svg"></a></td>
      <td class="teamvs"><span class="mtdate">Tonight</span></td>
      </tr>
      """

      assert [
               %{
                 date: nil,
                 away_team: %{name: "St. Louis Blues", nickname: "Blues", logo: "/blues.svg"},
                 home_team: %{name: "Utah Hockey Club", nickname: "Hockey Club"}
               }
             ] = Page.games(row)
    end
  end

  describe "feeds/1" do
    test "lists the feed buttons with the frame name as the id" do
      assert Page.feeds(fixture("team_page.html")) == [
               %{id: "wings", label: "HOME"},
               %{id: "rangers", label: "AWAY"},
               %{id: "wings2", label: "LINK 3"},
               %{id: "wings3", label: "LINK 4"}
             ]
    end
  end

  describe "lookup_params/1" do
    test "extracts the lookup query from the player frame" do
      assert Page.lookup_params(fixture("frame.html")) ==
               {:ok, [id: "178", ts: "1790976342", pt: "d704dccd6b0eef7c"]}
    end

    test "is an error when the frame carries no lookup values" do
      assert Page.lookup_params("<html></html>") == :error
    end
  end
end
