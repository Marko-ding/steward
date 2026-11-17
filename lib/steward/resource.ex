# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Resource do
  @moduledoc """
  A resource object, the unit of reconciliation.

  A resource belongs to a controller (see `Steward.Controller`) and typically corresponds to
  a domain entity, e.g. an order. Steward reconciles each resource's jobs separately, against
  the spec its controller's workers compute for it.

  Create resources with `Steward.Controller.create_resource/3`, and manage them with the
  other functions in `Steward.Controller`.

  ## Fields

    * `:controller` - the name of the resource's controller module.
    * `:id` - the resource's UUID, unique per controller. Generated unless given on creation.
    * `:meta` - a map of arbitrary domain information, e.g. foreign keys, see
      `Steward.Controller.list_resources_by_meta/2`. Stored as JSON.
    * `:object` - virtual field holding the domain data loaded by
      `c:Steward.Controller.load/1`. Not persisted.
    * `:cancelled_at` - when the resource was cancelled, see
      `Steward.Controller.cancel_resource!/2`.
    * `:pruned_at` - when the jobs of the cancelled resource were deleted, see the
      `:prune_max_age` option of `Steward.Plugin`.
    * `:reconciliation_state` - `:idle`, `:scheduled` (due at `:reconciliation_due_at`) or
      `:reconciling`, set at `:reconciliation_state_set_at`.
    * `:reconciliation_error` - the error of the last failed reconciliation, if any. Cleared
      when the resource is reconciled again.

  Steward manages all fields but `:meta` and `:object`. Don't change them yourself.
  """

  @moduledoc since: "0.1.0"

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type id :: binary

  @primary_key false

  schema "steward_resources" do
    field(:controller, :string, primary_key: true)
    field(:id, Ecto.UUID, primary_key: true, autogenerate: true)
    field(:meta, :map, default: %{})

    field(:cancelled_at, :utc_datetime_usec)
    field(:pruned_at, :utc_datetime_usec)

    field(:reconciliation_due_at, :utc_datetime_usec)

    field(:reconciliation_state, Ecto.Enum,
      values: [:idle, :scheduled, :reconciling],
      default: :idle
    )

    field(:reconciliation_state_set_at, :utc_datetime_usec)
    field(:reconciliation_error, :string)

    # Domain data from `c:Steward.Controller.load/1`.
    field(:object, :any, virtual: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec create_changeset(t, map, map) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = resource, user_attrs, system_attrs) do
    now = DateTime.utc_now()

    resource
    |> cast(user_attrs, [:id, :meta])
    |> change(system_attrs)
    |> change(%{
      reconciliation_due_at: now,
      reconciliation_state: :scheduled,
      reconciliation_state_set_at: now
    })
    |> unique_constraint(:id, name: "#{Ecto.get_meta(resource, :source)}_pkey")
  end

  @doc """
  Returns whether the resource is cancelled, see `Steward.Controller.cancel_resource!/2`.
  """
  @doc since: "0.1.0"
  @spec cancelled?(t) :: boolean
  def cancelled?(%__MODULE__{} = resource), do: not is_nil(resource.cancelled_at)

  @doc """
  Returns whether the jobs of the cancelled resource were pruned, see the `:prune_max_age`
  option of `Steward.Plugin`.
  """
  @doc since: "0.1.0"
  @spec pruned?(t) :: boolean
  def pruned?(%__MODULE__{} = resource), do: not is_nil(resource.pruned_at)
end
