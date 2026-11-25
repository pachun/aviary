defmodule Aviary.Reconcile.SchedulerTest do
  use ExUnit.Case, async: true

  alias Aviary.Reconcile.Scheduler

  @minute_ms 60 * 1000
  @hour_ms 60 * @minute_ms

  describe "ms_until_daily_pass/1" do
    test "waits for the small hours rather than running soon after a restart" do
      assert Scheduler.ms_until_daily_pass(~N[2026-11-24 20:45:00]) ==
               7 * @hour_ms + 15 * @minute_ms
    end

    test "runs later the same night when started before the small hours" do
      assert Scheduler.ms_until_daily_pass(~N[2026-11-25 01:30:00]) ==
               2 * @hour_ms + 30 * @minute_ms
    end

    test "waits a full day when started right at the pass" do
      assert Scheduler.ms_until_daily_pass(~N[2026-11-25 04:00:00]) == 24 * @hour_ms
    end
  end
end
