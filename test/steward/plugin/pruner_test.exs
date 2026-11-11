# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin.PrunerTest do
  use Steward.DataCase
  import Steward.Plugin.Pruner, only: [prune_all_expired: 3]
  alias Steward.TestOban
  alias Steward.TestSteward

  @max_age :timer.hours(1)

  defp prune(opts \\ []) do
    prune_all_expired(TestOban, TestSteward, Keyword.put_new(opts, :prune_max_age, @max_age))
  end

  defp job_ids(resource), do: Enum.map(resource_jobs(resource), & &1.id)

  defp expired_resource, do: insert_resource(%{cancelled_at: from_now(-2, :hour)})

  test "deletes jobs of expired cancelled resources and marks them pruned" do
    resource = expired_resource()
    insert_job(resource, %{state: "completed"})
    # Another worker, as jobs are unique per resource and worker.
    insert_job(resource, %{state: "scheduled", worker: "Steward.OtherWorker"})

    prune()

    assert job_ids(resource) == []
    assert reload(resource).pruned_at
  end

  test "does not delete executing jobs" do
    resource = expired_resource()
    executing = insert_job(resource, %{state: "executing"})

    prune()

    assert job_ids(resource) == [executing.id]
  end

  test "leaves resources cancelled less than prune_max_age ago alone" do
    resource = insert_resource(%{cancelled_at: from_now(-30, :minute)})
    job = insert_job(resource, %{state: "completed"})

    prune()

    assert job_ids(resource) == [job.id]
    refute reload(resource).pruned_at
  end

  test "leaves resources that aren't cancelled alone" do
    resource = insert_resource()
    job = insert_job(resource, %{state: "completed"})

    prune()

    assert job_ids(resource) == [job.id]
    refute reload(resource).pruned_at
  end

  test "does not prune a resource twice" do
    pruned_at = from_now(-1, :hour)
    resource = insert_resource(%{cancelled_at: from_now(-2, :hour), pruned_at: pruned_at})

    prune()

    assert reload(resource).pruned_at == pruned_at
  end

  test "prunes across multiple batches" do
    resources = for _ <- 1..5, do: expired_resource()
    Enum.each(resources, &insert_job(&1, %{state: "completed"}))

    assert prune(prune_batch_size: 2) == 5

    for resource <- resources do
      assert job_ids(resource) == []
      assert reload(resource).pruned_at
    end
  end

  test "doesn't start when prune_max_age is :infinity" do
    assert :ignore =
             Steward.Plugin.Pruner.start_link(
               conf: Oban.config(TestOban),
               steward: TestSteward,
               prune_max_age: :infinity,
               name: __MODULE__.Pruner
             )
  end

  test "doesn't mark resources pruned when deleting their jobs fails" do
    resource = expired_resource()
    job = insert_job(resource, %{state: "completed"})

    # Deleting jobs raises without an Oban instance of that name.
    assert_raise RuntimeError, fn ->
      prune_all_expired(:missing_oban, TestSteward, prune_max_age: @max_age)
    end

    assert job_ids(resource) == [job.id]
    refute reload(resource).pruned_at
  end
end
