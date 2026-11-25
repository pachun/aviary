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

  describe "fetch/4 finding the right page" do
    setup do
      :ets.delete_all_objects(:rotten_tomatoes_cache)
      :ets.delete_all_objects(:rotten_tomatoes_wikidata_cache)
      :ok
    end

    test "prefers the page Rotten Tomatoes keeps for that year over an older film's" do
      stub_rotten_tomatoes(fn
        "/m/resident_evil_2026" -> {:page, 82, 79}
        "/m/resident_evil" -> {:page, 34, 63}
        _ -> :missing
      end)

      assert RottenTomatoes.fetch("Resident Evil", :movie, 2026) == %{critic: 82, audience: 79}
    end

    test "uses the title's own page when there's no page for that year" do
      stub_rotten_tomatoes(fn
        "/m/brooklyn" -> {:page, 97, 85}
        _ -> :missing
      end)

      assert RottenTomatoes.fetch("Brooklyn", :movie, 2015) == %{critic: 97, audience: 85}
    end

    test "asks Wikidata again later when it was too busy to answer" do
      Req.Test.stub(RottenTomatoes, fn
        %{host: "query.wikidata.org"} = conn -> Plug.Conn.send_resp(conn, 429, "")
        conn -> Plug.Conn.send_resp(conn, 404, "")
      end)

      assert RottenTomatoes.fetch("Carol", :movie, 2015, "tt2402927") == nil

      stub_rotten_tomatoes(fn
        "/sparql" -> {:wikidata, "m/carol_2015"}
        "/m/carol_2015" -> {:page, 94, 70}
        _ -> :missing
      end)

      assert RottenTomatoes.fetch("Carol", :movie, 2015, "tt2402927") == %{
               critic: 94,
               audience: 70
             }
    end
  end

  defp stub_rotten_tomatoes(respond_to_path) do
    Req.Test.stub(RottenTomatoes, fn conn ->
      case respond_to_path.(conn.request_path) do
        {:page, critic, audience} ->
          Req.Test.html(
            conn,
            ~s|{"audienceScore":{"score":"#{audience}"},"criticsScore":{"score":"#{critic}"}}|
          )

        {:wikidata, path} ->
          Req.Test.json(conn, %{"results" => %{"bindings" => [%{"rt" => %{"value" => path}}]}})

        :missing ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end
end
