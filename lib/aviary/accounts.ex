defmodule Aviary.Accounts do
  @moduledoc """
  Household accounts, managed by the Jellyfin administrator from
  Settings. Accounts live in Jellyfin; every call here goes through
  aviary's own API key because a member's token can't manage accounts.
  """

  import Ecto.Query

  alias Aviary.{Deletions, Jellyfin, Library, Radarr, Repo, Sonarr}
  alias Aviary.DailyWire.Progress
  alias Aviary.Library.UserBackfill
  alias Aviary.Preferences.UserSetting
  alias Aviary.Recommendations.{Dismissal, Recommendation}

  @preferred_audio_language "eng"

  def manager?(%{id: id}) when is_binary(id) do
    with %{} = server <- Jellyfin.server_auth(),
         {:ok, account} <- Jellyfin.account(id, server) do
      administrator?(account)
    else
      _ -> false
    end
  end

  def manager?(_), do: false

  def list(acting_user) do
    with {:ok, server} <- authorize(acting_user),
         {:ok, accounts} <- Jellyfin.accounts(server) do
      {:ok, accounts |> Enum.map(&to_member/1) |> Enum.sort_by(&String.downcase(&1.username))}
    end
  end

  def add(acting_user, username, password) do
    username = String.trim(username)

    with {:ok, server} <- authorize(acting_user),
         :ok <- require_present(username, :username_missing),
         :ok <- require_present(password, :password_missing),
         :ok <- require_unused(username, nil, server),
         {:ok, account} <- Jellyfin.create_account(username, password, server) do
      case set_up_like_the_rest_of_the_household(account, server) do
        :ok ->
          {:ok, to_member(account)}

        error ->
          Jellyfin.delete_account(account["Id"], server)
          error
      end
    end
  end

  def rename(acting_user, account_id, username) do
    username = String.trim(username)

    with {:ok, server} <- authorize(acting_user),
         :ok <- require_present(username, :username_missing),
         :ok <- require_unused(username, account_id, server),
         {:ok, account} <- Jellyfin.account(account_id, server),
         {:ok, _} <- Jellyfin.update_account(Map.put(account, "Name", username), server) do
      :ok
    end
  end

  def change_password(acting_user, account_id, password) do
    with {:ok, server} <- authorize(acting_user),
         :ok <- require_present(password, :password_missing),
         {:ok, _} <- Jellyfin.set_account_password(account_id, password, server) do
      :ok
    end
  end

  def remove(acting_user, account_id) do
    with {:ok, server} <- authorize(acting_user),
         :ok <- require_someone_else(acting_user, account_id),
         {:ok, account} <- Jellyfin.account(account_id, server),
         :ok <- require_ordinary_member(account),
         {:ok, _} <- Jellyfin.delete_account(account_id, server) do
      forget(account_id)
    end
  end

  defp authorize(acting_user) do
    if manager?(acting_user), do: {:ok, Jellyfin.server_auth()}, else: {:error, :not_allowed}
  end

  defp administrator?(account), do: get_in(account, ["Policy", "IsAdministrator"]) == true

  defp to_member(account) do
    %{id: account["Id"], username: account["Name"], manager?: administrator?(account)}
  end

  defp require_present(text, reason) do
    if is_binary(text) and String.trim(text) != "", do: :ok, else: {:error, reason}
  end

  defp require_unused(username, renamed_account_id, server) do
    with {:ok, accounts} <- Jellyfin.accounts(server) do
      taken? =
        Enum.any?(accounts, fn account ->
          account["Id"] != renamed_account_id and
            String.downcase(account["Name"]) == String.downcase(username)
        end)

      if taken?, do: {:error, :username_taken}, else: :ok
    end
  end

  defp require_someone_else(%{id: id}, id), do: {:error, :cannot_remove_yourself}
  defp require_someone_else(_acting_user, _account_id), do: :ok

  defp require_ordinary_member(account) do
    if administrator?(account), do: {:error, :cannot_remove_manager}, else: :ok
  end

  defp set_up_like_the_rest_of_the_household(account, server) do
    hidden_from_jellyfin_login_with_every_library =
      Map.merge(account["Policy"] || %{}, %{"IsHidden" => true, "EnableAllFolders" => true})

    english_audio_over_file_defaults =
      Map.merge(account["Configuration"] || %{}, %{
        "AudioLanguagePreference" => @preferred_audio_language,
        "PlayDefaultAudioTrack" => false
      })

    with {:ok, _} <-
           Jellyfin.set_account_policy(
             account["Id"],
             hidden_from_jellyfin_login_with_every_library,
             server
           ),
         {:ok, _} <-
           Jellyfin.set_account_configuration(
             account["Id"],
             english_audio_over_file_defaults,
             server
           ) do
      :ok
    end
  end

  defp forget(account_id) do
    titles_they_had = Library.list_tmdb_ids(account_id)

    Repo.delete_all(from(e in Library.Entry, where: e.jellyfin_user_id == ^account_id))
    Repo.delete_all(from(b in UserBackfill, where: b.jellyfin_user_id == ^account_id))
    Repo.delete_all(from(s in UserSetting, where: s.jellyfin_user_id == ^account_id))

    Repo.delete_all(
      from(s in Aviary.RecentSearches.Entry, where: s.jellyfin_user_id == ^account_id)
    )

    Repo.delete_all(from(p in Progress, where: p.user_id == ^account_id))
    Repo.delete_all(from(d in Dismissal, where: d.user_id == ^account_id))

    Repo.delete_all(
      from(r in Recommendation,
        where: r.from_user_id == ^account_id or r.to_user_id == ^account_id
      )
    )

    titles_they_had
    |> Enum.filter(&(Library.subscribers(&1) == []))
    |> Enum.each(&schedule_deletion_of_title_nobody_has/1)

    :ok
  end

  defp schedule_deletion_of_title_nobody_has(tmdb_id) do
    case {Sonarr.find_series_by_tmdb(tmdb_id), Radarr.find_movie_by_tmdb(tmdb_id)} do
      {{:ok, _}, :not_found} -> Deletions.schedule(tmdb_id, "show")
      {:not_found, {:ok, _}} -> Deletions.schedule(tmdb_id, "movie")
      _ -> :ambiguous_or_unknown
    end
  end
end
