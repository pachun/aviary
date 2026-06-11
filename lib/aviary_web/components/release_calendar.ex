defmodule AviaryWeb.Components.ReleaseCalendar do
  @moduledoc """
  Show-detail-page widget that takes the slot the trailer iframe usually
  occupies. Two modes, picked by the data shape:

    * `:calendar` — show is mid-season with a known upcoming air date.
      Renders a 7×2 grid (Sun-Sat × 2 rows starting from the most
      recent Sunday). Today gets a quiet underline; the target air
      date gets a circled date number. Caption beneath in Fraunces
      italic + a small-caps S/E credit line.

    * `:premiere` — a new season is announced. Calendar grid is
      omitted; the slot becomes a pure typographic announcement
      (label / big date / credit).

  Both modes are color-disciplined: today and target use *shape* —
  underline vs. ring — to differ rather than color, so the oxblood
  accent stays uniquely associated with action affordances (Play,
  kicker). Themes flow through existing tokens (text-ink, text-muted,
  border-rule, etc.) so day/night switching just works.

  Caller supplies the schedule shape `%{air_date, season, episode,
  kind}` where kind is `:continuation` (mid-season weekly drop) or
  `:new_season` (S+1 E1 announcement). The component handles `today`
  defaulting to `Date.utc_today/0` but accepts an override for test/
  preview rendering.
  """
  use Phoenix.Component

  attr :schedule, :map,
    required: true,
    doc: "%{air_date: Date, season: int, episode: int, kind: :continuation | :new_season}"

  attr :today, Date, default: nil

  def widget(assigns) do
    # assign_new wouldn't help here because attr declares :today with
    # default nil — the key IS present, so assign_new is a no-op.
    # Explicit nil-coalesce instead.
    assigns =
      assigns
      |> assign(:today, assigns[:today] || Date.utc_today())
      |> then(fn a -> assign(a, :mode, a.schedule.kind) end)

    ~H"""
    <div class="w-full">
      <%= case @mode do %>
        <% :continuation -> %>
          <.calendar schedule={@schedule} today={@today} />
        <% :new_season -> %>
          <.premiere schedule={@schedule} today={@today} />
      <% end %>
    </div>
    """
  end

  ## Mid-season weekly-drop calendar

  attr :schedule, :map, required: true
  attr :today, Date, required: true

  defp calendar(assigns) do
    days = two_weeks_from_sunday(assigns.today)

    assigns =
      assigns
      |> assign(:row1, Enum.take(days, 7))
      |> assign(:row2, Enum.drop(days, 7))
      |> assign(:caption, caption_phrase(assigns.schedule.air_date, assigns.today))

    ~H"""
    <%!--
      Stripped to pure time-shape: 14 boxes, no day labels, no date
      numbers. Today reads as outlined, target reads as filled — the
      eye lands on the filled box first ("destination"), then locates
      itself via the outlined one ("you are here"). The caption
      beneath carries the actual day name and episode credit, so the
      grid stays purely visual.
    --%>
    <div class="font-sans">
      <div class="grid grid-cols-7 gap-1.5">
        <.day_cell :for={d <- @row1} date={d} today={@today} target={@schedule.air_date} />
      </div>
      <div class="grid grid-cols-7 gap-1.5 mt-1.5">
        <.day_cell :for={d <- @row2} date={d} today={@today} target={@schedule.air_date} />
      </div>

      <div class="mt-6 text-center">
        <p
          class="font-display italic text-ink/85 text-base leading-snug"
          style="font-variation-settings: 'opsz' 14;"
        >
          {@caption}
        </p>
        <p class="mt-1.5 font-sans text-[0.65rem] tracking-[0.18em] uppercase text-muted">
          S{@schedule.season} · E{@schedule.episode}
        </p>
      </div>
    </div>
    """
  end

  attr :date, Date, required: true
  attr :today, Date, required: true
  attr :target, Date, required: true

  defp day_cell(assigns) do
    is_today = Date.compare(assigns.date, assigns.today) == :eq
    is_target = Date.compare(assigns.date, assigns.target) == :eq
    is_past = Date.compare(assigns.date, assigns.today) == :lt

    box_class =
      cond do
        is_target -> "bg-ink/85 border border-ink/85"
        is_today -> "bg-paper border-[1.5px] border-ink"
        is_past -> "bg-transparent border border-rule opacity-40"
        true -> "bg-transparent border border-rule"
      end

    assigns = assign(assigns, :box_class, box_class)

    ~H"""
    <div class={["aspect-square rounded-[2px]", @box_class]}></div>
    """
  end

  ## New-season announcement (calendar omitted)

  defp premiere(assigns) do
    assigns =
      assigns
      |> assign(:date_phrase, premiere_phrase(assigns.schedule.air_date))
      |> assign(:days_away, Date.diff(assigns.schedule.air_date, assigns.today))

    ~H"""
    <%!--
      Pure typography in lieu of the grid. The contrast between this
      shape and the calendar shape itself carries meaning: weekly
      drops get a utility grid, season premieres get a big-type
      anticipation moment.
    --%>
    <div class="flex flex-col items-center justify-center text-center py-6">
      <p class="font-sans text-[0.65rem] tracking-[0.22em] uppercase text-muted mb-3">
        New Season
      </p>
      <p
        class="font-heading text-ink text-2xl md:text-[1.75rem] leading-tight"
        style="font-variation-settings: 'opsz' 30;"
      >
        {@date_phrase}
      </p>
      <p class="mt-2 font-sans text-[0.65rem] tracking-[0.18em] uppercase text-muted">
        S{@schedule.season} · E{@schedule.episode}
      </p>
      <p
        :if={@days_away > 0}
        class="mt-4 font-display italic text-muted text-sm"
        style="font-variation-settings: 'opsz' 14;"
      >
        in {@days_away} {pluralize_days(@days_away)}
      </p>
    </div>
    """
  end

  ## Phrase builders — kept in this module because they're tightly
  ## coupled to the visual structure and not reused elsewhere yet.

  defp caption_phrase(air_date, today) do
    days = Date.diff(air_date, today)

    cond do
      days == 0 -> "Next episode today"
      days == 1 -> "Next episode tomorrow"
      days <= 7 -> "Next episode #{day_name(air_date, today)}"
      days <= 14 -> "Next episode next #{day_name(air_date, today)}"
      true -> "Next episode #{Calendar.strftime(air_date, "%B %-d")}"
    end
  end

  defp premiere_phrase(air_date) do
    Calendar.strftime(air_date, "%A, %B %-d")
  end

  defp day_name(date, today) do
    same_week =
      Date.beginning_of_week(date, :sunday) ==
        Date.beginning_of_week(today, :sunday)

    name = Calendar.strftime(date, "%A")
    if same_week, do: "this #{name}", else: name
  end

  defp pluralize_days(1), do: "day"
  defp pluralize_days(_), do: "days"

  ## Grid construction

  # Returns the 14 consecutive dates beginning at the most recent
  # Sunday on or before `today`. Always 14 elements; the visual grid
  # depends on this contract.
  defp two_weeks_from_sunday(today) do
    start = Date.beginning_of_week(today, :sunday)
    Enum.map(0..13, fn n -> Date.add(start, n) end)
  end
end
