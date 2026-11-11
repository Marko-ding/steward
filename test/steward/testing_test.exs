# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestingTest do
  use Steward.DataCase
  alias Steward.MockController
  alias Steward.MockWorker
  alias Steward.Spec
  alias Steward.TestOban
  alias Steward.TestSteward

  setup do
    stub_defaults(MockController)

    MockWorker
    |> stub_defaults()
    |> stub(:spec, fn spec, _, _ -> Spec.schedule(spec, MockWorker, %{}) end)

    :ok
  end

  defp reconcile, do: Steward.Testing.reconcile(TestOban, TestSteward)

  describe "reconcile/2" do
    test "reconciles due resources" do
      resource = insert_resource()

      assert {:ok, 1} = reconcile()

      assert reload(resource).reconciliation_state == :idle
      assert [_job] = resource_jobs(resource)
    end

    test "raises errors of single resources" do
      insert_resource()
      stub(MockWorker, :spec, fn _, _, _ -> raise "spec failed" end)

      assert_raise RuntimeError, "spec failed", &reconcile/0
    end

    test "raises errors of the whole batch" do
      insert_resource(%{controller: "Steward.UnknownController"})

      assert_raise ArgumentError,
                   ~r/controller Steward.UnknownController does not exist/,
                   &reconcile/0
    end
  end
end
