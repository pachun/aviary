defmodule AviaryWeb.LibraryControllerTest do
  use AviaryWeb.ConnCase, async: false

  alias AviaryWeb.API.LibraryController

  @moduletag :capture_log
  @viewer %{id: "library-viewer", token: "viewer-token"}

  setup do
    Aviary.Cache.invalidate(:sonarr_series_list)
    Application.put_env(:aviary, :sonarr_setup_check_every_ms, 1_000)

    on_exit(fn ->
      Application.delete_env(:aviary, :sonarr_setup_check_every_ms)
      stop_background_downloads()
    end)

    :ok
  end

  test "adding a show answers as soon as Sonarr has it, without waiting out Sonarr's setup" do
    Req.Test.stub(Aviary.Sonarr, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v3/series"} ->
          Req.Test.json(conn, [])

        {"GET", "/api/v3/series/lookup"} ->
          Req.Test.json(conn, [%{"tvdbId" => 1, "title" => "Narcos"}])

        {"POST", "/api/v3/series"} ->
          Req.Test.json(conn, %{"id" => 282, "addOptions" => %{}})

        {"GET", "/api/v3/series/282"} ->
          Req.Test.json(conn, %{"id" => 282, "addOptions" => %{}})

        {"GET", "/api/v3/episode"} ->
          Req.Test.json(conn, [])
      end
    end)

    {elapsed_us, conn} =
      :timer.tc(fn ->
        build_conn()
        |> assign(:current_user, @viewer)
        |> LibraryController.add(%{"kind" => "show", "id" => 63351})
      end)

    assert json_response(conn, 200) == %{"ok" => true}
    assert elapsed_us < 2_000_000
  end

  test "adding a show says the downloader is unavailable when Sonarr won't take it" do
    Req.Test.stub(Aviary.Sonarr, &Plug.Conn.send_resp(&1, 503, ""))

    conn =
      build_conn()
      |> assign(:current_user, @viewer)
      |> LibraryController.add(%{"kind" => "show", "id" => 63351})

    assert json_response(conn, 502) == %{"error" => "downloader_unavailable"}
  end

  defp stop_background_downloads do
    for pid <- Task.Supervisor.children(Aviary.TaskSupervisor) do
      Task.Supervisor.terminate_child(Aviary.TaskSupervisor, pid)
    end
  end
end
