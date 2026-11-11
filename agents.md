# Tests

Test files mirror the `lib/steward/` namespace under `test/steward/`:

`test/test_helper.exs` starts TestRepo, runs the migrations (down then up in auto mode so
DDL commits), switches to manual sandbox mode and starts `Steward.TestOban`, once per run.
`use Steward.DataCase` in a test module checks out/in a sandbox connection per test.
Shared helpers (`insert_resource/1`, `insert_job/2`, `resource_jobs/1`, `assert_between/3`,
...) live in `Steward.TestUtils`.
