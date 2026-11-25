# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Resource do
  @moduledoc """
  A resource object, the unit of reconciliation.

  A resource belongs to a controller (see `Steward.Controller`) and typically corresponds to
  a domain entity, e.g. an order. Steward reconciles each resource's jobs separately, against
  the spec its controller's workers compute for it.
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
