defmodule AviaryWeb.API.HomeController do
  @moduledoc """
  The home feed for native clients. `continue_watching` mirrors the
  marquee on the web home page — the same `Aviary.Home` computation —
  flattened into the shape the tvOS client renders, with image URLs
  pointing back at the token-authed image proxy (`/api/v1/image/:id`).
  """
  use AviaryWeb, :controller

  def continue_watching(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Home.continue_watching()
      |> Enum.map(&serialize/1)

    json(conn, %{items: items})
  end

  # "What of mine is dropping soon" — the same per-user feed as the web
  # home page's Upcoming list (`Aviary.Upcoming`), flattened for the tvOS
  # client. Every entry is a show; `seriesId` opens the same detail screen
  # the continue-watching cards do. `daysAway` (computed against the
  # user's local today) lets the client group by day without timezone
  # guesswork.
  def upcoming(conn, _params) do
    items =
      conn.assigns.current_user
      |> Aviary.Upcoming.releases()
      |> Enum.map(&serialize_upcoming/1)

    json(conn, %{items: items})
  end

  defp serialize_upcoming(release) do
    %{
      seriesId: release.series_id,
      title: release.series_name,
      season: release.season,
      episode: release.episode,
      airDate: Date.to_iso8601(release.air_date),
      daysAway: release.days_away,
      newSeason: release.kind == :new_season,
      image: image_path(release.poster_url)
    }
  end

  # "What household members sent you" — the same feed as the web home
  # page's Family Recommended row (`Aviary.Recommendations.list_for_marquee`,
  # which already drops anything the recipient has in their library).
  # `id`/`kind` open the show/movie detail; each recommender carries a
  # name and (when they've set a Jellyfin avatar) an image URL to stack
  # in the corner of the artwork.
  def recommended(conn, _params) do
    user = conn.assigns.current_user

    items =
      user
      |> Aviary.Recommendations.list_for_marquee(Aviary.Jellyfin.list_users(user))
      |> Enum.map(&serialize_recommended/1)

    json(conn, %{items: items})
  end

  defp serialize_recommended(rec) do
    %{
      id: rec.detail_id,
      kind: to_string(rec.kind),
      title: rec.title,
      image: image_path(rec.thumbnail_url),
      recommenders: Enum.map(rec.recommenders, &serialize_recommender/1)
    }
  end

  defp serialize_recommender(%{id: id, username: name, primary_image_tag: tag}) do
    %{name: name, avatar: tag && "/api/v1/user-image/#{id}?tag=#{tag}"}
  end

  defp image_path(nil), do: nil
  defp image_path(path), do: "/api/v1" <> path

  # Drop a title out of Continue Watching by resetting its Jellyfin
  # watch state — same action as the web home page's hover-X. `id` is
  # the series id (shows) or item id (movies), which is the unprefixed
  # `dedupe_key` the client already holds.
  def dismiss(conn, %{"kind" => "show", "id" => id}) do
    Aviary.Jellyfin.reset_series_progress(id, conn.assigns.current_user)
    json(conn, %{ok: true})
  end

  def dismiss(conn, %{"kind" => "movie", "id" => id}) do
    Aviary.Jellyfin.reset_item_progress(id, conn.assigns.current_user)
    json(conn, %{ok: true})
  end

  def dismiss(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "bad_request"})
  end

  defp serialize(item) do
    %{
      id: item.dedupe_key,
      kind: to_string(item.kind),
      title: item.title,
      subtitle: item.subtitle,
      image: image_url(item)
    }
  end

  # Shows use the specific episode still (play_item_id's Primary image),
  # falling back to the series backdrop when the still is missing. Movies
  # have no per-episode still, so they stay on the item backdrop.
  defp image_url(%{kind: :show, play_item_id: episode_id, thumbnail_item_id: series_id}),
    do: "/api/v1/image/#{episode_id}?fallback=#{series_id}"

  defp image_url(%{thumbnail_item_id: id}),
    do: "/api/v1/image/#{id}?kind=backdrop"
end
