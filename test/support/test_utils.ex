# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestUtils do
  @moduledoc false

  import ExUnit.Assertions
  import Ecto.Query
  import Mox
  import Steward.Utils
  alias Steward.MockController
  alias Steward.MockWorker
  alias Steward.Resource
  alias Steward.TestRepo

  @spec from_now(integer) :: DateTime.t()
  @spec from_now(integer, :second | :minute | :hour | :day | :week | :month | :year) ::
          DateTime.t()
  def from_now(delta, unit \\ :second) do
    DateTime.add(DateTime.utc_now(), delta, unit)
  end

  # Asserts `from <= datetime <= to`.
  @spec assert_between(DateTime.t(), DateTime.t(), DateTime.t()) :: true
  def assert_between(datetime, from, to) do
    assert DateTime.compare(datetime, from) != :lt,
           "expected #{inspect(datetime)} not to be before #{inspect(from)}"

    assert DateTime.compare(datetime, to) != :gt,
           "expected #{inspect(datetime)} not to be after #{inspect(to)}"
  end

  @spec reload(Resource.t()) :: Resource.t()
  def reload(%Resource{} = resource) do
    Resource
    |> where([r], r.controller == ^resource.controller and r.id == ^resource.id)
    |> TestRepo.one!()
  end

  @spec scheduled?(Resource.t()) :: boolean
  def scheduled?(%Resource{} = resource), do: reload(resource).reconciliation_state == :scheduled

  @spec stub_defaults(module) :: module
  def stub_defaults(MockController) do
    MockController
    |> stub(:__steward__, fn -> Steward.TestSteward end)
    |> stub(:__steward_controller_config__, fn -> %{reconcile_interval: :infinity} end)
    |> stub(:load, fn resource -> {:ok, resource} end)
    |> stub(:workers, fn -> [MockWorker] end)
  end

  def stub_defaults(MockWorker) do
    MockWorker
    |> stub(:new, fn args, opts -> Oban.Job.new(args, Keyword.put(opts, :worker, MockWorker)) end)
  end

  # Inserts a resource of `MockController`, due for reconciliation unless `attrs` say otherwise.
  @spec insert_resource(map) :: Resource.t()
  def insert_resource(attrs \\ %{}) do
    %{
      controller: controller_to_string!(MockController),
      reconciliation_state: :scheduled,
      reconciliation_due_at: from_now(-1)
    }
    |> Map.merge(attrs)
    |> then(&struct!(Resource, &1))
    |> TestRepo.insert!()
  end

  @spec insert_idle_resource(map) :: Resource.t()
  def insert_idle_resource(attrs \\ %{}) do
    insert_resource(Map.merge(%{reconciliation_state: :idle, reconciliation_due_at: nil}, attrs))
  end

  # Inserts a job of `resource`, reloaded to pick up database defaults (priority, timestamps).
  # `attrs` are merged into the job, its `:meta` into the resource's meta (with the unique key
  # of a job scheduled without one by default).
  @spec insert_job(Resource.t(), map) :: Oban.Job.t()
  def insert_job(%Resource{} = resource, attrs \\ %{}) do
    {meta, attrs} = Map.pop(attrs, :meta, %{})

    %{args: %{}, worker: Oban.Worker.to_string(MockWorker), queue: "default"}
    |> Map.merge(attrs)
    |> Map.put(
      :meta,
      Map.merge(
        %{
          "steward_controller" => resource.controller,
          "steward_resource_id" => resource.id,
          "steward_unique_key" => hash(nil)
        },
        meta
      )
    )
    |> then(&struct!(Oban.Job, &1))
    |> TestRepo.insert!()
    |> then(&TestRepo.get!(Oban.Job, &1.id))
  end

  # The jobs of `resource` in `Steward.TestOban`, sorted by id.
  @spec resource_jobs(Resource.t()) :: [Oban.Job.t()]
  def resource_jobs(%Resource{} = resource) do
    Steward.TestOban
    |> Steward.Oban.all_resource_jobs(resource)
    |> Enum.sort_by(& &1.id)
  end
end
