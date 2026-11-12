# SPDX-License-Identifier: Apache-2.0

defmodule Steward.MigrationsTest do
  use Steward.DataCase
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Steward.Migrations
  alias Steward.TestRepo

  @table "steward_resources_migrations_test"

  defmodule Migration do
    use Ecto.Migration

    @table "steward_resources_migrations_test"

    def up, do: Migrations.up(version: 1, table: @table)
    def down, do: Migrations.down(version: 1, table: @table)
  end

  # Ecto's migrator doesn't run the same module twice.
  defmodule MigrationAgain do
    use Ecto.Migration

    def up, do: Migration.up()
    def down, do: Migration.down()
  end

  defmodule MigrationWithoutMetaIndex do
    use Ecto.Migration

    @table "steward_resources_migrations_test"

    def up, do: Migrations.up(version: 1, table: @table, index_meta: false)
    def down, do: Migrations.down(version: 1, table: @table)
  end

  setup do
    # Ecto's migrator runs migrations in another process.
    Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp migrated_version, do: Migrations.migrated_version(repo: TestRepo, table: @table)

  defp meta_index? do
    TestRepo.exists?(
      from(i in "pg_indexes", where: i.indexname == ^"#{@table}_meta_idx", select: 1)
    )
  end

  # By default, both versions migrate to the latest version: the second is a no-op on the way
  # up, and the first is one on the way down, as the second already dropped the table.
  defp migrate(direction, migrations \\ [{1, Migration}, {2, MigrationAgain}]) do
    Ecto.Migrator.run(TestRepo, migrations, direction,
      all: true,
      log: false,
      # The lock holds a second connection, which the shared sandbox doesn't provide.
      migration_lock: false
    )
  end

  test "the test suite's table is migrated to the current version" do
    assert Migrations.migrated_version(repo: TestRepo) == Migrations.current_version()
  end

  test "migrates the table up and down, recording its version" do
    assert migrated_version() == 0

    migrate(:up)
    assert migrated_version() == Migrations.current_version()
    assert meta_index?()

    TestRepo.query!("""
    INSERT INTO #{@table} (controller, id, inserted_at, updated_at)
    VALUES ('C', gen_random_uuid(), now(), now())
    """)

    migrate(:down)
    assert migrated_version() == 0
  end

  test "skips the meta index with index_meta: false" do
    migrate(:up, [{1, MigrationWithoutMetaIndex}])

    assert migrated_version() == Migrations.current_version()
    refute meta_index?()
  end

  for fun <- [:up, :down] do
    test "#{fun}/1 requires a valid version" do
      assert_raise ArgumentError, "missing required option :version", fn ->
        Migrations.unquote(fun)(table: @table)
      end

      for version <- [0, Migrations.current_version() + 1, "1"] do
        assert_raise ArgumentError, ~r/expected :version to be between 1 and/, fn ->
          Migrations.unquote(fun)(version: version, table: @table)
        end
      end
    end
  end
end
