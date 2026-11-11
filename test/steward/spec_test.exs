# SPDX-License-Identifier: Apache-2.0

defmodule Steward.SpecTest do
  use ExUnit.Case, async: true
  alias Steward.Spec

  describe "schedule/4" do
    test "adds the job to the spec" do
      spec = Spec.schedule(Spec.new(), SomeWorker, %{"a" => 1}, priority: 1)

      assert spec.jobs == [
               {SomeWorker, %{"a" => 1},
                [steward_unique_key: Steward.Utils.hash(nil), priority: 1]}
             ]
    end

    for opt <- [:unique, :replace] do
      test "raises for the #{inspect(opt)} option" do
        assert_raise ArgumentError, ~r/Not allowed to specify :unique or :replace/, fn ->
          Spec.schedule(Spec.new(), SomeWorker, %{}, [{unquote(opt), []}])
        end
      end
    end

    test "raises for the :schedule_in option" do
      assert_raise ArgumentError, ~r/:schedule_in is not allowed/, fn ->
        Spec.schedule(Spec.new(), SomeWorker, %{}, schedule_in: 60)
      end
    end

    test "raises for unsupported options" do
      assert_raise ArgumentError, ~r/Unsupported options \[:meta\] for SomeWorker/, fn ->
        Spec.schedule(Spec.new(), SomeWorker, %{}, meta: %{"a" => 1})
      end
    end

    test "raises for duplicate jobs of a worker" do
      spec = Spec.schedule(Spec.new(), SomeWorker, %{})

      assert_raise ArgumentError, ~r/Job is not unique in the spec/, fn ->
        Spec.schedule(spec, SomeWorker, %{})
      end
    end

    test "allows multiple jobs of a worker with distinct unique keys" do
      spec =
        Spec.new()
        |> Spec.schedule(SomeWorker, %{}, steward_unique_key: "a")
        |> Spec.schedule(SomeWorker, %{}, steward_unique_key: "b")

      assert length(spec.jobs) == 2
    end

    test "hashes the unique key" do
      spec = Spec.schedule(Spec.new(), SomeWorker, %{}, steward_unique_key: %{id: 1})

      assert [{SomeWorker, %{}, [steward_unique_key: hash]}] = spec.jobs
      assert hash == Steward.Utils.hash(%{id: 1})
      assert hash =~ ~r/^[0-9a-f]{8}$/
    end

    test "hashes falsy unique keys" do
      spec = Spec.schedule(Spec.new(), SomeWorker, %{}, steward_unique_key: false)

      assert [{SomeWorker, %{}, [steward_unique_key: hash]}] = spec.jobs
      assert hash == Steward.Utils.hash(false)
    end

    test "raises for duplicate unique keys of a worker" do
      spec = Spec.schedule(Spec.new(), SomeWorker, %{}, steward_unique_key: %{id: 1})

      assert_raise ArgumentError, ~r/Job is not unique in the spec/, fn ->
        Spec.schedule(spec, SomeWorker, %{}, steward_unique_key: %{id: 1})
      end
    end
  end
end
