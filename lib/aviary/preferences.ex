defmodule Aviary.Preferences do
  @moduledoc """
  Per-user playback preferences, shared by every surface (tvOS, web,
  mobile) so a member's choice follows them across devices. Keyed by
  Jellyfin user id — aviary owns no identity of its own.

  Currently a single preference: whether subtitles start on. It's set
  explicitly in Settings and implicitly whenever the user changes
  subtitles during playback.
  """
  import Ecto.Query

  alias Aviary.Preferences.UserSetting
  alias Aviary.Repo

  @doc "Whether subtitles start on for this user. Defaults to off."
  def subtitles_default?(user_id) when is_binary(user_id) do
    Repo.one(
      from s in UserSetting,
        where: s.jellyfin_user_id == ^user_id,
        select: s.subtitles_default
    ) || false
  end

  @doc "Sets the user's subtitles-on-by-default preference. Upserts."
  def set_subtitles_default(user_id, on)
      when is_binary(user_id) and is_boolean(on) do
    %UserSetting{}
    |> UserSetting.changeset(%{jellyfin_user_id: user_id, subtitles_default: on})
    |> Repo.insert(
      on_conflict: {:replace, [:subtitles_default, :updated_at]},
      conflict_target: :jellyfin_user_id
    )

    :ok
  end
end
