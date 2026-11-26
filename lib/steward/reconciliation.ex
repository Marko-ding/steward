# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Reconciliation do
  @moduledoc false

  import Ecto.Query

  import Oban.Validation, only: [validate_schema!: 2]

  import Steward.Oban,
    only: [all_resource_jobs: 2, delete_deletable_jobs: 2, resource_job?: 2]

  import Steward.Utils, only: [controller_from_string!: 1]

  alias Steward.Controller
  alias Steward.Controller.Query
  alias Steward.Reconciliation.Locking
  alias Steward.Reconciliation.Plan
  alias Steward.Resource
  alias Steward.Spec
  alias Steward.Telemetry

  @default_reconciliation_error_backoff :timer.hours(1)

  # Returns the number of reconciled resources, including failed ones.
  @spec reconcile_all_due(module) :: {:ok, non_neg_integer} | :error
  @spec reconcile_all_due(module, module) :: {:ok, non_neg_integer} | :error
  @spec reconcile_all_due(module, module, keyword) :: {:ok, non_neg_integer} | :error
  def reconcile_all_due(oban \\ Oban, steward, opts \\ []) do
    validate_schema!(opts,
      reconcile_batch_size: :pos_integer,
      reconciliation_error_backoff: :non_neg_integer,
      raise_errors: :boolean
    )

    opts =
      Keyword.merge(
        [
          reconcile_batch_size: 10,
          reconciliation_error_backoff: @default_reconciliation_error_backoff,
          raise_errors: false
        ],
        opts
      )

    try do
      meta = %{oban: oban, steward: steward}

      Telemetry.span([:reconciliation], meta, fn ->
        measurements = reconcile_due_in_batches_until_done(oban, steward, opts)

        {{:ok, measurements.resource_count}, measurements, meta}
      end)
    catch
      kind, reason ->
        if Keyword.fetch!(opts, :raise_errors) do
          :erlang.raise(kind, reason, __STACKTRACE__)
        else
          :error
        end
    end
  end

  defp reconcile_due_in_batches_until_done(
         oban,
         steward,
         opts,
         acc \\ %{batch_count: 0, resource_count: 0}
       ) do
    case reconcile_batch(oban, steward, &Query.where_due/1, opts) do
      0 ->
        acc

      count ->
        acc = %{
          batch_count: acc.batch_count + 1,
          resource_count: acc.resource_count + count
        }

        reconcile_due_in_batches_until_done(oban, steward, opts, acc)
    end
  end

  # Reconciles a single resource in the calling process, for debugging. The resource is claimed
  # and released like in `reconcile_all_due/3`, but it's reconciled even when it's idle. Errors
  # are raised (after backing off the resource).
  @spec reconcile_one(module, Resource.t() | Resource.id()) :: {:ok, non_neg_integer}
  @spec reconcile_one(Oban.name(), module, Resource.t() | Resource.id()) ::
          {:ok, non_neg_integer}
  @spec reconcile_one(Oban.name(), module, Resource.t() | Resource.id(), keyword) ::
          {:ok, non_neg_integer}
  def reconcile_one(oban \\ Oban, controller, resource_or_id, opts \\ []) do
    validate_schema!(opts, reconciliation_error_backoff: :non_neg_integer)

    opts =
      Keyword.merge(
        [
          reconcile_batch_size: 1,
          reconciliation_error_backoff: @default_reconciliation_error_backoff,
          raise_errors: true
        ],
        opts
      )

    scope = &Query.where_resource(&1, controller, resource_or_id)

    {:ok, reconcile_batch(oban, controller.__steward__(), scope, opts)}
  end

  defp reconcile_batch(oban, steward, scope, opts) do
    case Locking.claim_batch(steward, scope, opts) do
      {0, []} ->
        0

      {count, batch} ->
        try do
          do_reconcile_batch(oban, steward, batch, opts)
        rescue
          # Errors of single resources are handled in `reconcile_resource/5`. Anything raised
          # here affects the whole batch (e.g. an unknown controller or a database error), so
          # the whole batch is rescheduled after the backoff, and the reconciliation run ends.
          e ->
            Locking.backoff_batch(steward, batch, opts)
            reraise e, __STACKTRACE__
        else
          _ -> Locking.release_batch(steward, batch)
        end

        count
    end
  end

  defp do_reconcile_batch(oban, steward, batch, opts) do
    existing_jobs = all_resource_jobs(oban, batch)

    {desired_jobs, existing_jobs} =
      Enum.reduce(batch, {[], []}, fn resource, {desired_acc, existing_acc} ->
        # Only pass resource's own jobs to spec/3.
        existing_jobs = Enum.filter(existing_jobs, &resource_job?(&1, resource))

        controller = controller_from_string!(resource.controller)

        case reconcile_resource(steward, controller, resource, existing_jobs, opts) do
          {:ok, desired_jobs} -> {desired_acc ++ desired_jobs, existing_acc ++ existing_jobs}
          :error -> {desired_acc, existing_acc}
        end
      end)

    plan = Plan.plan(desired_jobs, existing_jobs)

    execute(oban, plan)
  end

  defp reconcile_resource(steward, controller, resource, existing_jobs, opts) do
    meta = %{steward: steward, controller: controller, resource: resource}

    Telemetry.span([:reconciliation, :resource], meta, fn ->
      {{:ok, desired_resource_jobs_from_spec(controller, resource, existing_jobs)}, meta}
    end)
  rescue
    e ->
      Controller.reschedule_resource_after_reconciliation_error!(
        controller,
        resource,
        e,
        __STACKTRACE__,
        Keyword.fetch!(opts, :reconciliation_error_backoff)
      )

      if Keyword.fetch!(opts, :raise_errors) do
        reraise(e, __STACKTRACE__)
      else
        :error
      end
  end

  defp desired_resource_jobs_from_spec(controller, resource, existing_jobs) do
    if Resource.cancelled?(resource) do
      []
    else
      case controller.load(resource) do
        {:ok, loaded_object} ->
          controller.workers()
          |> Enum.reduce(Spec.new(), & &1.spec(&2, loaded_object, existing_jobs))
          |> Map.fetch!(:jobs)
          |> Enum.map(&Plan.desired(resource, &1))

        :cancel ->
          # Directly mark as cancelled (without schedule) as jobs will be cancelled within
          # the current run.
          Controller.mark_resource_cancelled!(controller, resource)
          []
      end
    end
  end

  defp execute(oban, actions) do
    insert_jobs(oban, for({:insert, changeset} <- actions, do: changeset))
    delete_jobs(oban, for({:delete, job} <- actions, do: job.id))
    for {:update, job, desired} <- actions, do: update_job!(oban, job, desired)

    :ok
  end

  # NOTE: Using Oban's "Basic" engine, the `insert_all/2` call below does *not* check
  #       unique attributes of the jobs, allowing for a raced (manual) insert from elsewhere.
  #       However, we deem this unlikely enough that the batched INSERT is still worth it.
  defp insert_jobs(_oban, []), do: :ok
  defp insert_jobs(oban, changesets), do: Oban.insert_all(oban, changesets)

  defp delete_jobs(_oban, []), do: :ok

  defp delete_jobs(oban, job_ids), do: delete_deletable_jobs(oban, job_ids)

  # Locks the job and recomputes the changes, as the job may have changed since it was read.
  defp update_job!(oban, %Oban.Job{} = job, desired) do
    conf = Oban.config(oban)

    {:ok, result} =
      Oban.Repo.transaction(conf, fn ->
        locked_job =
          Oban.Job
          |> where([j], j.id == ^job.id)
          |> lock("FOR UPDATE")
          |> then(&Oban.Repo.one(conf, &1))

        # The job may have been deleted, moved on (e.g. started executing) or changed outside
        # of Steward since it was read.
        with %Oban.Job{} <- locked_job,
             {:ok, changes} <- Plan.update(desired, locked_job) do
          Oban.update_job(oban, locked_job, changes)
        end
      end)

    # `nil` (job gone) and `:skip` (nothing to change) are fine.
    case result do
      {:error, reason} -> raise "failed to update job #{job.id}: #{inspect(reason)}"
      _ -> :ok
    end
  end
end
