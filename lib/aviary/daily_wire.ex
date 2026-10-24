defmodule Aviary.DailyWire do
  alias Aviary.DailyWire.Credentials

  @api "https://middleware-prod.dailywire.com"
  @shows [
    %{slug: "the-ben-shapiro-show", title: "The Ben Shapiro Show"},
    %{slug: "sunday-special", title: "The Sunday Special"}
  ]
  @catalog_ttl_ms :timer.minutes(5)
  @request_timeout_ms 15_000
  @cursor_max_age_seconds 86_400

  def shows, do: @shows
  def allowed?(user), do: Credentials.allowed?(user)

  def episodes(user, show, cursor \\ nil) do
    with :ok <- authorize(user),
         true <- Enum.any?(@shows, &(&1.slug == show)),
         {:ok, path} <- page_path(show, cursor) do
      cached_page(path, show)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def playback(user, slug) do
    with :ok <- authorize(user),
         true <- is_binary(slug) and Regex.match?(~r/^[a-z0-9-]+$/, slug),
         {:ok, episode} <- get("/middleware/v4/getEpisode?" <> URI.encode_query(slug: slug)),
         true <- Enum.any?(@shows, &(&1.slug == get_in(episode, ["show", "slug"]))),
         true <- episode["playbackPolicy"] in ["SIGNED", "PUBLIC"],
         url when is_binary(url) <- video_url(episode),
         %URI{scheme: "https", host: "stream.mux.com", path: path} <- URI.parse(url),
         true <- String.ends_with?(path, ".m3u8") do
      {:ok, %{streamUrl: url, contentType: "hls", title: episode["title"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :playback_unavailable}
    end
  end

  defp authorize(user), do: if(allowed?(user), do: :ok, else: {:error, :forbidden})

  defp page_path(show, nil) do
    with {:ok, user} <- get("/middleware/v3/getUserInfo?nocache=1"),
         plan when is_binary(plan) <- user["accessLevel"],
         {:ok, page} <-
           get(
             "/middleware/v4/getShowPage?" <> URI.encode_query(slug: show, membershipPlan: plan)
           ),
         seasons when is_list(seasons) and seasons != [] <- get_in(page, ["show", "seasons"]),
         %{"id" => season} <- Enum.max_by(seasons, & &1["name"]) do
      query =
        URI.encode_query(
          slug: show,
          membershipPlan: plan,
          showSeasonId: season,
          podcastSeasonId: "",
          pageNumber: 1,
          pageSize: 20,
          showOffset: 0,
          podcastOffset: 0,
          lastPodcastEpisodeId: "",
          lastShowEpisodeId: "",
          nextDate: "",
          orderBy: "published_at_desc"
        )

      {:ok, "/middleware/v4/getPaginatedEpisodes?" <> query}
    else
      {:error, _} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp page_path(show, cursor) when is_binary(cursor) do
    case Phoenix.Token.verify(AviaryWeb.Endpoint, "daily-wire-page", cursor,
           max_age: @cursor_max_age_seconds
         ) do
      {:ok, %{show: ^show, path: "/middleware/v4/getPaginatedEpisodes?" <> _ = path}} ->
        {:ok, path}

      _ ->
        {:error, :invalid_page}
    end
  end

  defp page_path(_, _), do: {:error, :invalid_page}

  defp cached_page(path, show) do
    key = {:daily_wire, :episodes, path}

    case Aviary.Cache.get(key) do
      {:ok, page} ->
        {:ok, page}

      :miss ->
        with {:ok, body} <- get(path) do
          page = serialize_page(body, show)
          Aviary.Cache.put(key, page, @catalog_ttl_ms)
          {:ok, page}
        end
    end
  end

  defp serialize_page(body, show) do
    component =
      case body do
        %{"componentItems" => items} ->
          %{"items" => items, "nextPageUrl" => body["nextPageUrl"]}

        %{"tabs" => tabs} ->
          tabs
          |> Enum.flat_map(&Map.get(&1, "components", []))
          |> Enum.find(%{}, &(&1["renderType"] == "verticalShowEpisodesCarousel"))

        _ ->
          %{}
      end

    episodes =
      component
      |> Map.get("items", [])
      |> Enum.flat_map(fn
        %{"showEpisode" => %{"status" => "PUBLISHED"} = episode} ->
          if daily_clip?(show, episode), do: [], else: [serialize_episode(episode)]

        _ ->
          []
      end)

    episodes = Enum.sort_by(episodes, & &1.publishedAt, :desc)

    cursor =
      case component["nextPageUrl"] do
        "/middleware/v4/getPaginatedEpisodes?" <> _ = path ->
          Phoenix.Token.sign(AviaryWeb.Endpoint, "daily-wire-page", %{show: show, path: path})

        _ ->
          nil
      end

    %{episodes: episodes, nextPage: cursor}
  end

  defp serialize_episode(episode) do
    %{
      id: episode["slug"],
      title: episode["title"],
      description: episode["description"],
      image: get_in(episode, ["images", "thumbnail", "land"]),
      publishedAt: episode["publishedAt"],
      duration: episode["duration"],
      dateLabel: date_label(episode["publishedAt"]),
      durationLabel: duration_label(episode["duration"]),
      memberOnly: episode["isPaidVideo"] == true and episode["hasFreeAndPaidVideo"] != true
    }
  end

  defp daily_clip?("the-ben-shapiro-show", %{"slug" => slug}),
    do: String.ends_with?(slug, "-memberblock")

  defp daily_clip?(_, _), do: false

  defp date_label(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, date, _} -> Calendar.strftime(date, "%a %b %-d, %Y")
      _ -> nil
    end
  end

  defp date_label(_), do: nil

  @seconds_per_minute 60
  @minimum_duration_minutes 1

  defp duration_label(seconds) when is_number(seconds) and seconds > 0,
    do: "#{max(@minimum_duration_minutes, round(seconds / @seconds_per_minute))} min"

  defp duration_label(_), do: nil

  defp video_url(%{"secureVideoURL" => url}) when is_binary(url) and url != "", do: url
  defp video_url(episode), do: episode["videoURL"]

  defp get(path) do
    with {:ok, token} <- Credentials.access_token() do
      options = [
        headers: [
          {"authorization", "Bearer " <> token},
          {"user-agent", "curl/8.10.1"},
          {"origin", "https://www.dailywire.com"},
          {"referer", "https://www.dailywire.com/"}
        ],
        receive_timeout: @request_timeout_ms,
        retry: false,
        redirect: false
      ]

      case Req.get(
             @api <> path,
             Keyword.merge(options, Application.get_env(:aviary, :daily_wire_req_options, []))
           ) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %Req.Response{status: 401}} -> {:error, :reconnect}
        _ -> {:error, :unavailable}
      end
    end
  end
end
