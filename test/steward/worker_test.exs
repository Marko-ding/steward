# SPDX-License-Identifier: Apache-2.0

defmodule Steward.WorkerTest do
  use Steward.DataCase
  alias Steward.MockController
  alias Steward.MockWorker

  setup do
    stub_defaults(MockController)
    %{resource: insert_idle_resource()}
  end

  # A job of `resource` in its first of two attempts, unless `attrs` say otherwise.
  defp job(resource, attrs \\ %{}) do
    struct!(
      %Oban.Job{
        id: System.unique_integer([:positive]),
        worker: Oban.Worker.to_string(MockWorker),
        args: %{},
        attempt: 1,
        max_attempts: 2,
        meta: %{"steward_controller" => resource.controller, "steward_resource_id" => resource.id}
      },
      attrs
    )
  end

  defp last_attempt(resource), do: job(resource, %{attempt: 2})

  describe "perform/1" do
    test "calls perform/2 with the job and the loaded object", %{resource: resource} do
      job = job(resource)
      resource_id = resource.id
      expect(MockController, :load, fn %{id: ^resource_id} -> {:ok, :loaded} end)
      expect(MockWorker, :perform, fn ^job, :loaded -> :ok end)

      assert Steward.Worker.perform(job) == :ok
    end

    for result <- [:ok, {:ok, :value}, :discard, {:discard, :reason}, {:cancel, :reason}] do
      test "returns #{inspect(result)} and schedules the resource", %{resource: resource} do
        expect(MockWorker, :perform, fn _, _ -> unquote(Macro.escape(result)) end)

        assert Steward.Worker.perform(job(resource)) == unquote(Macro.escape(result))
        assert scheduled?(resource)
      end
    end

    for result <- [{:error, :reason}, {:snooze, 60}] do
      test "returns #{inspect(result)} without scheduling the resource when retryable", %{
        resource: resource
      } do
        expect(MockWorker, :perform, fn _, _ -> unquote(Macro.escape(result)) end)

        assert Steward.Worker.perform(job(resource)) == unquote(Macro.escape(result))
        refute scheduled?(resource)
      end
    end

    test "schedules the resource on an error in the last attempt", %{resource: resource} do
      expect(MockWorker, :perform, fn _, _ -> {:error, :reason} end)

      assert Steward.Worker.perform(last_attempt(resource)) == {:error, :reason}
      assert scheduled?(resource)
    end

    test "re-raises without scheduling the resource when retryable", %{resource: resource} do
      expect(MockWorker, :perform, fn _, _ -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn -> Steward.Worker.perform(job(resource)) end
      refute scheduled?(resource)
    end

    test "re-raises and schedules the resource in the last attempt", %{resource: resource} do
      expect(MockWorker, :perform, fn _, _ -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn ->
        Steward.Worker.perform(last_attempt(resource))
      end

      assert scheduled?(resource)
    end

    test "cancels the job of a cancelled resource" do
      resource = insert_resource(%{cancelled_at: from_now(-10)})

      assert Steward.Worker.perform(job(resource)) == {:cancel, :resource_cancelled}
    end

    test "cancels the job and the resource when load/1 returns :cancel", %{resource: resource} do
      expect(MockController, :load, fn _ -> :cancel end)

      assert Steward.Worker.perform(job(resource)) == {:cancel, :resource_cancelled}

      resource = reload(resource)
      assert resource.cancelled_at
      assert resource.reconciliation_state == :scheduled
    end

    test "cancels the job of a missing resource" do
      resource = %Steward.Resource{controller: "Steward.MockController", id: Ecto.UUID.generate()}

      assert Steward.Worker.perform(job(resource)) == {:cancel, :resource_not_found}
    end
  end
end
