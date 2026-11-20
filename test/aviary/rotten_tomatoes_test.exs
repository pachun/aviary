defmodule Aviary.RottenTomatoesTest do
  use ExUnit.Case, async: false

  alias Aviary.RottenTomatoes

  test "looks nothing up on a server set up without ratings" do
    Application.put_env(:aviary, :ratings, false)
    on_exit(fn -> Application.delete_env(:aviary, :ratings) end)

    assert RottenTomatoes.fetch("His Girl Friday", :movie, 1940) == nil
  end

  test "reads both scores from a page that gives them as percentages" do
    page = """
    <script>{"audienceScore":{"bandedRatingCount":"5,000+ Ratings","certified":false,"scorePercent":"80%","sentiment":"POSITIVE","title":"Avg. Popcornmeter"},
    "criticsScore":{"averageRating":"8.70","certified":false,"likedCount":232,"reviewCount":242,"scorePercent":"95%","sentiment":"POSITIVE","title":"Avg. Tomatometer"}}</script>
    """

    assert RottenTomatoes.scores_in_page(page) == %{critic: 95, audience: 80}
  end

  test "reads both scores from a page that gives them as bare numbers" do
    page = """
    <script>{"audienceScore":{"certified":false,"score":"85","sentiment":"POSITIVE"},
    "criticsScore":{"certified":true,"score":"83","sentiment":"POSITIVE"}}</script>
    """

    assert RottenTomatoes.scores_in_page(page) == %{critic: 83, audience: 85}
  end

  test "gives nothing for a page with only one of the two scores" do
    page =
      ~s|{"criticsScore":{"certified":false,"scorePercent":"95%"},"audienceScore":{"certified":false}}|

    assert RottenTomatoes.scores_in_page(page) == nil
  end
end
