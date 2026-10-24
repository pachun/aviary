defmodule Aviary.DailyWire.Progress do
  use Ecto.Schema
  import Ecto.Query
  alias Aviary.Repo

  @primary_key false
  @completion_fraction 0.95
  @maximum_duration_seconds 86_400
  @seconds_per_minute 60

  schema "daily_wire_progress" do
    field(:user_id, :string, primary_key: true)
    field(:slug, :string, primary_key: true)
    field(:position, :float, default: 0.0)
    field(:duration, :float, default: 0.0)
    field(:watched, :boolean, default: false)
    field(:session_id, :string)
    field(:sequence, :integer, default: -1)
  end

  def for_episodes(user_id, episodes) do
    slugs = Enum.map(episodes, & &1.id)
    saved = Repo.all(from(p in __MODULE__, where: p.user_id == ^user_id and p.slug in ^slugs))
    by_slug = Map.new(saved, &{&1.slug, describe(&1)})
    Enum.map(episodes, &Map.put(&1, :progress, Map.get(by_slug, &1.id, describe(nil))))
  end

  def start(user_id, slug) do
    session_id = Ecto.UUID.generate()

    saved =
      Repo.insert!(%__MODULE__{user_id: user_id, slug: slug, session_id: session_id},
        on_conflict: [set: [session_id: session_id, sequence: -1]],
        conflict_target: [:user_id, :slug],
        returning: true
      )

    Map.put(describe(saved), :sessionId, session_id)
  end

  def save(
        user_id,
        slug,
        %{
          "sessionId" => session_id,
          "sequence" => sequence,
          "position" => position,
          "duration" => duration
        } = params
      )
      when is_binary(session_id) and is_integer(sequence) and sequence >= 0 and
             is_number(position) and position >= 0 and is_number(duration) and
             duration > 0 and duration <= @maximum_duration_seconds and position <= duration do
    watched = params["ended"] == true or position / duration >= @completion_fraction

    query =
      from(p in __MODULE__,
        where:
          p.user_id == ^user_id and p.slug == ^slug and
            p.session_id == ^session_id and p.sequence < ^sequence
      )

    case Repo.update_all(query,
           set: [
             position: position * 1.0,
             duration: duration * 1.0,
             watched: watched,
             sequence: sequence
           ]
         ) do
      {1, _} ->
        {:ok, describe(Repo.get_by!(__MODULE__, user_id: user_id, slug: slug))}

      {0, _} ->
        case Repo.get_by(__MODULE__, user_id: user_id, slug: slug, session_id: session_id) do
          nil -> {:error, :stale_progress}
          saved -> {:ok, describe(saved)}
        end
    end
  end

  def save(_, _, _), do: {:error, :invalid_progress}

  defp describe(nil), do: %{resumeSeconds: 0, watched: false, label: "Play"}

  defp describe(saved) do
    label =
      cond do
        saved.watched ->
          "Watched · Play again"

        saved.position > 0 ->
          "Resume · #{max(1, ceil((saved.duration - saved.position) / @seconds_per_minute))} min left"

        true ->
          "Play"
      end

    %{
      resumeSeconds: if(saved.watched, do: 0, else: saved.position),
      watched: saved.watched,
      label: label
    }
  end
end
