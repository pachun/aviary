defmodule Aviary.Series do
  @moduledoc """
  The server's series section: shows whose episodes are listed newest
  first and played with their place remembered. They come from the
  server's own sections file when it defines any (`Aviary.Sections`),
  and from a connected Daily Wire membership otherwise.
  """

  alias Aviary.{DailyWire, Sections}
  alias Aviary.DailyWire.Progress

  @membership_label "Daily Wire"
  @configured_label "Shows"
  @hls_extension ".m3u8"

  @doc "What the section is called in a client's navigation."
  def label do
    case Sections.series() do
      %{"label" => label} when is_binary(label) and label != "" -> label
      %{} -> @configured_label
      nil -> @membership_label
    end
  end

  @doc "Whether this user has a series section at all."
  def allowed?(user) do
    case Sections.series() do
      %{} -> configured_shows() != []
      nil -> DailyWire.allowed?(user)
    end
  end

  @doc "The shows, each `%{slug, title}`."
  def shows do
    case Sections.series() do
      %{} -> Enum.map(configured_shows(), &%{slug: &1["slug"], title: &1["title"]})
      nil -> DailyWire.shows()
    end
  end

  @doc "One page of a show's episodes with the user's progress on each."
  def episodes(user, show, cursor \\ nil) do
    case Sections.series() do
      %{} ->
        case Enum.find(configured_shows(), &(&1["slug"] == show)) do
          %{} = found ->
            episodes = found |> Map.get("episodes", []) |> Enum.map(&configured_episode/1)

            {:ok,
             %{
               episodes:
                 episodes
                 |> Enum.sort_by(& &1.publishedAt, :desc)
                 |> then(&Progress.for_episodes(user.id, &1)),
               nextPage: nil
             }}

          nil ->
            {:error, :not_found}
        end

      nil ->
        DailyWire.episodes(user, show, cursor)
    end
  end

  @doc "Where an episode plays from, and where the user left off."
  def playback(user, episode_id) do
    case Sections.series() do
      %{} ->
        case configured_episode_listing(episode_id) do
          %{"url" => url} = listed when is_binary(url) ->
            {:ok,
             %{
               streamUrl: url,
               contentType:
                 if(String.contains?(url, @hls_extension), do: "hls", else: "progressive"),
               title: listed["title"],
               slug: episode_id,
               progress: Progress.start(user.id, episode_id)
             }}

          _ ->
            {:error, :playback_unavailable}
        end

      nil ->
        DailyWire.playback(user, episode_id)
    end
  end

  @doc "Remembers how far into an episode the user is."
  def save_progress(user, episode_id, params) do
    case Sections.series() do
      %{} -> Progress.save(user.id, episode_id, params)
      nil -> DailyWire.save_progress(user, episode_id, params)
    end
  end

  defp configured_shows do
    for %{"slug" => slug, "title" => title} = show <-
          Map.get(Sections.series() || %{}, "shows", []),
        is_binary(slug) and is_binary(title),
        do: show
  end

  defp configured_episode_listing(episode_id) do
    configured_shows()
    |> Enum.flat_map(&Map.get(&1, "episodes", []))
    |> Enum.find(&(&1["id"] == episode_id))
  end

  defp configured_episode(listed) do
    %{
      id: listed["id"],
      title: listed["title"],
      description: listed["description"],
      image: listed["image"],
      publishedAt: listed["publishedAt"],
      duration: listed["duration"],
      dateLabel: DailyWire.date_label(listed["publishedAt"]),
      durationLabel: DailyWire.duration_label(listed["duration"]),
      memberOnly: false
    }
  end
end
