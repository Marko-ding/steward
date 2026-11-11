# SPDX-License-Identifier: Apache-2.0

defmodule Steward.ReconciliationTest do
  use Steward.DataCase
  import Steward.Reconciliation, only: [reconcile_all_due: 3]
  import Steward.Utils, only: [hash: 1]
  alias Steward.MockController
  alias Steward.MockWorker
  alias Steward.Spec
  alias Steward.TestOban
  alias Steward.TestSteward

  # By default, resources are loaded as is and their worker desires no jobs.
  setup do
    stub_defaults(MockController)

    MockWorker
    |> stub_defaults()
    |> stub(:spec, fn spec, _, _ -> spec end)

    :ok
  end

  defp reconcile(opts \\ []), do: reconcile_all_due(TestOban, TestSteward, opts)

  defp stub_spec(fun), do: stub(MockWorker, :spec, fn spec, _, _ -> fun.(spec) end)

  defp reschedule(resource), do: Steward.Controller.schedule_resource!(MockController, resource)

  describe "reconcile_all_due/3" do
    test "moves the resource to :idle" do
      resource = insert_resource()
      stub_spec(&Spec.schedule(&1, MockWorker, %{}))

      {:ok, 1} = reconcile()

      resource = reload(resource)
      assert resource.reconciliation_state == :idle
      refute resource.reconciliation_due_at
      refute resource.cancelled_at
      assert [_job] = resource_jobs(resource)
    end

    test "reconciles a resource scheduled during reconciliation again" do
      resource = insert_resource()
      test_pid = self()

      # Simulates a concurrent schedule (e.g. a job finishing) mid-reconciliation.
      MockWorker
      |> expect(:spec, fn spec, resource, _existing_jobs ->
        send(test_pid, :first_spec)
        reschedule(resource)
        spec
      end)
      |> expect(:spec, fn spec, _resource, _existing_jobs ->
        send(test_pid, :second_spec)
        spec
      end)

      # Counted once per reconciliation.
      {:ok, 2} = reconcile()

      assert_received :first_spec
      assert_received :second_spec

      resource = reload(resource)
      assert resource.reconciliation_state == :idle
      refute resource.reconciliation_due_at
    end
  end

  describe "reconcile_all_due/3 periodic reconciliation" do
    setup do
      stub(MockController, :__steward_controller_config__, fn ->
        %{reconcile_interval: :timer.minutes(10)}
      end)

      :ok
    end

    test "schedules the resource after its controller's reconcile_interval" do
      resource = insert_resource()
      before = from_now(600)

      {:ok, _} = reconcile()

      resource = reload(resource)
      assert resource.reconciliation_state == :scheduled
      assert_between(resource.reconciliation_due_at, before, from_now(600))
    end

    test "a schedule during reconciliation takes precedence over the interval" do
      resource = insert_resource()

      MockWorker
      |> expect(:spec, fn spec, resource, _ ->
        reschedule(resource)
        spec
      end)
      # Reconciled again right away, not after the interval.
      |> expect(:spec, fn spec, _, _ -> spec end)

      {:ok, _} = reconcile()

      resource = reload(resource)
      assert resource.reconciliation_state == :scheduled
      assert DateTime.compare(resource.reconciliation_due_at, from_now(590)) == :gt
    end

    test "does not schedule cancelled resources" do
      resource = insert_resource(%{cancelled_at: from_now(-10)})

      {:ok, _} = reconcile()

      resource = reload(resource)
      assert resource.reconciliation_state == :idle
      refute resource.reconciliation_due_at
    end

    test "cancels the resource and deletes its jobs when load/1 returns :cancel" do
      resource = insert_resource()
      insert_job(resource, %{state: "scheduled"})
      expect(MockController, :load, fn _ -> :cancel end)

      {:ok, _} = reconcile()

      resource = reload(resource)
      assert resource.cancelled_at
      assert resource.reconciliation_state == :idle
      refute resource.reconciliation_due_at
      assert [] = resource_jobs(resource)
    end

    test "is not due again within the same run" do
      insert_resource()
      # Counts calls by message: an `expect/4` would fall back to the stub once exhausted.
      stub(MockWorker, :spec, fn spec, _, _ ->
        send(self(), :spec)
        spec
      end)

      {:ok, _} = reconcile()

      assert_received :spec
      refute_received :spec
    end
  end

  describe "reconcile_all_due/3 job management" do
    setup do
      %{resource: insert_resource()}
    end

    # Ignores the snapshot Steward stores of the fields it applied.
    defp comparable(jobs) when is_list(jobs), do: Enum.map(jobs, &comparable/1)

    defp comparable(job) do
      job
      |> Map.take([:id, :state, :args, :priority, :tags, :scheduled_at, :meta])
      |> Map.update!(:meta, &Map.delete(&1, "steward_applied"))
    end

    test "inserts desired jobs", %{resource: resource} do
      stub_spec(fn spec ->
        spec
        |> Spec.schedule(MockWorker, %{"a" => 1}, steward_unique_key: "a")
        |> Spec.schedule(MockWorker, %{"b" => 2}, steward_unique_key: "b", priority: 2)
      end)

      {:ok, _} = reconcile()

      assert [job_a, job_b] = resource_jobs(resource) |> Enum.sort_by(& &1.args)
      assert job_a.args == %{"a" => 1}
      assert job_a.meta["steward_unique_key"] == hash("a")
      assert job_b.args == %{"b" => 2}
      assert job_b.priority == 2
    end

    test "does not insert a job twice", %{resource: resource} do
      stub_spec(&Spec.schedule(&1, MockWorker, %{}))

      {:ok, _} = reconcile()
      [job] = resource_jobs(resource)

      reschedule(resource)
      {:ok, _} = reconcile()

      assert [^job] = resource_jobs(resource)
    end

    test "does not re-insert a completed job", %{resource: resource} do
      completed = insert_job(resource, %{state: "completed"})
      stub_spec(&Spec.schedule(&1, MockWorker, %{}))

      {:ok, _} = reconcile()

      assert [%{id: id, state: "completed"}] = resource_jobs(resource)
      assert id == completed.id
    end

    test "deletes pending jobs that are no longer desired", %{resource: resource} do
      insert_job(resource, %{state: "available"})

      completed =
        insert_job(resource, %{state: "completed", meta: %{"steward_unique_key" => hash("c")}})

      {:ok, _} = reconcile()

      assert Enum.map(resource_jobs(resource), & &1.id) == [completed.id]
    end

    test "does not touch jobs of other resources", %{resource: resource} do
      other = insert_idle_resource()
      insert_job(other, %{state: "available"})

      {:ok, _} = reconcile()

      assert [_] = resource_jobs(other)
      assert [] = resource_jobs(resource)
    end

    test "updates pending jobs whose desired attributes changed", %{resource: resource} do
      job = insert_job(resource, %{state: "scheduled", args: %{"v" => 1}, priority: 0})
      scheduled_at = DateTime.truncate(from_now(3600), :second)

      stub_spec(
        &Spec.schedule(&1, MockWorker, %{"v" => 2},
          priority: 3,
          tags: ["t"],
          scheduled_at: scheduled_at
        )
      )

      {:ok, _} = reconcile()

      assert [updated] = resource_jobs(resource)
      assert updated.id == job.id
      assert updated.args == %{"v" => 2}
      assert updated.priority == 3
      assert updated.tags == ["t"]
      assert DateTime.compare(updated.scheduled_at, scheduled_at) == :eq
    end

    test "does not update executing jobs", %{resource: resource} do
      executing = insert_job(resource, %{state: "executing", args: %{"v" => 1}})
      stub_spec(&Spec.schedule(&1, MockWorker, %{"v" => 2}))

      {:ok, _} = reconcile()

      assert comparable(resource_jobs(resource)) == comparable([executing])
    end

    test "does not touch scheduled_at when not given", %{resource: resource} do
      job = insert_job(resource, %{state: "scheduled", scheduled_at: from_now(60)})
      stub_spec(&Spec.schedule(&1, MockWorker, %{}))

      {:ok, _} = reconcile()

      assert comparable(resource_jobs(resource)) == comparable([job])
    end

    test "runs a job immediately once the spec no longer sets scheduled_at", %{
      resource: resource
    } do
      scheduled_at = DateTime.truncate(from_now(1, :day), :second)
      stub_spec(&Spec.schedule(&1, MockWorker, %{}, scheduled_at: scheduled_at))

      {:ok, _} = reconcile()
      [job] = resource_jobs(resource)

      stub_spec(&Spec.schedule(&1, MockWorker, %{}))
      reschedule(resource)
      {:ok, _} = reconcile()

      assert [%{id: id, scheduled_at: actual}] = resource_jobs(resource)
      assert id == job.id
      assert DateTime.compare(actual, from_now(1)) == :lt
    end

    # Unlike the tests in `Steward.Reconciliation.PlanTest`, these round-trip the applied
    # snapshot through the database.
    test "keeps changes made outside of Steward", %{resource: resource} do
      scheduled_at = DateTime.truncate(from_now(3600), :second)
      stub_spec(&Spec.schedule(&1, MockWorker, %{}, scheduled_at: scheduled_at))

      {:ok, _} = reconcile()
      [job] = resource_jobs(resource)
      assert job.meta["steward_applied"]

      rescheduled_at = DateTime.add(scheduled_at, 1, :day)
      {:ok, _} = Oban.update_job(TestOban, job, %{scheduled_at: rescheduled_at})

      reschedule(resource)
      {:ok, _} = reconcile()

      assert [%{id: id, scheduled_at: actual}] = resource_jobs(resource)
      assert id == job.id
      assert DateTime.compare(actual, rescheduled_at) == :eq
    end

    test "overrides changes made outside of Steward once the spec changes", %{resource: resource} do
      scheduled_at = DateTime.truncate(from_now(3600), :second)
      stub_spec(&Spec.schedule(&1, MockWorker, %{}, scheduled_at: scheduled_at))

      {:ok, _} = reconcile()
      [job] = resource_jobs(resource)

      {:ok, _} =
        Oban.update_job(TestOban, job, %{scheduled_at: DateTime.add(scheduled_at, 1, :day)})

      desired = DateTime.add(scheduled_at, 1, :hour)
      stub_spec(&Spec.schedule(&1, MockWorker, %{}, scheduled_at: desired))
      reschedule(resource)
      {:ok, _} = reconcile()

      assert [%{scheduled_at: actual}] = resource_jobs(resource)
      assert DateTime.compare(actual, desired) == :eq
    end
  end

  describe "reconcile_all_due/3 callback errors" do
    setup do
      failing = insert_resource()
      healthy = insert_resource()
      failing_job = insert_job(failing, %{state: "scheduled"})

      %{failing: failing, healthy: healthy, failing_job: failing_job}
    end

    # Stores the error, keeps the jobs and reconciles again after the default
    # `:reconciliation_error_backoff` of 1 hour.
    defp assert_failed(failing, failing_job, message) do
      failing = reload(failing)
      assert failing.reconciliation_state == :scheduled
      assert_between(failing.reconciliation_due_at, from_now(59, :minute), from_now(61, :minute))
      assert failing.reconciliation_error =~ "** (RuntimeError) #{message}"
      assert failing.reconciliation_error =~ "reconciliation_test.exs"
      assert [%{id: id, state: "scheduled"}] = resource_jobs(failing)
      assert id == failing_job.id
    end

    defp assert_reconciled(healthy) do
      healthy = reload(healthy)
      assert healthy.reconciliation_state == :idle
      refute healthy.reconciliation_error
      assert [_job] = resource_jobs(healthy)
    end

    defp backdate_due_at(resource) do
      resource
      |> reload()
      |> Ecto.Changeset.change(reconciliation_due_at: from_now(-1))
      |> Steward.TestRepo.update!()
    end

    test "handles errors raised by load/1", ctx do
      stub(MockController, :load, fn resource ->
        if resource.id == ctx.failing.id, do: raise("load failed"), else: {:ok, resource}
      end)

      stub_spec(&Spec.schedule(&1, MockWorker, %{}))

      # Failed resources are counted, too.
      {:ok, 2} = reconcile()

      assert_failed(ctx.failing, ctx.failing_job, "load failed")
      assert_reconciled(ctx.healthy)
    end

    test "handles errors raised by spec/3", ctx do
      stub(MockWorker, :spec, fn spec, resource, _ ->
        if resource.id == ctx.failing.id, do: raise("spec failed")
        Spec.schedule(spec, MockWorker, %{})
      end)

      {:ok, _} = reconcile()

      assert_failed(ctx.failing, ctx.failing_job, "spec failed")
      assert_reconciled(ctx.healthy)
    end

    test "reconciles the failing resource again after the backoff", ctx do
      stub(MockWorker, :spec, fn spec, resource, _ ->
        if resource.id == ctx.failing.id, do: raise("spec failed")
        spec
      end)

      {:ok, _} = reconcile()

      stub_spec(& &1)

      # Not due yet.
      {:ok, _} = reconcile()
      assert scheduled?(ctx.failing)

      backdate_due_at(ctx.failing)
      {:ok, _} = reconcile()

      failing = reload(ctx.failing)
      assert failing.reconciliation_state == :idle
      refute failing.reconciliation_error
      assert [] = resource_jobs(failing)
    end

    test "honors a custom :reconciliation_error_backoff", ctx do
      stub(MockWorker, :spec, fn spec, resource, _ ->
        if resource.id == ctx.failing.id, do: raise("spec failed")
        spec
      end)

      {:ok, _} = reconcile(reconciliation_error_backoff: :timer.minutes(5))

      due_at = reload(ctx.failing).reconciliation_due_at
      assert_between(due_at, from_now(4, :minute), from_now(6, :minute))
    end

    test "backs off the whole batch on errors outside of single resources", ctx do
      unknown = insert_resource(%{controller: "Steward.UnknownController"})

      :error = reconcile()

      for resource <- [ctx.failing, ctx.healthy, unknown] do
        resource = reload(resource)
        assert resource.reconciliation_state == :scheduled
        # Plus up to 10% jitter.
        assert_between(
          resource.reconciliation_due_at,
          from_now(59, :minute),
          from_now(67, :minute)
        )

        refute resource.reconciliation_error
      end

      # Jobs are untouched.
      assert [%{state: "scheduled"}] = resource_jobs(ctx.failing)
    end
  end

  describe "reconcile_all_due/3 telemetry" do
    @events [
      [:steward, :reconciliation, :start],
      [:steward, :reconciliation, :stop],
      [:steward, :reconciliation, :exception],
      [:steward, :reconciliation, :resource, :start],
      [:steward, :reconciliation, :resource, :stop],
      [:steward, :reconciliation, :resource, :exception]
    ]

    setup do
      %{ref: :telemetry_test.attach_event_handlers(self(), @events)}
    end

    test "emits run and resource events", %{ref: ref} do
      %{id: id} = insert_resource()

      {:ok, _} = reconcile()

      assert_received {[:steward, :reconciliation, :start], ^ref, _,
                       %{oban: TestOban, steward: TestSteward}}

      assert_received {[:steward, :reconciliation, :resource, :start], ^ref, _,
                       %{controller: MockController, resource: %{id: ^id}}}

      assert_received {[:steward, :reconciliation, :resource, :stop], ^ref, %{duration: _}, _}

      assert_received {[:steward, :reconciliation, :stop], ^ref,
                       %{duration: _, batch_count: 1, resource_count: 1}, _}
    end

    test "emits nothing but the run events when no resource is due", %{ref: ref} do
      {:ok, _} = reconcile()

      assert_received {[:steward, :reconciliation, :stop], ^ref,
                       %{batch_count: 0, resource_count: 0}, _}

      refute_received {[:steward, :reconciliation, :resource, :start], ^ref, _, _}
    end

    test "emits a resource exception event", %{ref: ref} do
      %{id: id} = insert_resource()

      stub(MockController, :load, fn _resource -> raise "load failed" end)

      {:ok, _} = reconcile()

      assert_received {[:steward, :reconciliation, :resource, :exception], ^ref, %{duration: _},
                       %{
                         resource: %{id: ^id},
                         kind: :error,
                         reason: %RuntimeError{message: "load failed"},
                         stacktrace: [_ | _]
                       }}
    end

    test "ends the run with an exception event when a whole batch fails", %{ref: ref} do
      insert_resource(%{controller: "Steward.UnknownController"})

      :error = reconcile()

      assert_received {[:steward, :reconciliation, :exception], ^ref, %{duration: _},
                       %{kind: :error, reason: %ArgumentError{}, stacktrace: [_ | _]}}

      refute_received {[:steward, :reconciliation, :stop], ^ref, _, _}
    end
  end
end
