# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin.LifelineTest do
  use Steward.DataCase
  import Steward.Plugin.Lifeline, only: [rescue_all_stuck: 1, rescue_all_stuck: 2]
  alias Steward.TestSteward

  defp reconciling_resource(since, attrs \\ %{}) do
    %{
      reconciliation_state: :reconciling,
      reconciliation_state_set_at: since,
      reconciliation_due_at: nil
    }
    |> Map.merge(attrs)
    |> insert_resource()
  end

  test "schedules resources reconciling for longer than the timeout" do
    resource = reconciling_resource(from_now(-2, :day))

    assert rescue_all_stuck(TestSteward) == 1

    resource = reload(resource)
    assert resource.reconciliation_state == :scheduled
    assert DateTime.compare(resource.reconciliation_due_at, from_now(-1)) == :gt
    assert DateTime.compare(resource.reconciliation_state_set_at, from_now(-1)) == :gt
  end

  test "keeps the due time of resources scheduled mid-reconciliation" do
    due_at = from_now(1, :hour)
    resource = reconciling_resource(from_now(-2, :day), %{reconciliation_due_at: due_at})

    rescue_all_stuck(TestSteward)

    resource = reload(resource)
    assert resource.reconciliation_state == :scheduled
    assert resource.reconciliation_due_at == due_at
  end

  test "leaves resources reconciling for less than the timeout alone" do
    resource = reconciling_resource(from_now(-12, :hour))

    assert rescue_all_stuck(TestSteward) == 0
    assert reload(resource).reconciliation_state == :reconciling
  end

  test "honors a custom :lifeline_reconciliation_timeout" do
    resource = reconciling_resource(from_now(-30, :minute))

    assert rescue_all_stuck(TestSteward, lifeline_reconciliation_timeout: :timer.minutes(10)) ==
             1

    assert reload(resource).reconciliation_state == :scheduled
  end

  test "leaves resources in other states alone" do
    idle =
      insert_resource(%{
        reconciliation_state: :idle,
        reconciliation_state_set_at: from_now(-2, :day),
        reconciliation_due_at: nil
      })

    assert rescue_all_stuck(TestSteward) == 0
    assert reload(idle).reconciliation_state == :idle
  end

  test "doesn't start when the timeout is :infinity" do
    conf = Oban.config(Steward.TestOban)

    assert :ignore =
             Steward.Plugin.Lifeline.start_link(
               conf: conf,
               steward: TestSteward,
               lifeline_reconciliation_timeout: :infinity,
               name: __MODULE__.Lifeline
             )
  end
end
