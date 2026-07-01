defmodule AviaryWeb.API.PreferencesController do
  @moduledoc """
  Per-user playback preferences for native clients. `show` returns the
  current values; `update` sets them. Backed by `Aviary.Preferences`,
  so the same values are visible to every surface.
  """
  use AviaryWeb, :controller

  alias Aviary.Preferences

  def show(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{subtitlesDefault: Preferences.subtitles_default?(user.id)})
  end

  def update(conn, %{"subtitlesDefault" => on}) when is_boolean(on) do
    user = conn.assigns.current_user
    Preferences.set_subtitles_default(user.id, on)
    json(conn, %{subtitlesDefault: on})
  end
end
