defmodule Aviary.Recommendations do
  @moduledoc """
  Family Recommendations: household members can send each other shows
  and movies they think the other would like. The recipient sees those
  items in a Family Recommended row on Home, and the detail page of
  any recommended item shows a small "X thinks you'll like this" note
  with the sender's avatar.

  Two-table model:
    - `recommendations` — one row per (sender, recipient, item).
      Idempotent: re-sending the same recommendation just bumps
      `updated_at` rather than duplicating.
    - `dismissed_recommendations` — one row per (recipient, item)
      when the recipient clicks X. Future recommendations of the same
      item from anyone are silently absorbed (stored but filtered
      from view). This is the "no, don't bother me again" answer.

  All visibility queries are scoped through dismissals — if the
  recipient has a dismissal row for `(tmdb_id, kind)`, no
  recommendation of that item shows for them, ever.
  """

  import Ecto.Query

  alias Aviary.Repo
  alias Aviary.Recommendations.{Dismissal, Recommendation}

  @doc """
  Insert (or update timestamps on) a recommendation. Returns
  `{:ok, %Recommendation{}}` on success.
  """
  def recommend(from_user_id, to_user_id, tmdb_id, kind)
      when kind in ["show", "movie"] do
    %Recommendation{}
    |> Recommendation.changeset(%{
      from_user_id: to_string(from_user_id),
      to_user_id: to_string(to_user_id),
      tmdb_id: to_string(tmdb_id),
      kind: kind
    })
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:from_user_id, :to_user_id, :tmdb_id, :kind]
    )
  end

  @doc """
  Returns a list of items recommended to `user_id`, deduplicated by
  (tmdb_id, kind). Each entry includes the list of sender user_ids
  (oldest first) so the marquee card can stack avatars and the
  detail page can render "Chris and Sarah think you'll like this."

  Filters out dismissed items entirely.

  Shape:
    [%{tmdb_id: "123", kind: "show", from_user_ids: ["uid1", "uid2"]}, ...]
  """
  def list_active_for_user(user_id) do
    uid = to_string(user_id)

    dismissals =
      from(d in Dismissal,
        where: d.user_id == ^uid,
        select: {d.tmdb_id, d.kind}
      )
      |> Repo.all()
      |> MapSet.new()

    from(r in Recommendation,
      where: r.to_user_id == ^uid,
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(dismissals, {&1.tmdb_id, &1.kind}))
    |> Enum.group_by(&{&1.tmdb_id, &1.kind})
    |> Enum.map(fn {{tmdb_id, kind}, recs} ->
      %{
        tmdb_id: tmdb_id,
        kind: kind,
        from_user_ids: Enum.map(recs, & &1.from_user_id)
      }
    end)
  end

  @doc """
  Returns the list of sender user_ids who've recommended the given
  item to the recipient AND whose recommendation isn't dismissed.
  Used by the detail page badge ("X thinks you'll like this").

  Returns `[]` when no active recommendations, when the recipient
  has dismissed the item, or when the inputs are nil/empty.
  """
  def recommenders_for(_user_id, nil, _kind), do: []
  def recommenders_for(_user_id, "", _kind), do: []

  def recommenders_for(user_id, tmdb_id, kind) when kind in ["show", "movie"] do
    uid = to_string(user_id)
    tid = to_string(tmdb_id)

    case dismissed?(uid, tid, kind) do
      true ->
        []

      false ->
        from(r in Recommendation,
          where: r.to_user_id == ^uid and r.tmdb_id == ^tid and r.kind == ^kind,
          order_by: [asc: r.inserted_at],
          select: r.from_user_id
        )
        |> Repo.all()
    end
  end

  def recommenders_for(_, _, _), do: []

  @doc """
  Returns the recipient user_ids the sender has already recommended
  this item to (i.e., active rows). Used by the Recommend popover to
  pre-check the recipient checkboxes.
  """
  def recipients_for(from_user_id, tmdb_id, kind) when kind in ["show", "movie"] do
    fid = to_string(from_user_id)
    tid = to_string(tmdb_id)

    from(r in Recommendation,
      where: r.from_user_id == ^fid and r.tmdb_id == ^tid and r.kind == ^kind,
      select: r.to_user_id
    )
    |> Repo.all()
  end

  def recipients_for(_, _, _), do: []

  @doc """
  Insert the recipient-side dismissal for this item. Idempotent —
  re-dismissing the same item does nothing.
  """
  def dismiss(user_id, tmdb_id, kind) when kind in ["show", "movie"] do
    %Dismissal{}
    |> Dismissal.changeset(%{
      user_id: to_string(user_id),
      tmdb_id: to_string(tmdb_id),
      kind: kind,
      dismissed_at: DateTime.utc_now()
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :tmdb_id, :kind]
    )
  end

  defp dismissed?(user_id, tmdb_id, kind) do
    Repo.exists?(
      from(d in Dismissal,
        where: d.user_id == ^user_id and d.tmdb_id == ^tmdb_id and d.kind == ^kind
      )
    )
  end

  @doc """
  Returns marquee-ready items for the recipient's Family Recommended
  row. For each active recommendation, resolves the show/movie via
  Catalog (so we get title + poster), attaches a `recommenders` list
  of `%{id, username, primary_image_tag}` maps for the avatar stack.

  Items where Catalog can't resolve the metadata (deleted TMDB id,
  network blip) are silently dropped — better an empty row than a
  card with no thumbnail. Sequential per-item Catalog calls; for
  typical household sizes (< 20 active recs) the wall-clock is fine.
  Optimize with parallel fetches if it ever matters.
  """
  def list_for_marquee(user, all_users) do
    # Index by Jellyfin user id (string key on the raw Jellyfin map).
    user_lookup = Map.new(all_users, &{&1["Id"], &1})

    user
    |> Map.fetch!(:id)
    |> list_active_for_user()
    # Recommending something the recipient already has in their
    # library is noise — they don't need a sender's avatar in their
    # face for a show they're actively watching. Filtered out at
    # display time only (the DB row stays, so it can come back if
    # they ever remove from library and re-discover via the rec).
    |> Enum.reject(&Aviary.Library.member?(user.id, &1.tmdb_id))
    |> Enum.map(fn rec ->
      metadata = resolve_metadata(rec, user)

      if metadata do
        Map.merge(metadata, %{
          recommenders: lookup_recommenders(rec.from_user_ids, user_lookup),
          rec_tmdb_id: rec.tmdb_id,
          rec_kind: rec.kind
        })
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Same as list_active_for_user/1 but also drops anything the user
  already has in their library. Used by Aviary.Nav.visibility — Home
  shouldn't appear "for the rec row" if every active rec is already
  in the library and would be filtered from view anyway.
  """
  def list_active_for_user_excluding_library(user_id) do
    user_id
    |> list_active_for_user()
    |> Enum.reject(&Aviary.Library.member?(user_id, &1.tmdb_id))
  end

  defp resolve_metadata(%{tmdb_id: tmdb_id, kind: "show"}, user) do
    case Aviary.Catalog.get_show(tmdb_id, user) do
      {:ok, show} ->
        %{
          detail_id: tmdb_id,
          kind: :show,
          thumbnail_url: show.poster_url,
          title: show.title,
          subtitle: nil
        }

      _ ->
        nil
    end
  end

  defp resolve_metadata(%{tmdb_id: tmdb_id, kind: "movie"}, user) do
    case Aviary.Catalog.get_movie(tmdb_id, user) do
      {:ok, movie} ->
        %{
          detail_id: tmdb_id,
          kind: :movie,
          thumbnail_url: movie.poster_url,
          title: movie.title,
          subtitle: nil
        }

      _ ->
        nil
    end
  end

  defp lookup_recommenders(from_user_ids, user_lookup) do
    from_user_ids
    |> Enum.uniq()
    |> Enum.map(fn uid -> Map.get(user_lookup, uid) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn u ->
      %{
        id: u["Id"],
        username: u["Name"],
        primary_image_tag: u["PrimaryImageTag"]
      }
    end)
  end
end
