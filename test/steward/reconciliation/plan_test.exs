# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Reconciliation.PlanTest do
  use ExUnit.Case, async: true

  import Steward.Utils, only: [hash: 1]
  alias Steward.Reconciliation.Plan
  alias Steward.Resource
  alias Steward.Spec

  defmodule Worker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  @resource %Resource{controller: "MyController", id: "8c5c6a2e-3b4f-4b8e-9a3e-1f0d2c3b4a5d"}
  @scheduled_at ~U[2026-11-12 12:00:00.000000Z]

  # Goes through `Spec.schedule/4`, which hashes the unique key.
  defp desired(args \\ %{}, opts \\ []) do
    [job] = Spec.schedule(Spec.new(), Worker, args, opts).jobs
    Plan.desired(@resource, job)
  end

  # A job without snapshot, so Steward owns all of its fields. `:unique_key` is hashed.
  defp existing(attrs \\ %{}) do
    {unique_key, attrs} = Map.pop(attrs, :unique_key)
    {meta, attrs} = Map.pop(attrs, :meta, %{})
    meta = Map.put(meta, "steward_unique_key", hash(unique_key))

    %Oban.Job{
      id: System.unique_integer([:positive]),
      state: "scheduled",
      worker: Oban.Worker.to_string(Worker),
      queue: "default",
      args: %{},
      priority: 0,
      max_attempts: 20,
      tags: [],
      scheduled_at: @scheduled_at,
      meta:
        Map.merge(
          %{"steward_controller" => @resource.controller, "steward_resource_id" => @resource.id},
          meta
        )
    }
    |> struct!(attrs)
  end

  # A job as Steward wrote it for `desired`, then modified by `attrs`.
  defp applied(%{snapshot: _} = desired, attrs \\ %{}) do
    {meta, attrs} = Map.pop(attrs, :meta, %{})

    desired.fields
    |> Map.merge(attrs)
    |> Map.put(:meta, Map.put(meta, "steward_applied", desired.snapshot))
    |> existing()
  end

  defp plan(desired, existing), do: Plan.plan(List.wrap(desired), List.wrap(existing))

  describe "desired/2" do
    test "only holds the fields the spec sets" do
      assert desired().fields == %{args: %{}, max_attempts: 20, queue: "default", tags: []}
    end

    test "normalizes args to their JSON form" do
      assert desired(%{a: :b}).fields.args == %{"a" => "b"}
    end

    test "stores the unique key in the job's meta" do
      desired = desired(%{}, steward_unique_key: "k")
      hash = hash("k")

      assert {_, _, _, ^hash} = desired.key
      assert Ecto.Changeset.get_field(desired.changeset, :meta).steward_unique_key == hash
    end

    test "stores the hash of nil as unique key in the job's meta when not given" do
      hash = hash(nil)

      assert {_, _, _, ^hash} = desired().key
      assert Ecto.Changeset.get_field(desired().changeset, :meta).steward_unique_key == hash
    end

    test "matches the key of the existing job" do
      assert desired().key == Plan.key(existing())

      assert desired(%{}, steward_unique_key: "k").key ==
               Plan.key(existing(%{unique_key: "k"}))
    end

    test "stores a snapshot of the fields in the job's meta, with args hashed" do
      desired = desired(%{"a" => 1}, scheduled_at: @scheduled_at)

      assert %{
               "args" => hash,
               "scheduled_at" => "2026-11-12T12:00:00.000000Z",
               "max_attempts" => 20,
               "queue" => "default",
               "tags" => []
             } = desired.snapshot

      assert hash =~ ~r/^[0-9a-f]{8}$/

      assert Ecto.Changeset.get_field(desired.changeset, :meta).steward_applied ==
               desired.snapshot
    end

    test "raises for invalid jobs, naming the worker" do
      assert_raise ArgumentError, ~r/invalid job scheduled by .*Worker: .*priority/, fn ->
        desired(%{}, priority: 99)
      end
    end
  end

  describe "plan/2" do
    test "inserts desired jobs that don't exist" do
      desired = desired()

      assert plan(desired, []) == [{:insert, desired.changeset}]
    end

    test "does nothing when the job is as Steward applied it" do
      desired = desired(%{"a" => 1})

      assert plan(desired, applied(desired)) == []
    end

    test "updates jobs to be changed" do
      desired = desired(%{"v" => 2})
      existing = applied(desired(%{"v" => 1}))

      assert plan(desired, existing) == [{:update, existing, desired}]
    end

    test "tells jobs apart by unique key" do
      desired = desired(%{}, steward_unique_key: "b")
      existing = existing(%{unique_key: "a"})

      assert Enum.sort(plan(desired, existing)) ==
               Enum.sort([{:insert, desired.changeset}, {:delete, existing}])
    end

    for state <- ~w[available scheduled retryable] do
      test "deletes undesired #{state} jobs" do
        existing = existing(%{state: unquote(state)})

        assert plan([], existing) == [{:delete, existing}]
      end
    end

    for state <- ~w[executing completed discarded cancelled] do
      test "keeps undesired #{state} jobs" do
        assert plan([], existing(%{state: unquote(state)})) == []
      end
    end
  end

  describe "update/2" do
    test "changes the fields that differ and stores the new snapshot" do
      previous = desired(%{"v" => 1}, priority: 0, scheduled_at: @scheduled_at)
      existing = applied(previous)
      desired = desired(%{v: 2}, priority: 3, scheduled_at: DateTime.add(@scheduled_at, 1, :hour))

      assert {:ok, changes} = Plan.update(desired, existing)

      assert Map.delete(changes, :meta) ==
               Map.take(desired.fields, [:args, :priority, :scheduled_at])

      assert changes.meta == Map.put(existing.meta, "steward_applied", desired.snapshot)
    end

    test "doesn't reconcile fields the spec doesn't set" do
      desired = desired()

      assert Plan.update(desired, applied(desired, %{priority: 3, scheduled_at: @scheduled_at})) ==
               :skip
    end

    test "resets fields the spec no longer sets to their defaults" do
      existing = applied(desired(%{}, priority: 3, tags: ["t"], scheduled_at: @scheduled_at))
      desired = desired()
      now = DateTime.add(@scheduled_at, -1, :day)

      assert {:ok, changes} = Plan.update(desired, existing, now)
      assert Map.delete(changes, :meta) == %{priority: 0, tags: [], scheduled_at: now}
      assert changes.meta["steward_applied"] == desired.snapshot

      # The new snapshot no longer tracks them, so they're left alone afterwards.
      assert Plan.update(desired, applied(desired, Map.delete(changes, :meta)), now) == :skip
    end

    test "resets fields changed outside of Steward once the spec no longer sets them" do
      existing =
        applied(desired(%{}, scheduled_at: @scheduled_at), %{
          scheduled_at: DateTime.add(@scheduled_at, 1, :day)
        })

      now = DateTime.add(@scheduled_at, -1, :day)

      assert {:ok, %{scheduled_at: ^now}} = Plan.update(desired(), existing, now)
    end

    test "doesn't reset scheduled_at within 10s of now" do
      existing = applied(desired(%{}, scheduled_at: @scheduled_at))

      assert {:ok, changes} =
               Plan.update(desired(), existing, DateTime.add(@scheduled_at, 5, :second))

      assert Map.keys(changes) == [:meta]
    end

    test "tolerates scheduled_at within 10s of the desired time" do
      applied_desired = desired(%{}, scheduled_at: @scheduled_at)
      existing = applied(applied_desired)

      # Snapshots differ, so only the meta is updated.
      assert {:ok, changes} =
               Plan.update(
                 desired(%{}, scheduled_at: DateTime.add(@scheduled_at, 10, :second)),
                 existing
               )

      assert Map.keys(changes) == [:meta]

      desired = desired(%{}, scheduled_at: DateTime.add(@scheduled_at, 11, :second))

      assert {:ok, %{scheduled_at: scheduled_at}} = Plan.update(desired, existing)
      assert scheduled_at == desired.fields.scheduled_at
    end

    for state <- ~w[available retryable executing completed] do
      test "skips #{state} jobs" do
        desired = desired(%{"v" => 2})

        assert Plan.update(desired, applied(desired(), %{state: unquote(state)})) == :skip
      end
    end

    test "keeps fields changed outside of Steward" do
      desired = desired(%{"v" => 1}, priority: 1, scheduled_at: @scheduled_at)

      existing =
        applied(desired, %{
          args: %{"v" => 0},
          priority: 9,
          scheduled_at: DateTime.add(@scheduled_at, 1, :day)
        })

      assert Plan.update(desired, existing) == :skip
    end

    test "overrides fields changed outside of Steward once the desired value changes" do
      previous = desired(%{}, priority: 1, scheduled_at: @scheduled_at)

      existing =
        applied(previous, %{priority: 9, scheduled_at: DateTime.add(@scheduled_at, 1, :day)})

      desired = desired(%{}, priority: 1, scheduled_at: DateTime.add(@scheduled_at, 1, :hour))

      assert {:ok, changes} = Plan.update(desired, existing)
      # Priority is still desired as applied, so it's kept.
      refute Map.has_key?(changes, :priority)
      assert changes.scheduled_at == desired.fields.scheduled_at
    end
  end
end
