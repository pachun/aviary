defmodule Aviary.Credits do
  @moduledoc """
  Who to thank for what a server shows: TMDB for artwork and details on
  every server, then whatever the server's sections file credits for
  the video it carries.
  """

  @tmdb "This product uses the TMDB API but is not endorsed or certified by TMDB."

  @doc "Every credit, one line each."
  def all, do: [@tmdb | Aviary.Sections.credits()]
end
