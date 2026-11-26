# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Controller.Query do
  @moduledoc false

  # Composable queries on a controller's resources. All queries carry the table and prefix of
  # the controller's Steward, so they can be run with its repo as is.

  import Ecto.Query
  import Steward.Utils, only: [controller_to_string!: 1]
  alias Steward.Resource

  # ---------------------------------------------------------------------------------------
  # Base queries

  @doc false
  @spec resources(module) :: Ecto.Query.t()
  def resources(controller) do
    %{table: table, prefix: prefix} = controller.__steward__().__steward_config__()

    from(r in {table, Resource}, where: r.controller == ^controller_to_string!(controller))
    |> put_query_prefix(prefix)
  end

  @doc false
  @spec resources(module, [Resource.id()]) :: Ecto.Query.t()
  def resources(controller, resource_ids) when is_list(resource_ids) do
    where(resources(controller), [r], r.id in ^resource_ids)
  end

  @doc false
  @spec resource(module, Resource.t() | Resource.id()) :: Ecto.Query.t()
  def resource(controller, resource_or_id) do
    where(resources(controller), [r], r.id == ^resource_id(resource_or_id))
  end

  # The resources of `controller` whose meta contains `meta`, see
  # `Steward.Controller.list_resources_by_meta/2`.
  @doc false
  @spec resources_by_meta(module, map) :: Ecto.Query.t()
  def resources_by_meta(controller, meta) when is_map(meta) do
    where(resources(controller), [r], fragment("? @> ?", r.meta, type(^meta, :map)))
  end

  # ---------------------------------------------------------------------------------------
  # Modifier queries

  @doc false
  @spec where_resource(Ecto.Query.t(), module, Resource.t() | Resource.id()) :: Ecto.Query.t()
  def where_resource(query, controller, resource_or_id) do
    where(
      query,
      [r],
      r.controller == ^controller_to_string!(controller) and r.id == ^resource_id(resource_or_id)
    )
  end

  @doc false
  @spec where_due(Ecto.Query.t()) :: Ecto.Query.t()
  def where_due(query) do
    query
    |> where([r], r.reconciliation_state == :scheduled)
    |> where([r], r.reconciliation_due_at <= ^DateTime.utc_now())
  end

  # ---------------------------------------------------------------------------------------
  # Update queries

  # Update that schedules the queried resources for reconciliation at `due_at`, defaulting to
  # `now`. Resources that are reconciling stay so (and keep their state timestamp): the due
  # time makes their release schedule them again.
  @doc false
  @spec schedule(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  @spec schedule(Ecto.Queryable.t(), DateTime.t(), DateTime.t() | nil) :: Ecto.Query.t()
  def schedule(query, now, due_at \\ nil) do
    update(query, [r],
      set: [
        reconciliation_due_at: type(^(due_at || now), :utc_datetime_usec),
        reconciliation_state:
          fragment(
            "CASE WHEN ? = 'reconciling' THEN ? ELSE 'scheduled' END",
            r.reconciliation_state,
            r.reconciliation_state
          ),
        reconciliation_state_set_at:
          fragment(
            "CASE WHEN ? = 'reconciling' THEN ? ELSE ? END",
            r.reconciliation_state,
            r.reconciliation_state_set_at,
            type(^now, :utc_datetime_usec)
          )
      ]
    )
  end

  # Update that marks the queried resources cancelled at `now`, unless they already are.
  @doc false
  @spec cancel(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def cancel(query, now) do
    update(query, [r],
      set: [cancelled_at: coalesce(r.cancelled_at, type(^now, :utc_datetime_usec))]
    )
  end

  # Update that stores the formatted error of a failed reconciliation on the queried resources.
  @doc false
  @spec record_reconciliation_error(Ecto.Queryable.t(), Exception.t(), Exception.stacktrace()) ::
          Ecto.Query.t()
  def record_reconciliation_error(query, exception, stacktrace) do
    update(query,
      set: [reconciliation_error: ^Exception.format(:error, exception, stacktrace)]
    )
  end

  # Update that sets `updated_at` of the queried resources to `now`.
  @doc false
  @spec touch(Ecto.Queryable.t(), DateTime.t()) :: Ecto.Query.t()
  def touch(query, now) do
    update(query, set: [updated_at: type(^now, :utc_datetime_usec)])
  end

  # Update that clears the cancellation of the queried resources.
  @doc false
  @spec resume(Ecto.Queryable.t()) :: Ecto.Query.t()
  def resume(query) do
    update(query, set: [cancelled_at: nil])
  end

  defp resource_id(%Resource{id: id}), do: id
  defp resource_id(id) when is_binary(id), do: id
end
