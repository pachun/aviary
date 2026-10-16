defmodule Aviary.SonarrTest do
  use ExUnit.Case, async: true

  alias Aviary.Sonarr

  describe "standalone_episodes?/1" do
    test "a game show stands alone" do
      assert Sonarr.standalone_episodes?(%{
               "seriesType" => "standard",
               "genres" => ["Family", "Game Show", "Reality"]
             })
    end

    test "a talk show stands alone" do
      assert Sonarr.standalone_episodes?(%{
               "seriesType" => "standard",
               "genres" => ["Comedy", "News", "Talk Show"]
             })
    end

    test "a daily series stands alone whatever its genres" do
      assert Sonarr.standalone_episodes?(%{"seriesType" => "daily", "genres" => ["Drama"]})
    end

    test "a drama is watched in order" do
      refute Sonarr.standalone_episodes?(%{
               "seriesType" => "standard",
               "genres" => ["Drama", "Romance", "Soap"]
             })
    end

    test "a series with no genres is watched in order" do
      refute Sonarr.standalone_episodes?(%{"seriesType" => "standard"})
    end
  end
end
