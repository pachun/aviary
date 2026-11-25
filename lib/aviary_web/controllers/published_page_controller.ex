defmodule AviaryWeb.PublishedPageController do
  @moduledoc """
  Pages a server publishes to anyone, signed in or not: a privacy policy
  and a support page. Each is an HTML fragment the server's owner keeps
  in the folder named by `PAGES_DIR`, as `privacy.html` and
  `support.html`. A server without the file has no such page.
  """
  use AviaryWeb, :controller

  @titles %{"privacy" => "Privacy", "support" => "Support"}

  def privacy(conn, _params), do: publish(conn, "privacy")
  def support(conn, _params), do: publish(conn, "support")

  defp publish(conn, page) do
    case written(page) do
      {:ok, body} ->
        render(conn, :show, page_title: @titles[page], body: body)

      :error ->
        conn
        |> put_status(:not_found)
        |> put_view(html: AviaryWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp written(page) do
    with folder when is_binary(folder) and folder != "" <-
           Application.get_env(:aviary, :pages_dir),
         {:ok, body} <- File.read(Path.join(folder, page <> ".html")) do
      {:ok, body}
    else
      _ -> :error
    end
  end
end
