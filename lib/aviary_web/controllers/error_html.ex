defmodule AviaryWeb.ErrorHTML do
  @moduledoc """
  Renders error pages (404 / 500) when something goes wrong on an
  HTML request. Templates live in `error_html/`. The pages are
  standalone — no Layouts.app wrapper, no LiveView — so they render
  safely even when the underlying error came from a layout dependency.

  Each render picks a random caption/clip pairing from `pairings/0`
  to give the user something to look at while figuring out what went
  wrong. The Office Space "case of the Mondays" pairing is locked to
  actual Mondays; on other days the rotation picks from the rest.
  """
  use AviaryWeb, :html

  embed_templates "error_html/*"

  # Fallback for any status code we haven't templated (403, 502, etc.).
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc """
  Returns one pairing — caption + YouTube embed URL — to show on an
  error page. Monday → always the Office Space "Mondays" clip; other
  days → randomly selected from the remaining set.
  """
  def pairing do
    if monday?() do
      Enum.find(pairings(), &(&1.key == :mondays))
    else
      pairings()
      |> Enum.reject(&(&1.key == :mondays))
      |> Enum.random()
    end
  end

  defp monday? do
    Date.day_of_week(Aviary.LocalTime.today()) == 1
  end

  defp pairings do
    [
      %{
        key: :star_wars,
        caption: "We have a reactor leak. Give us a few minutes to lock it down.",
        embed: "https://www.youtube.com/embed/3bjEpLoL0ls?start=12"
      },
      %{
        key: :apollo_13_houston,
        caption: "Houston, we have a problem.",
        embed: "https://www.youtube.com/embed/Yxzu5evyBM4"
      },
      %{
        key: :jaws,
        caption: "We're gonna need a bigger boat.",
        embed: "https://www.youtube.com/embed/QT9BeGNnCqw?start=14"
      },
      %{
        key: :top_gun,
        caption: "The defense department regrets to inform you...",
        embed: "https://www.youtube.com/embed/K_Kzf21cFoQ"
      },
      %{
        key: :casablanca,
        caption: "Major Strasser's been shot...",
        embed: "https://www.youtube.com/embed/_ss8kaYq-n8?start=57"
      },
      %{
        key: :office_space_printer,
        caption: "Please be patient. I'll do better.",
        embed: "https://www.youtube.com/embed/N9wsjroVlu8"
      },
      %{
        key: :mondays,
        caption: "I may have a case of the Mondays.",
        embed: "https://www.youtube.com/embed/guv5LUT1AFw"
      },
      %{
        key: :office_space_specs,
        caption: "I take the specifications from the customers...",
        embed: "https://www.youtube.com/embed/m4OvQIGDg4I"
      },
      %{
        key: :apollo_13_workaround,
        caption: "Engineering has proposed a workaround...",
        embed: "https://www.youtube.com/embed/58lJuR1JvDw"
      }
    ]
  end
end
