defmodule AviaryWeb.ErrorHTML do
  @moduledoc """
  Renders error pages (404 / 500) when something goes wrong on an
  HTML request. Templates live in `error_html/`. The pages are
  standalone — no Layouts.app wrapper, no LiveView — so they render
  safely even when the underlying error came from a layout dependency
  (current_user fetch, nav visibility, etc.).
  """
  use AviaryWeb, :html

  embed_templates "error_html/*"

  # Fallback for any status code we haven't templated (403, 502, etc.).
  # Still returns plain-text from Phoenix's built-in mapping. If we
  # ever care to design those individually, add a corresponding
  # template.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
