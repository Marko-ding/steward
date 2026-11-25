# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Worker do
  @moduledoc """
  A wrapper around `Oban.Worker` integrating it with Steward's reconciliation engine.

  ## Using this module

  #{Steward.Utils.extract_from_readme("worker-example")}
  """

  @moduledoc since: "0.1.0"

  import Steward.Oban, only: [resource_pk_from_job!: 1]
  import Steward.Utils, only: [controller_from_string!: 1]
  alias Steward.Controller

  @doc """
  Called as part of the resource reconciliation to calculate the desired execution plan.

  Receives the object loaded by `c:Steward.Controller.load/1` and the resource's existing jobs.

  Callback implementation must be pure and deterministic. Repeated runs of the reconciliation
  should result in the same job schedule, hence the implementation must schedule the same set
  of jobs in every run as long as application state hasn't changed.

  The reconciliation engine consolidates the desired execution plan with jobs in Oban's queues.

  ## Scheduling jobs

  When your worker's preconditions are fulfilled, you can enqueue a job for immediate execution.

      schedule(spec, %{some: :args})

  The `:scheduled_at` option schedules a job into the future. To avoid "pushing"
  the job further into the future in repeated reconciliation runs, Oban's `:schedule_in`
  convenience option is not allowed.

      schedule(spec, %{some: :args}, scheduled_at: tomorrow)

  ## Job uniqueness

  In order to reconcile the desired job in the spec and actual jobs in Oban's queues,
  Steward needs to be able to uniquely identify each job it manages. The reconciliation
  process identifies jobs based on their worker, controller, and the id of the given
  `Steward.Resource`, meaning a worker can only enqueue a single job per resource by default.

  If you wish to enqueue multiple jobs from a single worker, the `:steward_unique_key` option
  distinguishes them by an arbitrary value.

      schedule(spec, %{some: :args}, steward_unique_key: my_job_id)

  Steward tries its best to ensure job uniqueness by controlling the job's `:unique` and
  `:replace` options. Passing either to `schedule/3` will raise an `ArgumentError`. Uniqueness
  holds over all job states (including `:completed`) for an infinite amount of time.

  #{Steward.Utils.extract_from_readme("pruner-warning")}

  > #### Batched inserts {: .info}
  >
  > Also note that Steward uses `Oban.insert_all` to insert jobs in a batch, which when
  > combined with Oban's `Basic` engine does not verify uniqueness constraints. However,
  > as Steward's reconciler checks uniqueness within a spec, the only risk of non-unique
  > jobs is manual inserts of duplicates while a resource is being reconciled.

  ## Changes outside of Steward

  Scheduled jobs may be changed outside of Steward, e.g. rescheduled through Oban Web.
  Steward keeps such changes per field until the desired value for that field changes,
  i.e. until the spec asks for something new.
  """
  @doc since: "0.1.0"
  @callback spec(Steward.Spec.t(), Steward.Controller.object(), [Oban.Job.t()]) ::
              Steward.Spec.t()

  @doc """
  Callback replacing `c:Oban.Worker.perform/1` in your workers.

  `Steward.Worker` implements the default `c:Oban.Worker.perform/1`. It loads the resource's
  object by calling `c:Steward.Controller.load/1` on its controller and passes the loaded object as the second
  argument to `c:Steward.Worker.perform/2`. Afterwards, it schedules the resource for
  reconciliation if the job is about to enter a terminal state, i.e. it succeeded, was
  discarded or cancelled, or failed its last attempt.

  ## Terminal states outside of `perform/2`

  Reconciliation is only scheduled when `perform/2` returns or raises. Jobs entering a
  terminal state by other means don't trigger it, e.g. jobs

    * cancelled with `Oban.cancel_job/2` or through Oban Web,
    * killed after exceeding their `c:Oban.Worker.timeout/1` in their last attempt,
    * or discarded by Oban's lifeline after their node crashed during their last attempt.

  Their resource isn't reconciled until it's scheduled otherwise. Use the `:reconcile_interval`
  option of `Steward.Controller` as a safety net, or call
  `Steward.Controller.schedule_resource!/2` when you cancel jobs yourself.
  """
  @doc since: "0.1.0"
  @callback perform(Oban.Job.t(), Steward.Controller.object()) :: Oban.Worker.result()

  defmacro __using__(opts) do
    validate_no_unique!(opts)

    quote do
      use Oban.Worker, unquote(opts)
      alias Steward.Spec

      @behaviour Steward.Worker

      @impl Oban.Worker
      def perform(job), do: Steward.Worker.perform(job)

      defp schedule(spec, args \\ %{}, opts \\ []),
        do: Spec.schedule(spec, __MODULE__, args, opts)
    end
  end

  defp validate_no_unique!(opts) do
    if Keyword.has_key?(opts, :unique) or Keyword.has_key?(opts, :replace) do
      raise ArgumentError,
            """
            Not allowed to specify :unique or :replace option on a Steward.Worker.
            """
    end
  end

  @doc false
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(job) do
    {controller, resource_id} = resource_pk_from_job!(job)
    controller = controller_from_string!(controller)

    case Controller.get_resource(controller, resource_id) do
      {:ok, resource} ->
        result =
          Controller.process_resource(controller, resource, &process_job(job, &1),
            schedule_on_error: not_retryable?(job)
          )

        if result == :cancelled do
          {:cancel, :resource_cancelled}
        else
          result
        end

      {:error, :not_found} ->
        {:cancel, :resource_not_found}
    end
  end

  defp process_job(job, resource) do
    {:ok, worker} = Oban.Worker.from_string(job.worker)

    case worker.perform(job, resource) do
      key when key in ~w[ok discard]a -> {true, key}
      {key, _} = result when key in ~w[ok discard cancel]a -> {true, result}
      any_error_result -> {not_retryable?(job), any_error_result}
    end
  end

  defp not_retryable?(job), do: job.attempt >= job.max_attempts
end
