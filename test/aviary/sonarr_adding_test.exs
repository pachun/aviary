defmodule Aviary.SonarrAddingTest do
  use ExUnit.Case, async: false

  alias Aviary.Sonarr

  @tmdb_id "63351"
  @series_id 282
  @first_episode_id 15252
  @setup_checks_before_done 3

  setup do
    Aviary.Cache.invalidate(:sonarr_series_list)
    Application.put_env(:aviary, :sonarr_setup_check_every_ms, 1)
    on_exit(fn -> Application.delete_env(:aviary, :sonarr_setup_check_every_ms) end)

    {:ok, sonarr} =
      Agent.start_link(fn -> %{added: false, checks: 0, monitored_while_adding: []} end)

    stub_slow_sonarr(sonarr)
    %{sonarr: sonarr}
  end

  test "waits for Sonarr to finish setting up a new show before choosing its first episode",
       %{sonarr: sonarr} do
    assert Sonarr.starting_episode(@tmdb_id) == {:ok, 1, 1}
    assert Agent.get(sonarr, & &1.added)
  end

  test "monitors the chosen episode only after Sonarr's own setup can't undo it",
       %{sonarr: sonarr} do
    assert {:ok, %{"id" => @first_episode_id}} = Sonarr.watch_episode(@tmdb_id, 1, 1)
    assert Agent.get(sonarr, & &1.monitored_while_adding) == [false]
  end

  test "reports a show Sonarr is still setting up", %{sonarr: sonarr} do
    {:ok, _series} = Sonarr.add_series(%{"tvdbId" => 1, "title" => "Narcos"}, monitor: "none")

    assert {:ok, %{being_added: true}} = Sonarr.series_status(@tmdb_id)

    Agent.update(sonarr, &%{&1 | added: true})
    Aviary.Cache.invalidate(:sonarr_series_list)

    assert {:ok, %{being_added: false}} = Sonarr.series_status(@tmdb_id)
  end

  defp stub_slow_sonarr(sonarr) do
    Req.Test.stub(Sonarr, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      state = Agent.get(sonarr, & &1)

      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/series"} ->
          Req.Test.json(conn, if(state.checks > 0 or state.added, do: [series(state)], else: []))

        {"GET", "/api/v3/series/lookup"} ->
          Req.Test.json(conn, [%{"tvdbId" => 1, "title" => "Narcos", "genres" => ["Drama"]}])

        {"POST", "/api/v3/series"} ->
          Agent.update(sonarr, &%{&1 | checks: 1})
          Req.Test.json(conn, series(state))

        {"GET", "/api/v3/series/" <> _id} ->
          Agent.update(sonarr, fn s ->
            checks = s.checks + 1
            %{s | checks: checks, added: s.added or checks > @setup_checks_before_done}
          end)

          Req.Test.json(conn, series(Agent.get(sonarr, & &1)))

        {"GET", "/api/v3/episode"} ->
          Req.Test.json(conn, if(state.checks > 1, do: episodes(), else: []))

        {"PUT", "/api/v3/episode/monitor"} ->
          Agent.update(
            sonarr,
            &%{&1 | monitored_while_adding: [not &1.added | &1.monitored_while_adding]}
          )

          Req.Test.json(conn, [])

        {"GET", "/api/v3/queue"} ->
          Req.Test.json(conn, %{"records" => []})

        {"POST", "/api/v3/command"} ->
          Req.Test.json(conn, %{"id" => 1, "status" => "queued"})
      end
    end)
  end

  defp series(%{added: added}) do
    %{
      "id" => @series_id,
      "tmdbId" => String.to_integer(@tmdb_id),
      "title" => "Narcos",
      "genres" => ["Drama"],
      "monitored" => false,
      "addOptions" => if(added, do: nil, else: %{"monitor" => "none"})
    }
  end

  defp episodes do
    [
      %{
        "id" => @first_episode_id,
        "seasonNumber" => 1,
        "episodeNumber" => 1,
        "airDate" => "2015-08-28",
        "monitored" => false,
        "hasFile" => false
      }
    ]
  end
end
