defmodule AviaryWeb.ErrorHTMLTest do
  use AviaryWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    document =
      render_to_string(AviaryWeb.ErrorHTML, "404", "html", []) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() ==
             "Page Not Found"
  end

  test "renders 500.html" do
    document =
      render_to_string(AviaryWeb.ErrorHTML, "500", "html", []) |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("h1") |> LazyHTML.text() |> String.trim() ==
             "Uh oh. Something Went Wrong."
  end
end
