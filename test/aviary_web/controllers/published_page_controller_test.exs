defmodule AviaryWeb.PublishedPageControllerTest do
  use AviaryWeb.ConnCase, async: false

  setup do
    folder = Path.join(System.tmp_dir!(), "aviary-pages-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    Application.put_env(:aviary, :pages_dir, folder)

    on_exit(fn ->
      File.rm_rf(folder)
      Application.delete_env(:aviary, :pages_dir)
    end)

    %{folder: folder}
  end

  test "anyone can read a page the server publishes", %{conn: conn, folder: folder} do
    File.write!(Path.join(folder, "privacy.html"), "<h1>Privacy</h1><p>Nothing is tracked.</p>")

    assert conn |> get("/privacy") |> html_response(200) =~ "<p>Nothing is tracked.</p>"
  end

  test "a page the server hasn't written is not found", %{conn: conn} do
    assert conn |> get("/support") |> html_response(404)
  end
end
