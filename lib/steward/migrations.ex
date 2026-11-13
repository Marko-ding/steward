# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Migrations do
  @moduledoc """
  Migrations for Steward's database tables.

  Steward's resources table is versioned: `up/1` migrates it to the given version, `down/1`
  rolls it back. The version is stored as a comment on the table, so `up/1` only applies
  versions newer than the table's. The version is required, so that a migration does the same
  whichever Steward release runs it. Generate a migration in your application:

      defmodule MyApp.Repo.Migrations.AddSteward do
        use Ecto.Migration

        def up, do: Steward.Migrations.up(version: 1)
        def down, do: Steward.Migrations.down(version: 1)
      end

  Steward additionally benefits from an index on Oban's `oban_jobs` table for performant lookups
  of jobs it manages. Add it with `add_index_to_oban_jobs/1` and `remove_index_from_oban_jobs/1`
  from another migration, creating it concurrently on a large table:

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

  @initial_version 1
  @current_version 1

  @oban_jobs_index "oban_jobs_steward_resource_index"

  @doc """
  Migrates the resources table up to the given version.

  The table and prefix must match the `:table` and `:prefix` options of `Steward.Config`.

  ## Options

    * `:version` - the version to migrate to, between 1 and `current_version/0`. Required.
    * `:table` - table name, defaults to `"steward_resources"`
    * `:prefix` - prefix, defaults to `"public"`
    * `:index_meta` - whether to create a GIN index on the `:meta` column, which speeds up
      `Steward.Controller.list_resources_by_meta/2`. Disable it if you don't look up resources
      by meta, to save its storage and write overhead. Only applies when the table is created.
      Defaults to `true`.
  """
  @doc since: "0.1.0"
  @spec up(keyword) :: :ok
  def up(opts) do
    opts = with_defaults(opts)
    version = fetch_version!(opts)
    initial = migrated_version(opts)

    if initial < version do
      change(max(initial + 1, @initial_version)..version//1, :up, opts)
    end

    :ok
  end

  @doc """
  Rolls the resources table back to before the given version. Version 1 drops the table.

  ## Options

    * `:version` - the earliest version to roll back, between 1 and `current_version/0`.
      Required.
    * `:table` - table name, defaults to `"steward_resources"`
    * `:prefix` - prefix, defaults to `"public"`
  """
  @doc since: "0.1.0"
  @spec down(keyword) :: :ok
  def down(opts) do
    opts = with_defaults(opts)
    version = fetch_version!(opts)
    initial = migrated_version(opts)

    if initial >= version do
      change(initial..version//-1, :down, opts)
    end

    :ok
  end

  @doc """
  Returns the version the resources table is migrated to, or `0` if it doesn't exist.

  ## Options

    * `:repo` - the repo to query, defaults to the migration's repo
    * `:table` - table name, defaults to `"steward_resources"`
    * `:prefix` - prefix, defaults to `"public"`
  """
  @doc since: "0.1.0"
  @spec migrated_version(keyword) :: non_neg_integer
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts)
    repo = Keyword.get_lazy(opts, :repo, &repo/0)

    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = $1 AND pg_namespace.nspname = $2
    """

    case repo.query(query, [opts[:table], opts[:prefix]], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  @doc """
  Returns the latest version of the resources table.
  """
  @doc since: "0.1.0"
  @spec current_version() :: pos_integer
  def current_version, do: @current_version

  defp change(range, direction, opts) do
    for version <- range do
      pad = version |> Integer.to_string() |> String.pad_leading(2, "0")
      apply(Module.concat(__MODULE__, "V#{pad}"), direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  # Rolling back the initial version dropped the table.
  defp record_version(_opts, 0), do: :ok

  defp record_version(opts, version) do
    table = "#{inspect(opts[:prefix])}.#{inspect(opts[:table])}"
    execute("COMMENT ON TABLE #{table} IS '#{version}'")
  end

  defp fetch_version!(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when version in @initial_version..@current_version//1 ->
        version

      {:ok, version} ->
        raise ArgumentError,
              "expected :version to be between #{@initial_version} and #{@current_version}, " <>
                "got: #{inspect(version)}"

      :error ->
        raise ArgumentError, "missing required option :version"
    end
  end

  defp with_defaults(opts) do
    [table: "steward_resources", prefix: "public", index_meta: true]
    |> Keyword.merge(opts)
    |> Keyword.update!(:table, &to_string/1)
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
