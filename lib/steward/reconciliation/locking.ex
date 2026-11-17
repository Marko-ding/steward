# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Reconciliation.Locking do
  @moduledoc false

  import Ecto.Query
  import Steward.Utils, only: [controller_from_string!: 1]
  alias Steward.Resource

  # Claims up to `:reconcile_batch_size` due resources, moving them to `:reconciling`.
  # Resources locked by a concurrent claim are skipped.
  @spec claim_batch(module, keyword) :: {non_neg_integer, [Resource.t()]}
  def claim_batch(steward, opts) do
    %{repo: repo, table: table, prefix: prefix} = steward.__steward_config__()

    batch_size = Keyword.fetch!(opts, :reconcile_batch_size)
    now = DateTime.utc_now()

    scheduled_resources =
      {table, Resource}
      |> where([r], r.reconciliation_state == :scheduled)
      |> where([r], r.reconciliation_due_at <= ^now)
      |> limit(^batch_size)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([r], %{controller: r.controller, id: r.id})

    {table, Resource}
    |> join(:inner, [r], s in subquery(scheduled_resources),
      on: r.controller == s.controller and r.id == s.id
    )
    |> select([r], r)
    |> repo.update_all(
      [
        set: [
          reconciliation_due_at: nil,
          reconciliation_state: :reconciling,
          reconciliation_state_set_at: now,
          reconciliation_error: nil,
          updated_at: now
        ]
      ],
      prefix: prefix,
      returning: true
    )
  end

  # Releases claimed resources, scheduling them again or moving them to `:idle`.
  @spec release_batch(module, [Resource.t()]) :: {non_neg_integer, nil}
  def release_batch(steward, batch) do
    %{repo: repo, table: table, prefix: prefix} = steward.__steward_config__()

    now = DateTime.utc_now()

    resource_values =
      Enum.map(batch, fn %{controller: controller, id: id} = resource ->
        %{reconcile_interval: interval} =
          controller_from_string!(controller).__steward_controller_config__()

        due_at = if interval != :infinity, do: DateTime.add(now, interval, :millisecond)

        %{
          controller: controller,
          id: id,
          claimed_at: resource.reconciliation_state_set_at,
          periodic_due_at: due_at
        }
      end)

    {table, Resource}
    |> join(
      :inner,
      [r],
      v in values(resource_values, %{
        controller: :string,
        id: :binary_id,
        claimed_at: :utc_datetime_usec,
        periodic_due_at: :utc_datetime_usec
      }),
      on: r.controller == v.controller and r.id == v.id
    )
    |> where([r], r.reconciliation_state == :reconciling)
    # Skips resources rescued by the lifeline and claimed again since.
    |> where([r, v], r.reconciliation_state_set_at == v.claimed_at)
    |> update([r, v],
      set: [
        # Resources scheduled mid-reconciliation (see `Steward.Controller.schedule_resource!/2`)
        # keep their `reconciliation_due_at`. All others are scheduled for periodic
        # reconciliation, unless cancelled or their controller's `:reconcile_interval` is
        # `:infinity`. Resources without a due time become `:idle`.
        reconciliation_due_at:
          fragment(
            "COALESCE(?, CASE WHEN ? IS NULL THEN ? END)",
            r.reconciliation_due_at,
            r.cancelled_at,
            v.periodic_due_at
          ),
        reconciliation_state:
          fragment(
            """
            CASE WHEN COALESCE(?, CASE WHEN ? IS NULL THEN ? END) IS NULL
            THEN 'idle' ELSE 'scheduled' END
            """,
            r.reconciliation_due_at,
            r.cancelled_at,
            v.periodic_due_at
          ),
        reconciliation_state_set_at: ^now,
        updated_at: ^now
      ]
    )
    |> repo.update_all([], prefix: prefix)
  end

  # Reschedules claimed resources after `:reconciliation_error_backoff` milliseconds plus jitter.
  # The error isn't recorded on the resources, as it can't be attributed to any of them;
  # it's reported through telemetry instead.
  # Unlike `release_batch/2`, this doesn't resolve the resources' controllers, so it also works
  # when a controller no longer exists.
  @spec backoff_batch(module, [Resource.t()], keyword) :: {non_neg_integer, nil}
  def backoff_batch(steward, batch, opts) do
    %{repo: repo, table: table, prefix: prefix} = steward.__steward_config__()

    backoff = Keyword.fetch!(opts, :reconciliation_error_backoff)

    now = DateTime.utc_now()

    resource_values =
      Enum.map(batch, fn %{controller: controller, id: id} = resource ->
        jitter = :rand.uniform(div(backoff, 10) + 1) - 1

        %{
          controller: controller,
          id: id,
          claimed_at: resource.reconciliation_state_set_at,
          due_at: DateTime.add(now, backoff + jitter, :millisecond)
        }
      end)

    {table, Resource}
    |> join(
      :inner,
      [r],
      v in values(resource_values, %{
        controller: :string,
        id: :binary_id,
        claimed_at: :utc_datetime_usec,
        due_at: :utc_datetime_usec
      }),
      on: r.controller == v.controller and r.id == v.id
    )
    |> where([r], r.reconciliation_state == :reconciling)
    # Skips resources rescued by the lifeline and claimed again since.
    |> where([r, v], r.reconciliation_state_set_at == v.claimed_at)
    |> update([r, v],
      set: [
        reconciliation_due_at: v.due_at,
        reconciliation_state: :scheduled,
        reconciliation_state_set_at: ^now,
        updated_at: ^now
      ]
    )
    |> repo.update_all([], prefix: prefix)
  end
end
