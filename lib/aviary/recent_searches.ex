defmodule Aviary.RecentSearches do
  @moduledoc """
  Per-user recent-search history, surfaced as the empty state on
  /search.

  Only committed searches get recorded — `record/2` is called from
  each detail LiveView's mount when it sees `from=search` + a `q`
  param, which means the user actually clicked through to a result.
  Intermediate debounce fires from the search input ("you've got
  mai" → "you've got mail") never make it here because they never
  produced a navigation.

  The table is capped per-user (`@cap` most recent entries); each
  record/2 call trims oldest entries beyond the cap, so the empty-
  state UI never has to think about pagination and the table stays
  small.
  """

  import Ecto.Query
  alias Aviary.RecentSearches.Entry
  alias Aviary.Repo

  # Empty-state cap. Big enough to feel useful at a glance, small
  # enough to not crowd the page. 7 feels right — anyone who's
  # searched more than 7 distinct things recently is going to
  # re-search anyway.
  @cap 7

  @doc """
  Records a search commitment. Idempotent on repeated calls with the
  same `(user, query)` — the row's `searched_at` gets bumped to now
  instead of inserting a duplicate. Trims the user's history to the
  cap on every call so the table doesn't grow without bound.

  Whitespace-only queries are dropped (defense against a stray
  `?q= ` URL); the empty string is also a no-op.
  """
  def record(user_id, query) when is_binary(user_id) and is_binary(query) do
    q = String.trim(query)

    if q == "" do
      :ok
    else
      now = DateTime.utc_now()

      %Entry{}
      |> Entry.changeset(%{
        jellyfin_user_id: user_id,
        query: q,
        searched_at: now
      })
      |> Repo.insert(
        on_conflict: [set: [searched_at: now]],
        conflict_target: [:jellyfin_user_id, :query]
      )

      trim_to_cap(user_id)

      :ok
    end
  end

  @doc """
  Convenience for detail LiveView mounts. If the user navigated here
  from /search (params has `from=search` + a non-blank `q`), record
  that as a committed search. No-op otherwise — keeps the call site
  to one line at every detail-page mount that wants this.
  """
  def record_if_from_search(user_id, %{"from" => "search", "q" => q})
      when is_binary(user_id) and is_binary(q) do
    record(user_id, q)
  end

  def record_if_from_search(_, _), do: :ok

  @doc """
  Returns this user's recent searches, newest first, capped to the
  configured limit. Returns `[]` for users who haven't clicked
  through to a result yet.
  """
  def for_user(user_id) when is_binary(user_id) do
    from(e in Entry,
      where: e.jellyfin_user_id == ^user_id,
      order_by: [desc: e.searched_at],
      limit: ^@cap,
      select: e.query
    )
    |> Repo.all()
  end

  # Keep only the @cap most recent entries for this user. Called
  # after every record/2 so the table is self-bounding without a
  # separate cron / periodic cleanup. The keep_ids subquery is
  # always non-empty (we just inserted), so the delete can't
  # accidentally wipe everything.
  defp trim_to_cap(user_id) do
    keep_ids =
      from(e in Entry,
        where: e.jellyfin_user_id == ^user_id,
        order_by: [desc: e.searched_at],
        limit: ^@cap,
        select: e.id
      )
      |> Repo.all()

    from(e in Entry,
      where: e.jellyfin_user_id == ^user_id and e.id not in ^keep_ids
    )
    |> Repo.delete_all()
  end
end
