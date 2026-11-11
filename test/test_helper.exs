# SPDX-License-Identifier: Apache-2.0

alias Ecto.Adapters.SQL.Sandbox
alias Steward.TestRepo

migrations = [
  {20_261_101_000_000, TestRepo.Migrations.CreateObanJobs},
  {20_261_101_000_001, TestRepo.Migrations.CreateStewardResources}
]

{:ok, _} = TestRepo.start_link()

# Migrates in auto mode so that the DDL commits, then switches to per-test sandboxes.
Sandbox.mode(TestRepo, :auto)
Ecto.Migrator.run(TestRepo, migrations, :down, all: true, log: false)
Ecto.Migrator.run(TestRepo, migrations, :up, all: true, log: false)
Sandbox.mode(TestRepo, :manual)

{:ok, _} =
  Oban.start_link(
    name: Steward.TestOban,
    repo: TestRepo,
    engine: Oban.Engines.Basic,
    queues: [default: 1],
    testing: :manual
  )

ExUnit.start()
