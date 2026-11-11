# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Migrations do
  @moduledoc """
  Migrations for Steward's database tables.

  Call `create_resources/1` and `drop_resources/1` from a migration in your application to
  create the resource table, and `add_index_to_oban_jobs/1` and `remove_index_from_oban_jobs/1`
  from another one to add the index Steward needs on Oban's `oban_jobs` table:

      defmodule MyApp.Repo.Migrations.CreateStewardResources do
        use Ecto.Migration

        def up, do: Steward.Migrations.create_resources()
        def down, do: Steward.Migrations.drop_resources()
      end

      defmodule MyApp.Repo.Migrations.AddStewardIndexToObanJobs do
        use Ecto.Migration

        @disable_ddl_transaction true
        @disable_migration_lock true

        def up, do: Steward.Migrations.add_index_to_oban_jobs(concurrently: true)
        def down, do: Steward.Migrations.remove_index_from_oban_jobs(concurrently: true)
      end
  """

  @moduledoc since: "0.1.0"

  use Ecto.Migration

  @oban_jobs_index "oban_jobs_steward_resource_index"

  @doc """
  Adds a table for Steward's resources.

  The table and prefix must match the `:table` and `:prefix` options of `Steward.Config`.

  ## Options

    * `:table` - table name, defaults to `steward_resources`
    * `:prefix` - prefix, defaults to the migration's prefix
  """
  @doc since: "0.1.0"
  @spec create_resources(keyword()) :: :ok
  def create_resources(opts \\ []) do
    table_name = Keyword.get(opts, :table, :steward_resources)
    prefix = Keyword.get(opts, :prefix, prefix())

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
    create(
      index(table_name, ["meta jsonb_path_ops"],
        name: "#{table_name}_meta_idx",
        using: :gin,
        prefix: prefix
      )
    )

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

  @doc """
  Rolls back Steward's resources table.

  ## Options

    * `:table` - table name, defaults to `steward_resources`
    * `:prefix` - prefix, defaults to the migration's prefix
  """
  @doc since: "0.1.0"
  @spec drop_resources(keyword()) :: :ok
  def drop_resources(opts \\ []) do
    table_name = Keyword.get(opts, :table, :steward_resources)
    prefix = Keyword.get(opts, :prefix, prefix())

    drop(table(table_name, prefix: prefix))

    :ok
  end

  @doc """
  Adds the index Steward needs to look up a resource's jobs to Oban's `oban_jobs` table.

  Oban's own GIN index on `meta` only serves `@>` containment queries and is too slow for
  Steward's lookups. Must run after Oban's migration created the table.

  ## Options

    * `:prefix` - prefix of the `oban_jobs` table, defaults to the migration's prefix
    * `:concurrently` - creates the index concurrently (requires `@disable_ddl_transaction` and
      `@disable_migration_lock`)
  """
  @doc since: "0.1.0"
  @spec add_index_to_oban_jobs(keyword()) :: :ok
  def add_index_to_oban_jobs(opts \\ []) do
    # Uniqueness is a safety net, see the note on Reconciliation.insert_jobs/2.
    create_if_not_exists(
      index(
        :oban_jobs,
        [
          "(meta->>'steward_controller')",
          "(meta->>'steward_resource_id')",
          :worker,
          "(meta->>'steward_unique_key')"
        ],
        name: @oban_jobs_index,
        where: """
        (meta->>'steward_controller') IS NOT NULL AND
        (meta->>'steward_resource_id') IS NOT NULL
        """,
        unique: true,
        prefix: Keyword.get(opts, :prefix, prefix()),
        concurrently: Keyword.get(opts, :concurrently, false)
      )
    )

    :ok
  end

  @doc """
  Removes the index added by `add_index_to_oban_jobs/1`. Accepts the same options.
  """
  @doc since: "0.1.0"
  @spec remove_index_from_oban_jobs(keyword()) :: :ok
  def remove_index_from_oban_jobs(opts \\ []) do
    drop_if_exists(
      index(:oban_jobs, [],
        name: @oban_jobs_index,
        prefix: Keyword.get(opts, :prefix, prefix()),
        concurrently: Keyword.get(opts, :concurrently, false)
      )
    )

    :ok
  end
end
