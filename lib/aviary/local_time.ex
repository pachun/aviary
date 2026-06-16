defmodule Aviary.LocalTime do
  @moduledoc """
  "Today" in the deployment's configured timezone.

  Most "is this today / tomorrow / this Friday" decisions in aviary
  need to match what the user sees on their wall clock, not UTC.
  `Date.utc_today/0` got this wrong: at 9 pm EDT Monday it returns
  Tuesday's date, so an episode airing Tuesday rendered as "later
  today (Tuesday)" while the user's actual today was Monday.

  Implementation just defers to `:calendar.local_time/0`, which
  honors the container's `TZ` env var (depot's configure.sh sets
  it from `timedatectl`). No tzdata dep needed.

  When something genuinely wants a UTC date (database keys,
  comparisons against a UTC-stamped log entry), continue to use
  `Date.utc_today/0` directly — this helper is for the user-facing
  "what day is it" sense only.
  """

  @doc "Returns today's Date in the deployment's local timezone."
  def today do
    {{y, m, d}, _} = :calendar.local_time()
    Date.new!(y, m, d)
  end
end
