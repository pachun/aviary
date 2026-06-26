defmodule Aviary.Preferences.UserSetting do
  @moduledoc """
  A household member's playback preferences — one row per user, keyed
  by Jellyfin identity (aviary has no users table of its own). Today
  it holds a single field: whether subtitles start on.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_preferences" do
    field :jellyfin_user_id, :string
    field :subtitles_default, :boolean, default: false

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:jellyfin_user_id, :subtitles_default])
    |> validate_required([:jellyfin_user_id, :subtitles_default])
    |> unique_constraint(:jellyfin_user_id)
  end
end
