defmodule Aviary.MetadataRepair do
  @moduledoc """
  Jellyfin looks an item up once, when it first scans the file. When
  that lookup fails (TMDb rate-limiting a bulk scan, a network blip) the
  item keeps the filename as its title, with no still and no provider
  ids, and Jellyfin never tries again: the NFO it saved beside the file
  now counts as local metadata and wins over the providers.

  Every episode list and every series aviary reads from Jellyfin passes
  through here, so the moment anyone sees a bare item it goes back to
  Jellyfin for another attempt: a replace-all refresh for an episode,
  an exact-title identification for a series Jellyfin never matched.
  One attempt per item per day keeps an item TMDb genuinely has nothing
  for from being refetched on every page load.
  """
  require Logger

  alias Aviary.Jellyfin

  @attempt_cooldown_ms :timer.hours(24)

  @doc "Episodes of one series just came back from Jellyfin."
  def episodes_listed(series_id, episodes) do
    episodes
    |> Enum.filter(&bare_episode?/1)
    |> Enum.each(fn episode ->
      attempt_once({:episode, episode["Id"]}, fn auth ->
        repair_episode(series_id, episode, auth)
      end)
    end)
  end

  @doc "Series just came back from Jellyfin."
  def series_listed(series) do
    series
    |> Enum.filter(&unidentified_series?/1)
    |> Enum.each(fn one -> attempt_once({:series, one["Id"]}, &identify_series(one, &1)) end)
  end

  def bare_episode?(episode), do: missing_metadata?(episode) or missing_image?(episode)

  def unidentified_series?(%{"Type" => "Series"} = series), do: missing_metadata?(series)
  def unidentified_series?(_), do: false

  # Only an item whose provider ids were asked for and came back empty
  # is bare; an item the caller never asked about is unknown, not broken.
  defp missing_metadata?(%{"ProviderIds" => ids}) when ids in [nil, %{}], do: true
  defp missing_metadata?(_), do: false

  defp missing_image?(%{"ImageTags" => tags}) when is_map(tags),
    do: not Map.has_key?(tags, "Primary")

  defp missing_image?(_), do: false

  def repair_episode(series_id, episode, auth) do
    id = episode["Id"]

    result =
      if missing_metadata?(episode) do
        Logger.info("metadata_repair: refetching metadata for episode #{id}")
        Jellyfin.refetch_metadata(id, auth)
      else
        Logger.info("metadata_repair: refetching the still for episode #{id}")
        Jellyfin.refetch_images(id, auth)
      end

    Aviary.Cache.invalidate_match({:jellyfin_list_episodes, series_id, :_})
    result
  end

  def identify_series(%{"Id" => id, "Name" => name}, auth) do
    exact_title =
      Enum.find(Jellyfin.search_series_identity(id, name, auth), &same_title?(&1["Name"], name))

    case exact_title do
      nil ->
        Logger.info("metadata_repair: no exact title match for series #{id} #{inspect(name)}")
        :no_match

      identity ->
        Logger.info(
          "metadata_repair: identifying series #{id} #{inspect(name)} as #{inspect(identity["ProviderIds"])}"
        )

        Jellyfin.apply_series_identity(id, identity, auth)
        Jellyfin.full_refresh_series(id, auth)
        Aviary.Cache.invalidate_match({:jellyfin_list_shows, :_})
        Aviary.Cache.invalidate_match({:jellyfin_list_episodes, id, :_})
        :identified
    end
  end

  defp same_title?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_title?(_, _), do: false

  defp attempt_once(key, repair) do
    case Jellyfin.server_auth() do
      nil ->
        :ok

      auth ->
        Aviary.Cache.fetch({:metadata_repair, key}, @attempt_cooldown_ms, fn ->
          Task.Supervisor.start_child(Aviary.TaskSupervisor, fn -> repair.(auth) end)
          :attempted
        end)

        :ok
    end
  end
end
