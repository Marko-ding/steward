# SPDX-License-Identifier: Apache-2.0

defmodule Steward.ObanTest do
  use Steward.DataCase
  import Steward.Oban, only: [build_job_changeset: 5]
  alias Steward.MockWorker
  alias Steward.TestOban

  setup do
    stub_defaults(MockWorker)
    :ok
  end

  describe "build_job_changeset/5" do
    # Exercises Oban's own uniqueness check, which `Oban.insert/2` runs (unlike `insert_all/2`
    # with the Basic engine).
    test "tells jobs apart by unique key" do
      resource = insert_resource()

      {:ok, a} = Oban.insert(TestOban, build_job_changeset(resource, MockWorker, %{}, [], "a"))
      {:ok, b} = Oban.insert(TestOban, build_job_changeset(resource, MockWorker, %{}, [], "b"))

      refute a.conflict?
      refute b.conflict?
    end

    test "detects duplicates" do
      resource = insert_resource()

      {:ok, _} = Oban.insert(TestOban, build_job_changeset(resource, MockWorker, %{}, [], "k"))
      {:ok, dup} = Oban.insert(TestOban, build_job_changeset(resource, MockWorker, %{}, [], "k"))

      assert dup.conflict?
    end

    test "raises without a unique key" do
      resource = insert_resource()

      assert_raise FunctionClauseError, fn ->
        build_job_changeset(resource, MockWorker, %{}, [], nil)
      end
    end
  end

  describe "delete_deletable_jobs/2" do
    test "only deletes pending jobs" do
      resource = insert_resource()

      deleted =
        for state <- ~w[available scheduled retryable],
            do: insert_job(resource, %{state: state, meta: %{"steward_unique_key" => state}})

      kept =
        for state <- ~w[executing completed discarded cancelled],
            do: insert_job(resource, %{state: state, meta: %{"steward_unique_key" => state}})

      assert {:ok, 3} =
               Steward.Oban.delete_deletable_jobs(TestOban, Enum.map(deleted ++ kept, & &1.id))

      assert Enum.map(resource_jobs(resource), & &1.id) == Enum.map(kept, & &1.id)
    end
  end
end
