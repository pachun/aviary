defmodule Aviary.Nhl.Page do
  @moduledoc """
  Pure parsing of the three slapstreams.com pages the NHL shelf is built
  from: the schedule table on the homepage, the feed buttons on a team's
  watch page, and the lookup parameters baked into a feed's player frame.

  The markup is a WordPress theme, not an API, so every parser is a
  narrow regex over the fragments we rely on and returns nothing rather
  than raising when the fragment is missing. A layout change blanks the
  shelf; it never takes the home page down.
  """

  @game_row ~r{<tr class="singele_match_date[^"]*">(.*?)</tr>}s
  @time ~r{class="matchtime"[^>]*>\s*([^<\s]+)}
  @team_links ~r{<a class="team" href="https://slapstreams\.com/([a-z0-9-]+)-live/"><img src="([^"]*)"}
  @game_date ~r{<span class="mtdate">([^<]+)</span>}
  @feed_button ~r{<a[^>]+href="https://slapstreams\.com/stream/([a-z0-9_-]+)\.html"[^>]*>(.*?)</a>}s
  @tag ~r{<[^>]+>}
  @lookup_values ~r{var _d=\[(\d+),'(\d+)','([0-9a-f]+)'\]}

  @month_numbers %{
    "January" => 1,
    "February" => 2,
    "March" => 3,
    "April" => 4,
    "May" => 5,
    "June" => 6,
    "July" => 7,
    "August" => 8,
    "September" => 9,
    "October" => 10,
    "November" => 11,
    "December" => 12
  }

  @team_names_that_need_punctuation %{"st-louis-blues" => "St. Louis Blues"}
  @two_word_cities ~w(new-york st-louis tampa-bay los-angeles san-jose new-jersey)

  @doc """
  Every game row on the schedule page, in page order. Rows without two
  team links (the date header row) are skipped. `date` is nil when the
  row's date text doesn't parse. Each team is
  `%{id, name, nickname, logo}`, the logo being the site's SVG URL.
  """
  def games(schedule_html) do
    @game_row
    |> Regex.scan(schedule_html, capture: :all_but_first)
    |> Enum.flat_map(fn [row] -> game(row) end)
  end

  defp game(row) do
    with [[away_slug, away_logo], [home_slug, home_logo]] <-
           Regex.scan(@team_links, row, capture: :all_but_first) do
      [
        %{
          id: home_slug,
          time: first_capture(@time, row),
          date: @game_date |> first_capture(row) |> parse_date(),
          away_team: team(away_slug, away_logo),
          home_team: team(home_slug, home_logo)
        }
      ]
    else
      _ -> []
    end
  end

  defp team(slug, logo) do
    %{id: slug, name: team_name(slug), nickname: nickname(slug), logo: logo}
  end

  defp nickname(slug) do
    city = Enum.find(@two_word_cities, &String.starts_with?(slug, &1 <> "-"))
    city_word_count = if city, do: 2, else: 1

    slug
    |> String.split("-")
    |> Enum.drop(city_word_count)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc """
  The feed buttons on a team's watch page: `[%{id: "wings", label: "HOME"}]`.
  The id is the player frame's basename under `/stream/`.
  """
  def feeds(team_page_html) do
    @feed_button
    |> Regex.scan(team_page_html, capture: :all_but_first)
    |> Enum.map(fn [id, label_html] ->
      %{id: id, label: label_html |> String.replace(@tag, "") |> clean_label()}
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  The query parameters the player frame sends to its stream lookup:
  `{:ok, [id: "178", ts: "1790976342", pt: "d704dccd6b0eef7c"]}`.
  """
  def lookup_params(frame_html) do
    case Regex.run(@lookup_values, frame_html, capture: :all_but_first) do
      [id, timestamp, proof] -> {:ok, [id: id, ts: timestamp, pt: proof]}
      _ -> :error
    end
  end

  defp first_capture(regex, text) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] -> String.trim(value)
      _ -> nil
    end
  end

  defp clean_label(label), do: label |> String.replace("&nbsp;", " ") |> String.trim()

  defp parse_date(nil), do: nil

  defp parse_date(text) do
    with [month_name, day, year] <- String.split(text, ~r{[ ,]+}, trim: true),
         {:ok, month} <- Map.fetch(@month_numbers, month_name),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(year, month, day) do
      date
    else
      _ -> nil
    end
  end

  defp team_name(slug) do
    Map.get_lazy(@team_names_that_need_punctuation, slug, fn ->
      slug |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
    end)
  end
end
