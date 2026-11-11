# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Spec do
  @moduledoc """
  The jobs a resource's workers desire, built by their `c:Steward.Worker.spec/3` callbacks.

  Steward reconciles a resource's jobs in Oban's queues against its spec, inserting, updating
  and deleting jobs as needed. Add jobs to the spec with `schedule/4`.
  """

  @moduledoc since: "0.1.0"

  @enforce_keys [:jobs]
  defstruct [:jobs]

  @type worker :: module
  @type args :: Oban.Job.args()
  # Always holds the `:steward_unique_key` option, as a hash, see `schedule/4`.
  @type job :: {worker, args, keyword}

  @type t :: %__MODULE__{jobs: [job]}

  @allowed_opts ~w[steward_unique_key scheduled_at queue priority max_attempts tags]a

  @doc false
  @spec new() :: t
  def new, do: %__MODULE__{jobs: []}

  @doc """
  Schedules a desired job into the resource's execution plan.

  Usually no need to call this directly, call your worker's private `schedule/3` helper instead.

  ## Options

    * `:steward_unique_key` - distinguishes multiple jobs of the same worker for a resource.
      Any term, hashed when scheduled. Uniqueness holds across all job states, forever. The
      hash has 32 bits, so collisions only become plausible with many thousands of keys for
      the same worker and resource.
    * `:scheduled_at` - when to run the job. Defaults to immediately.
    * `:queue`, `:priority`, `:max_attempts`, `:tags` - as in `Oban.Job.new/2`.

  Changes to these options are applied to existing jobs that are still `scheduled`, and
  omitting an option resets it to its default, e.g. a job no longer given `:scheduled_at` is
  rescheduled to run immediately. Steward keeps changes made to a job outside of Steward
  (e.g. through Oban Web) until the spec's desired value for that option changes.

  Steward controls uniqueness itself, so `:unique` and `:replace` raise an `ArgumentError`. So
  does `:schedule_in`, as it would push the job back on every reconciliation, and any other
  option not listed above.
  """
  @doc since: "0.1.0"
  @spec schedule(t, worker, args) :: t
  @spec schedule(t, worker, args, keyword) :: t
  def schedule(%__MODULE__{} = spec, worker, args, opts \\ []) do
    validate_opts!(worker, opts)

    # Always set, hashing `nil` without a key, so that jobs store a string either way.
    unique_key = Steward.Utils.hash(Keyword.get(opts, :steward_unique_key))
    opts = Keyword.put(opts, :steward_unique_key, unique_key)

    unique? =
      Enum.all?(spec.jobs, fn {existing_worker, _, existing_opts} ->
        existing_worker != worker or
          Keyword.fetch!(existing_opts, :steward_unique_key) != unique_key
      end)

    if not unique? do
      raise ArgumentError,
            """
            Job is not unique in the spec.

            HINT: Use the :steward_unique_key option to distinguish jobs from a single worker.
            """
    end

    %{spec | jobs: [{worker, args, opts} | spec.jobs]}
  end

  defp validate_opts!(worker, opts) do
    if Keyword.has_key?(opts, :unique) or Keyword.has_key?(opts, :replace) do
      raise ArgumentError,
            """
            Not allowed to specify :unique or :replace option on a Steward.Worker.
            """
    end

    if Keyword.has_key?(opts, :schedule_in) do
      raise ArgumentError,
            """
            Relative scheduling with :schedule_in is not allowed.
            """
    end

    case Keyword.keys(opts) -- @allowed_opts do
      [] ->
        :ok

      unsupported ->
        raise ArgumentError,
              """
              Unsupported options #{inspect(unsupported)} for #{inspect(worker)}.

              HINT: Supported options are #{inspect(@allowed_opts)}.
              """
    end
  end
end
