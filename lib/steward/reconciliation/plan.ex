# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Reconciliation.Plan do
  @moduledoc false

  # Pure part of the reconciliation: desired jobs (from the spec) are normalized to the form
  # of existing jobs (from Oban), then `plan/2` decides which jobs to insert, delete and
  # update. Side effects are left to `Steward.Reconciliation`.
  #
  # ## Changes made outside of Steward
  #
  # Jobs carry a snapshot of the fields Steward last applied (see `Steward.Oban`).
  # Updates compare three versions of each field, similar to `kubectl apply`:
  #
  #   * desired - computed by the spec in this reconciliation
  #   * applied - last written by Steward
  #   * live - currently in the database
  #
  # A field whose live value differs from the applied one was changed by someone else (e.g.
  # rescheduled through Oban Web, or snoozed) and is left alone, until the spec's desired
  # value changes.

  import Steward.Oban,
    only: [
      applied_snapshot: 1,
      applied_snapshot_changes: 2,
      build_job_changeset: 5,
      deletable?: 1,
      put_applied_snapshot: 2,
      resource_pk_from_job!: 1,
      unique_key_from_job!: 1
    ]

  import Steward.Utils, only: [hash: 1, json_roundtrip!: 1]

  alias Steward.Resource

  # Identifies a job of a resource across reconciliations, see `c:Steward.Worker.spec/3`.
  @type key ::
          {controller :: String.t(), Resource.id(), worker :: String.t(),
           unique_key_hash :: String.t()}

  # Reconciled job fields, in the form Oban returns them from the database.
  @type fields :: %{optional(atom) => term}

  # Reconciled fields in the form stored in the job's meta, see the module comment.
  @type snapshot :: %{optional(String.t()) => term}

  # A job as desired by the spec, see `desired/2`.
  #
  # `fields` only holds the fields the spec sets: fields left to their database default
  # (e.g. `priority`) or to Oban (e.g. `scheduled_at`) are not reconciled, unless Steward
  # applied them before, see `update/3`.
  @type desired :: %{
          key: key,
          changeset: Ecto.Changeset.t(),
          fields: fields,
          snapshot: snapshot
        }

  @type action ::
          {:insert, Ecto.Changeset.t()}
          | {:delete, Oban.Job.t()}
          | {:update, Oban.Job.t(), desired}

  @fields ~w[scheduled_at args max_attempts priority queue tags]a

  @scheduled_at_tolerance_ms :timer.seconds(10)

  @spec desired(Resource.t(), Steward.Spec.job()) :: desired
  def desired(%Resource{} = resource, {worker, args, opts}) do
    {unique_key, opts} = Keyword.pop!(opts, :steward_unique_key)
    changeset = build_job_changeset(resource, worker, args, opts, unique_key)

    if not changeset.valid? do
      raise ArgumentError,
            "invalid job scheduled by #{inspect(worker)}: #{inspect(changeset.errors)}"
    end

    # Args are stored as JSON, so compare them the way they come back from the database.
    fields =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.take(@fields)
      |> Map.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.update!(:args, &json_roundtrip!/1)

    snapshot = snapshot(fields)

    %{
      key: {resource.controller, resource.id, Oban.Worker.to_string(worker), unique_key},
      changeset: put_applied_snapshot(changeset, snapshot),
      fields: fields,
      snapshot: snapshot
    }
  end

  @spec key(Oban.Job.t()) :: key
  def key(%Oban.Job{} = job) do
    {controller, resource_id} = resource_pk_from_job!(job)
    {controller, resource_id, job.worker, unique_key_from_job!(job)}
  end

  # Stored in the job's meta, hence in JSON form. Args are only stored as a hash, to avoid
  # duplicating potentially large values.
  defp snapshot(fields), do: fields |> Map.update!(:args, &hash/1) |> json_roundtrip!()

  # Matches desired and existing jobs by key and returns the actions to apply.
  #
  #   * Desired jobs that don't exist are inserted.
  #   * Existing jobs that aren't desired are deleted, if pending.
  #   * Existing jobs that are desired are updated, see `update/2`.
  @spec plan([desired], [Oban.Job.t()]) :: [action]
  def plan(desired, jobs) do
    desired_by_key = Map.new(desired, &{&1.key, &1})
    jobs_by_key = Map.new(jobs, &{key(&1), &1})

    inserts =
      for {key, desired} <- desired_by_key,
          not Map.has_key?(jobs_by_key, key),
          do: {:insert, desired.changeset}

    deletes =
      for {key, job} <- jobs_by_key,
          not Map.has_key?(desired_by_key, key),
          deletable?(job),
          do: {:delete, job}

    updates =
      for {key, job} <- jobs_by_key,
          {:ok, desired} <- [Map.fetch(desired_by_key, key)],
          match?({:ok, _}, update(desired, job)),
          do: {:update, job, desired}

    inserts ++ deletes ++ updates
  end

  # Returns the changes to apply to an existing job, or `:skip`.
  #
  # Jobs are only updated when scheduled. Fields changed outside of
  # Steward are left alone, unless the desired value changed as well (see module comment).
  # Fields Steward applied before but the spec no longer sets are reset to their defaults,
  # e.g. `scheduled_at` to `now`. The changes include the job's meta with the new snapshot,
  # if it changed.
  @spec update(desired, Oban.Job.t()) :: {:ok, fields} | :skip
  @spec update(desired, Oban.Job.t(), DateTime.t()) :: {:ok, fields} | :skip
  def update(desired, job, now \\ DateTime.utc_now())

  def update(desired, %Oban.Job{state: "scheduled"} = job, now) do
    live_fields = Map.take(job, @fields)
    live = snapshot(live_fields)
    applied = applied_snapshot(job) || %{}

    changes =
      for {field, value} <- desired_fields(desired, applied, now),
          not same?(field, value, Map.fetch!(live_fields, field)),
          owned?(Atom.to_string(field), desired.snapshot, applied, live),
          into: applied_snapshot_changes(job, desired.snapshot),
          do: {field, value}

    if changes == %{}, do: :skip, else: {:ok, changes}
  end

  def update(_desired, %Oban.Job{}, _now), do: :skip

  # The desired fields, plus the defaults of fields that the applied snapshot holds but the
  # spec no longer sets. As the desired snapshot lacks such a field, Steward owns it, and
  # the new snapshot stops tracking it once applied.
  defp desired_fields(desired, applied, now) do
    for {field, default} <- unset_defaults(now),
        Map.has_key?(applied, Atom.to_string(field)),
        not Map.has_key?(desired.fields, field),
        into: desired.fields,
        do: {field, default}
  end

  # Values of the optional job fields when not set, see `Oban.Job.new/2`.
  defp unset_defaults(now), do: %{scheduled_at: now, priority: 0, tags: []}

  # Steward owns a field unless it was changed outside of Steward, and the spec still desires
  # the value Steward applied before. Fields the snapshot lacks (or jobs without snapshot) are
  # always owned.
  defp owned?(key, desired, applied, live),
    do: applied[key] == live[key] or applied[key] != desired[key]

  defp same?(:scheduled_at, desired, existing) do
    abs(DateTime.diff(desired, existing, :millisecond)) <= @scheduled_at_tolerance_ms
  end

  defp same?(_field, desired, existing), do: desired == existing
end
