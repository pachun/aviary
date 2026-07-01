defmodule AviaryWeb.API.StorageController do
  @moduledoc """
  Storage breakdown for native clients — the same `Aviary.Storage.stats`
  the web Settings page renders: the signed-in user's own usage, and the
  household total with a per-member split for the bar + legend. Byte
  values are humanized here (one formatter, shared with the web), and
  each member carries a `share` (fraction of the bar) plus `tankPercent`
  (its slice of total capacity) so the client just draws.
  """
  use AviaryWeb, :controller

  alias Aviary.Storage

  def show(conn, _params) do
    user = conn.assigns.current_user
    %{per_user: per_user, aggregate: aggregate, tank_bytes: tank_bytes} = Storage.stats(user)

    you =
      Enum.find(per_user, &(&1.user_id == user.id)) ||
        %{
          movie_count: 0,
          show_count: 0,
          episode_count: 0,
          bytes_movies: 0,
          bytes_shows: 0
        }

    used = aggregate.bytes
    scale = tank_bytes || max(used, 1)

    json(conn, %{
      you: %{
        moviesCount: you.movie_count,
        moviesSize: Storage.humanize_bytes(you.bytes_movies),
        showsCount: you.show_count,
        showsSize: Storage.humanize_bytes(you.bytes_shows),
        episodesCount: you.episode_count
      },
      tank: tank_bytes && Storage.humanize_bytes(tank_bytes),
      used: Storage.humanize_bytes(used),
      freePercent: free_percent(used, tank_bytes),
      members:
        Enum.map(per_user, fn member ->
          %{
            userId: member.user_id,
            username: member.username,
            size: Storage.humanize_bytes(member.bytes),
            share: share(member.bytes, scale),
            tankPercent: tank_percent(member.bytes, tank_bytes)
          }
        end)
    })
  end

  defp free_percent(_used, nil), do: nil
  defp free_percent(used, tank) when tank > 0, do: round((tank - used) / tank * 100)
  defp free_percent(_, _), do: nil

  defp share(_bytes, scale) when scale <= 0, do: 0.0
  defp share(bytes, scale), do: bytes / scale

  defp tank_percent(_bytes, nil), do: nil
  defp tank_percent(_bytes, 0), do: nil
  defp tank_percent(bytes, tank), do: round(bytes / tank * 100)
end
