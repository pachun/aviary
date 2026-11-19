defmodule AviaryWeb.Components.NhlTables do
  @moduledoc """
  The NHL page's standings and team views: each division's table, the
  list of teams, and one team's lines, injuries, results and scoring.
  """
  use Phoenix.Component

  @regulation "REG"
  @save_percentage_decimals 3
  @goals_against_decimals 2
  @position_names %{"C" => "C", "L" => "LW", "R" => "RW", "D" => "D", "G" => "G"}
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

  def teams(assigns) do
    ~H"""
    <p :if={@teams == :unavailable} class="font-sans text-muted">Teams are unavailable.</p>
    <p :if={@team == :unavailable} class="font-sans text-muted">
      This team's page is unavailable.
    </p>

    <div :if={match?({:shown, _}, @team)}>
      <button
        type="button"
        phx-click="show_teams"
        class="font-sans text-[0.78rem] tracking-[0.18em] uppercase text-oxblood hover:underline cursor-pointer mb-8"
      >
        All teams
      </button>
      <.team_page team={elem(@team, 1)} />
    </div>

    <table
      :if={is_list(@teams) and not match?({:shown, _}, @team)}
      class="w-full font-sans text-sm tabular-nums"
    >
      <thead>
        <tr class="border-b border-rule text-muted text-[0.7rem] tracking-[0.14em] uppercase">
          <th colspan="2"></th>
          <th
            :for={heading <- ~w(GP W L OTL PTS DIFF L10 STRK)}
            class="text-right font-normal py-2 pl-3"
          >
            {heading}
          </th>
        </tr>
      </thead>
      <tbody>
        <tr
          :for={listed <- @teams}
          phx-click="show_team"
          phx-value-team={listed.id}
          class="group border-b border-rule cursor-pointer hover:bg-rule/40"
        >
          <td class="py-2 pr-2 text-muted w-8">{listed.league_rank}</td>
          <td class="py-2">
            <button
              type="button"
              class="flex items-center gap-3 cursor-pointer text-ink group-hover:text-oxblood focus-visible:outline-2 focus-visible:outline-oxblood"
            >
              <img src={listed.logo_url} alt="" class="size-7" />
              <span class="font-display text-base">{listed.name}</span>
            </button>
          </td>
          <td class="text-right pl-3 text-muted">{listed.games_played}</td>
          <td class="text-right pl-3 text-muted">{listed.wins}</td>
          <td class="text-right pl-3 text-muted">{listed.losses}</td>
          <td class="text-right pl-3 text-muted">{listed.overtime_losses}</td>
          <td class="text-right pl-3 text-ink">{listed.points}</td>
          <td class="text-right pl-3 text-muted">{signed(listed.goal_difference)}</td>
          <td class="text-right pl-3 text-muted">{listed.last_ten}</td>
          <td class="text-right pl-3 text-muted">{listed.streak}</td>
        </tr>
      </tbody>
    </table>
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
        <section>
          <p :if={@team.lines.as_of} class="font-sans text-sm text-muted mb-4">
            {@team.lines.as_of}
          </p>
          <div class="grid gap-x-10 gap-y-10 sm:grid-cols-2">
            <div :for={{line, number} <- Enum.with_index(@team.lines.forwards, 1)}>
              <.heading label={"Line #{number}"} />
              <ul class="flex justify-center gap-5">
                <.tile :for={player <- line} player={player} />
              </ul>
            </div>
          </div>
          <div class="grid gap-x-10 gap-y-10 mt-10 grid-cols-2 lg:grid-cols-4">
            <div :for={{pair, number} <- Enum.with_index(@team.lines.defense, 1)}>
              <.heading label={"Defense #{number}"} />
              <ul class="flex justify-center gap-5">
                <.tile :for={player <- pair} player={player} />
              </ul>
            </div>
            <div :if={@team.lines.goalies != []}>
              <.heading label="Goalies" />
              <ul class="flex justify-center gap-5">
                <.tile :for={player <- @team.lines.goalies} player={player} />
              </ul>
            </div>
          </div>
        </section>
        <.units
          :if={@team.lines.power_play != []}
          label="Power play"
          units={@team.lines.power_play}
          show_position
        />
        <.units
          :if={@team.lines.penalty_kill != []}
          label="Penalty kill"
          units={@team.lines.penalty_kill}
          show_position
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
  attr :show_position, :boolean, default: false

  defp units(assigns) do
    ~H"""
    <section>
      <.heading label={@label} aside={@aside} />
      <div class="space-y-4">
        <ul :for={unit <- @units} class="flex flex-wrap gap-x-6 gap-y-3">
          <li :for={player <- forwards_then_defense(unit)} class="flex items-center gap-3 w-48">
            <.headshot player={player} />
            <div>
              <p class="font-sans text-xs text-oxblood">
                {number_and_position(player, @show_position)}
              </p>
              <p class="font-display text-ink text-base leading-tight">{player.name}</p>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :player, :map, required: true

  defp tile(assigns) do
    ~H"""
    <li class="flex w-28 flex-col items-center text-center">
      <img
        :if={@player.headshot}
        src={@player.headshot}
        alt=""
        loading="lazy"
        class="size-20 rounded-full bg-rule object-cover"
      />
      <span :if={!@player.headshot} class="size-20 rounded-full bg-rule"></span>
      <span class="font-sans text-xs text-oxblood mt-2">
        {if @player.number, do: "##{@player.number}"}
      </span>
      <span class="font-display text-ink text-base leading-tight">{@player.name}</span>
    </li>
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

  defp forwards_then_defense(unit), do: Enum.sort_by(unit, &(&1.position == "D"))

  defp number_and_position(player, show_position) do
    [
      player.number && "##{player.number}",
      show_position && Map.get(@position_names, player.position)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
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
