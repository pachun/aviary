defmodule Aviary.Live do
  @moduledoc """
  The server's live section: events that are on now or later today,
  each with one or more feeds to watch. They come from the server's
  own sections file when it defines any (`Aviary.Sections`), and from
  the NHL schedule otherwise, which also brings standings and team
  pages with it.
  """

  alias Aviary.{Nhl, Sections}

  @schedule_label "NHL"
  @configured_label "Live"

  @doc "What the section is called in a client's navigation."
  def label do
    case Sections.live() do
      %{"label" => label} when is_binary(label) and label != "" -> label
      %{} -> @configured_label
      nil -> @schedule_label
    end
  end

  @doc "Whether standings and team pages come with the live events."
  def sports?, do: Sections.live() == nil

  @doc """
  Whether the section has anything to open. The NHL schedule always
  does, since its standings and team pages are there on a day with no
  games; a server's own section does only while it lists an event.
  """
  def offered?, do: sports?() or events() != []

  @doc """
  The events, each `%{id, title, time, starts_at, images, feeds}` with
  feeds as `%{id, label}`.
  """
  def events do
    case Sections.live() do
      %{} = configured -> configured |> Map.get("events", []) |> Enum.map(&configured_event/1)
      nil -> Enum.map(Nhl.games(), &scheduled_event/1)
    end
  end

  @doc """
  Where a feed plays from: `{:ok, {:direct, url}}` for a feed the
  sections file points at, `{:ok, :through_aviary}` for one aviary
  relays itself, `{:error, :not_live}` before it has started, or
  `{:error, :unavailable}`.
  """
  def feed(event_id, feed_id) do
    case Sections.live() do
      %{} = configured ->
        with %{} = event <- Enum.find(Map.get(configured, "events", []), &(&1["id"] == event_id)),
             %{"url" => url} when is_binary(url) <-
               Enum.find(Map.get(event, "feeds", []), &(&1["id"] == feed_id)) do
          {:ok, {:direct, url}}
        else
          _ -> {:error, :unavailable}
        end

      nil ->
        case Nhl.playlist(event_id, feed_id) do
          {:ok, _playlist} -> {:ok, :through_aviary}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp configured_event(event) do
    %{
      id: event["id"],
      title: event["title"],
      time: event["time"],
      starts_at: starting_time(event["startsAt"]),
      images: event |> Map.get("images", []) |> Enum.filter(&is_binary/1),
      feeds:
        for(
          %{"id" => id} = feed <- Map.get(event, "feeds", []),
          do: %{id: id, label: feed["label"]}
        )
    }
  end

  defp starting_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, starts_at, _offset} -> starts_at
      _ -> nil
    end
  end

  defp starting_time(_timestamp), do: nil

  defp scheduled_event(game) do
    %{
      id: game.id,
      title: "#{game.away_team.nickname} @ #{game.home_team.nickname}",
      time: game.time,
      starts_at: game.starts_at,
      images: [logo(game.away_team), logo(game.home_team)],
      feeds: Enum.map(game.feeds, &%{id: &1.id, label: &1.label})
    }
  end

  defp logo(team), do: "/api/v1/nhl/logos/#{team.id}?background=dark"
end
