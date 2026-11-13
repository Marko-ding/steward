# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Oban do
  @moduledoc """
  Helper functions for dealing with Steward managed jobs.
  """

  alias Steward.Oban.Query
  alias Steward.Resource

  @pending_states ~w[available scheduled retryable]

  # _______________________________________________________________________________________
  # Public API

  @doc """
  Fetches all jobs for a given resource.
  """
  @doc since: "0.1.0"
  @spec all_resource_jobs(Resource.t() | [Resource.t()]) :: [Oban.Job.t()]
  @spec all_resource_jobs(Oban.name(), Resource.t() | [Resource.t()]) :: [Oban.Job.t()]
  def all_resource_jobs(oban \\ Oban, resource_or_resources)
  def all_resource_jobs(oban, %Resource{} = resource), do: all_resource_jobs(oban, [resource])
  def all_resource_jobs(oban, resources), do: Oban.all_jobs(oban, Query.resource_jobs(resources))

  @doc """
  Deletes all jobs for a given resource.

  If you wish to halt reconciliation for the resource, see `Steward.Controller.cancel_resource!/2`
  instead, and wait for the next reconciliation to delete pending resource jobs automatically.

  Steward then deletes the remaining jobs of cancelled resources after some time, see the
  `:prune_max_age` option of `Steward.Plugin`.
  """
  @doc since: "0.1.0"
  @spec delete_resource_jobs(Resource.t() | [Resource.t()]) :: {:ok, non_neg_integer()}
  @spec delete_resource_jobs(Oban.name(), Resource.t() | [Resource.t()]) ::
          {:ok, non_neg_integer()}
  def delete_resource_jobs(oban \\ Oban, resource_or_resources)

  def delete_resource_jobs(oban, %Resource{} = resource),
    do: delete_resource_jobs(oban, [resource])

  def delete_resource_jobs(oban, resources) do
    Oban.delete_all_jobs(oban, Query.resource_jobs(resources))
  end

  # _______________________________________________________________________________________
  # Reconciliation helpers

  @doc false
  @spec resource_job?(Oban.Job.t(), Resource.t()) :: boolean
  def resource_job?(%Oban.Job{meta: meta}, resource) do
    meta["steward_controller"] == resource.controller and
      meta["steward_resource_id"] == resource.id
  end

  @doc false
  @spec resource_pk_from_job!(Oban.Job.t()) :: {controller :: binary, Resource.id()}
  def resource_pk_from_job!(%Oban.Job{
        meta: %{"steward_controller" => controller, "steward_resource_id" => resource_id}
      }) do
    {controller, resource_id}
  end

  # Jobs store a hash of their unique key, as it can be an arbitrarily large term (see
  # `Steward.Spec.schedule/4`). Jobs without a key store the hash of `nil`.
  @doc false
  @spec unique_key_from_job!(Oban.Job.t()) :: String.t()
  def unique_key_from_job!(%Oban.Job{meta: meta}), do: meta["steward_unique_key"]

  # Returns whether a job may be deleted by the reconciliation, i.e. is pending.
  @doc false
  @spec deletable?(Oban.Job.t()) :: boolean
  def deletable?(%Oban.Job{state: state}), do: state in @pending_states

  # Deletes the jobs with the given ids that are still deletable, see `deletable?/1`. Jobs may
  # have moved on since they were read, e.g. completed, and are then kept.
  @doc false
  @spec delete_deletable_jobs(module, [pos_integer]) :: {:ok, non_neg_integer}
  def delete_deletable_jobs(oban, job_ids),
    do: Oban.delete_all_jobs(oban, Query.jobs_in_states(job_ids, @pending_states))

  # Returns the snapshot of the fields Steward last applied to the job, or `nil`.
  @doc false
  @spec applied_snapshot(Oban.Job.t()) :: map | nil
  def applied_snapshot(%Oban.Job{meta: meta}), do: meta["steward_applied"]

  # Stores the snapshot of the applied fields in the meta of a job changeset.
  @doc false
  @spec put_applied_snapshot(Ecto.Changeset.t(), map) :: Ecto.Changeset.t()
  def put_applied_snapshot(%Ecto.Changeset{} = changeset, snapshot),
    do: Ecto.Changeset.update_change(changeset, :meta, &Map.put(&1, :steward_applied, snapshot))

  # Returns the changes storing the snapshot of the applied fields in a job's meta, or `%{}`
  # if the job already carries it.
  @doc false
  @spec applied_snapshot_changes(Oban.Job.t(), map) :: %{optional(:meta) => map}
  def applied_snapshot_changes(%Oban.Job{meta: %{"steward_applied" => snapshot}}, snapshot),
    do: %{}

  def applied_snapshot_changes(%Oban.Job{meta: meta}, snapshot),
    do: %{meta: Map.put(meta, "steward_applied", snapshot)}

  # Builds a job changeset for insertion.
  @doc false
  @spec build_job_changeset(Resource.t(), module, map, keyword, String.t()) ::
          Ecto.Changeset.t()
  def build_job_changeset(%Resource{} = resource, worker, args, opts, unique_key)
      when is_binary(unique_key) do
    # The unique key is always a string, the hash of `nil` if not given (see
    # `Steward.Spec.schedule/4`). Oban's uniqueness check matches jobs by containment
    # (`meta @> ...`), so a job without the key would collide with the worker's jobs that have
    # one, and the index added by `Steward.Migrations.add_index_to_oban_jobs/1` treats `NULL`s
    # as distinct.
    meta = %{
      steward_controller: resource.controller,
      steward_resource_id: resource.id,
      steward_unique_key: unique_key
    }

    opts =
      opts
      |> Keyword.put(:meta, meta)
      |> Keyword.put(:unique,
        states: :all,
        period: :infinity,
        fields: [:worker, :meta],
        keys: [:steward_controller, :steward_resource_id, :steward_unique_key]
      )
      |> Keyword.put(:worker, worker)

    worker.new(args, opts)
  end
end
