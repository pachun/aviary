defmodule AviaryWeb.Components.NhlTables do
  @moduledoc """
  The NHL page's standings and team views: each division's table, the
  list of teams, and one team's lines, injuries, results and scoring.
  """
  use Phoenix.Component

  @regulation "REG"
  @save_percentage_decimals 3
  @goals_against_decimals 2
  @position_groups [{"Forwards", ["C", "L", "R"]}, {"Defense", ["D"]}, {"Goalies", ["G"]}]

  attr :divisions, :any, required: true

  def standings(assigns) do
    ~H"""
    <p :if={@divisions == :unavailable} class="font-sans text-muted">
      Standings are unavailable.
    </p>
    <div :if={is_list(@divisions)} class="grid gap-x-10 gap-y-12 lg:grid-cols-2">
      <section :for={division <- @divisions}>
        <table class="w-full font-sans text-sm tabular-nums">
          <thead>
            <tr class="border-b border-rule text-muted text-[0.7rem] tracking-[0.14em] uppercase">
              <th class="text-left font-normal py-2 text-oxblood tracking-[0.18em]" colspan="2">
                {division.name}
              </th>
              <th
                :for={heading <- ~w(GP W L OTL PTS DIFF L10 STRK)}
                class="text-right font-normal py-2 pl-3"
              >
                {heading}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={team <- division.teams} class="border-b border-rule">
              <td class="py-2 pr-2 text-muted w-6">{team.rank}</td>
              <td class="py-2">
                <span class="flex items-center gap-3">
                  <img src={team.logo_url} alt="" class="size-7" />
                  <span class="font-display text-ink text-base">{team.nickname}</span>
                </span>
              </td>
              <td class="text-right pl-3 text-muted">{team.games_played}</td>
              <td class="text-right pl-3 text-muted">{team.wins}</td>
              <td class="text-right pl-3 text-muted">{team.losses}</td>
              <td class="text-right pl-3 text-muted">{team.overtime_losses}</td>
              <td class="text-right pl-3 text-ink">{team.points}</td>
              <td class="text-right pl-3 text-muted">{signed(team.goal_difference)}</td>
              <td class="text-right pl-3 text-muted">{team.last_ten}</td>
              <td class="text-right pl-3 text-muted">{team.streak}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  attr :teams, :any, required: true
  attr :team, :any, required: true
  attr :shown_team_id, :string, default: nil

  def teams(assigns) do
    ~H"""
    <p :if={@teams == :unavailable} class="font-sans text-muted">Teams are unavailable.</p>
    <div :if={is_list(@teams)} class="grid gap-10 md:grid-cols-[16rem_1fr]">
      <ul class="flex gap-1 overflow-x-auto md:block md:space-y-1 md:overflow-visible">
        <li :for={listed <- @teams} class="shrink-0">
          <button
            type="button"
            phx-click="show_team"
            phx-value-team={listed.id}
            aria-pressed={@shown_team_id == listed.id}
            class={[
              "flex w-full items-center gap-3 px-2 py-1.5 text-left cursor-pointer hover:text-oxblood focus-visible:outline-2 focus-visible:outline-oxblood",
              @shown_team_id == listed.id && "text-oxblood",
              @shown_team_id != listed.id && "text-ink"
            ]}
          >
            <img src={listed.logo_url} alt="" class="size-7" />
            <span class="font-display text-base whitespace-nowrap">{listed.name}</span>
          </button>
        </li>
      </ul>

      <div>
        <p :if={@team == nil} class="font-sans text-muted">Pick a team to see its page.</p>
        <p :if={@team == :unavailable} class="font-sans text-muted">
          This team's page is unavailable.
        </p>
        <.team_page :if={match?({:shown, _}, @team)} team={elem(@team, 1)} />
      </div>
    </div>
    """
  end

  attr :team, :map, required: true

  defp team_page(assigns) do
    ~H"""
    <div class="space-y-10">
      <header class="flex items-center gap-6">
        <img src={@team.standing.logo_url} alt="" class="size-24" />
        <div>
          <h2 class="font-display text-ink text-3xl leading-tight">{@team.name}</h2>
          <p class="font-sans text-ink text-xl tabular-nums">
            {@team.standing.wins}-{@team.standing.losses}-{@team.standing.overtime_losses}
          </p>
          <p class="font-sans text-muted text-sm">
            {@team.standing.points} points · {ordinal(@team.standing.rank)} in the {@team.standing.division} · Last ten {@team.standing.last_ten}
            <span :if={@team.standing.streak}>· Streak {@team.standing.streak}</span>
          </p>
        </div>
      </header>

      <section :if={@team.next_game || @team.recent_games != []} class="font-sans">
        <p :if={@team.next_game} class="text-ink">
          Next: {against(@team.next_game)}, {game_time(@team.next_game.starts_at)}
        </p>
        <ul class="flex flex-wrap gap-x-8 gap-y-2 mt-3 text-sm tabular-nums">
          <li :for={game <- @team.recent_games}>
            <span class="text-ink">{outcome(game)} {game.score}-{game.opponent_score}</span>
            <span class="text-muted">{against(game)}</span>
          </li>
        </ul>
      </section>

      <%= if @team.lines do %>
        <.units label="Forwards" aside={@team.lines.as_of} units={@team.lines.forwards} />
        <.units label="Defense and goalies" units={@team.lines.defense ++ [@team.lines.goalies]} />
        <.units :if={@team.lines.power_play != []} label="Power play" units={@team.lines.power_play} />
        <.units
          :if={@team.lines.penalty_kill != []}
          label="Penalty kill"
          units={@team.lines.penalty_kill}
        />
      <% else %>
        <.units
          :for={{label, positions} <- position_groups()}
          label={label}
          units={[Enum.filter(@team.roster, &(&1.position in positions))]}
        />
      <% end %>

      <section :if={@team.injuries != []}>
        <.heading label="Out" />
        <ul class="space-y-4">
          <li :for={injury <- @team.injuries} class="flex items-start gap-4">
            <.headshot player={injury.player} />
            <div>
              <p class="font-display text-ink text-lg leading-tight">
                {injury.player.name}
                <span :if={injury.player.number} class="font-sans text-sm text-oxblood">
                  #{injury.player.number}
                </span>
              </p>
              <p class="font-sans text-sm text-muted">
                {injury_facts(injury)}
              </p>
              <p :if={injury.note} class="font-sans text-sm text-muted mt-1 max-w-prose">
                {injury.note}
              </p>
            </div>
          </li>
        </ul>
      </section>

      <section :if={@team.scoring_leaders != []}>
        <.heading label="Scoring leaders" />
        <table class="w-full max-w-xl font-sans text-sm tabular-nums">
          <thead>
            <tr class="text-muted text-[0.7rem] tracking-[0.14em] uppercase border-b border-rule">
              <th></th>
              <th :for={heading <- ~w(GP G A PTS)} class="text-right font-normal py-2 pl-3">
                {heading}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={scorer <- @team.scoring_leaders} class="border-b border-rule">
              <td class="py-2 font-display text-ink text-base">{scorer.player.name}</td>
              <td class="text-right pl-3 text-muted">{scorer.games_played}</td>
              <td class="text-right pl-3 text-muted">{scorer.goals}</td>
              <td class="text-right pl-3 text-muted">{scorer.assists}</td>
              <td class="text-right pl-3 text-ink">{scorer.points}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section :if={@team.goalies != []}>
        <.heading label="In goal" />
        <table class="w-full max-w-xl font-sans text-sm tabular-nums">
          <thead>
            <tr class="text-muted text-[0.7rem] tracking-[0.14em] uppercase border-b border-rule">
              <th></th>
              <th :for={heading <- ~w(GS W-L-OTL SV% GAA)} class="text-right font-normal py-2 pl-3">
                {heading}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={goalie <- @team.goalies} class="border-b border-rule">
              <td class="py-2 font-display text-ink text-base">{goalie.player.name}</td>
              <td class="text-right pl-3 text-muted">{goalie.games_started}</td>
              <td class="text-right pl-3 text-muted">
                {goalie.wins}-{goalie.losses}-{goalie.overtime_losses}
              </td>
              <td class="text-right pl-3 text-ink">
                {decimal(goalie.save_percentage, save_percentage_decimals())}
              </td>
              <td class="text-right pl-3 text-muted">
                {decimal(goalie.goals_against_average, goals_against_decimals())}
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :aside, :string, default: nil

  defp heading(assigns) do
    ~H"""
    <h3 class="flex items-baseline justify-between font-sans text-[0.78rem] tracking-[0.18em] uppercase text-oxblood mb-4">
      {@label}
      <span :if={@aside} class="text-muted normal-case tracking-normal">{@aside}</span>
    </h3>
    """
  end

  attr :label, :string, required: true
  attr :aside, :string, default: nil
  attr :units, :list, required: true

  defp units(assigns) do
    ~H"""
    <section>
      <.heading label={@label} aside={@aside} />
      <div class="space-y-4">
        <ul :for={unit <- @units} class="flex flex-wrap gap-x-6 gap-y-3">
          <li :for={player <- unit} class="flex items-center gap-3 w-48">
            <.headshot player={player} />
            <div>
              <p :if={player.number} class="font-sans text-xs text-oxblood">#{player.number}</p>
              <p class="font-display text-ink text-base leading-tight">{player.name}</p>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :player, :map, required: true

  defp headshot(assigns) do
    ~H"""
    <img
      :if={@player.headshot}
      src={@player.headshot}
      alt=""
      loading="lazy"
      class="size-14 shrink-0 rounded-full bg-rule object-cover"
    />
    <span :if={!@player.headshot} class="size-14 shrink-0 rounded-full bg-rule"></span>
    """
  end

  defp position_groups, do: @position_groups
  defp save_percentage_decimals, do: @save_percentage_decimals
  defp goals_against_decimals, do: @goals_against_decimals

  defp signed(difference) when is_integer(difference) and difference > 0, do: "+#{difference}"
  defp signed(difference), do: difference

  defp against(game),
    do: "#{if game.at_home, do: "vs", else: "at"} #{game.opponent.nickname}"

  defp game_time(starts_at) when is_binary(starts_at) do
    case DateTime.from_iso8601(starts_at) do
      {:ok, utc, _offset} ->
        utc
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()
        |> NaiveDateTime.from_erl!()
        |> Calendar.strftime("%a %b %-d, %-I:%M %p")

      _ ->
        nil
    end
  end

  defp game_time(_starts_at), do: nil

  defp outcome(%{score: score, opponent_score: opponent_score}) when score > opponent_score,
    do: "W"

  defp outcome(%{decided_in: @regulation}), do: "L"
  defp outcome(_game), do: "OTL"

  defp injury_facts(injury) do
    [
      injury.status,
      injury.injury,
      injury.expected_back && "Expected back #{day(injury.expected_back)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp day(date) do
    case Date.from_iso8601(date) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d")
      _ -> date
    end
  end

  defp decimal(value, places) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: places)

  defp decimal(_value, _places), do: nil

  @teens 11..13

  defp ordinal(rank) when is_integer(rank) do
    suffix =
      cond do
        rem(rank, 100) in @teens -> "th"
        rem(rank, 10) == 1 -> "st"
        rem(rank, 10) == 2 -> "nd"
        rem(rank, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{rank}#{suffix}"
  end

  defp ordinal(rank), do: rank
end
