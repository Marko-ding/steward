# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Migrations.V01 do
  @moduledoc false

  # Creates the resources table.

  use Ecto.Migration

  @spec up(keyword) :: :ok
  def up(opts) do
    table_name = Keyword.fetch!(opts, :table)
    prefix = Keyword.fetch!(opts, :prefix)

    create table(table_name, primary_key: false, prefix: prefix) do
      add(:controller, :string, primary_key: true, null: false)
      add(:id, :binary_id, primary_key: true, null: false)
      add(:meta, :jsonb, null: false, default: "{}")
      add(:cancelled_at, :utc_datetime_usec)
      add(:pruned_at, :utc_datetime_usec)

      add(:reconciliation_due_at, :utc_datetime_usec)
      add(:reconciliation_state, :string, null: false, default: "idle")
      add(:reconciliation_state_set_at, :utc_datetime_usec)
      add(:reconciliation_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(table_name, :reconciliation_state_check,
        check: "reconciliation_state IN ('idle', 'scheduled', 'reconciling')",
        prefix: prefix
      )
    )

    # `jsonb_path_ops` only supports containment (`@>`), which is all
    # `Steward.Controller.list_resources_by_meta/2` needs, and is smaller and faster than the
    # default `jsonb_ops`.
    if Keyword.fetch!(opts, :index_meta) do
      create(
        index(table_name, ["meta jsonb_path_ops"],
          name: "#{table_name}_meta_idx",
          using: :gin,
          prefix: prefix
        )
      )
    end

    create(
      index(table_name, [:reconciliation_due_at],
        name: "#{table_name}_due_idx",
        where: "reconciliation_state = 'scheduled'",
        prefix: prefix
      )
    )

    create(
      index(table_name, [:cancelled_at],
        name: "#{table_name}_prune_idx",
        where: "cancelled_at IS NOT NULL AND pruned_at IS NULL",
        prefix: prefix
      )
    )

    create(
      index(table_name, [:reconciliation_state_set_at],
        name: "#{table_name}_reconciling_idx",
        where: "reconciliation_state = 'reconciling'",
        prefix: prefix
      )
    )

    :ok
  end

  @spec down(keyword) :: :ok
  def down(opts) do
    drop(table(Keyword.fetch!(opts, :table), prefix: Keyword.fetch!(opts, :prefix)))

    :ok
  end
end
