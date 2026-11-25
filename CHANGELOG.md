## [Unreleased]

### Added

- `Steward.Controller.upsert_resource/3` creates a resource or schedules the existing one with
  the same id.

### Changed

- `c:Steward.Controller.load/1` returns `{:ok, object}` with arbitrary domain data instead
  of a resource with its `:object` field filled.

- `Steward.Plugin` polls every 30 seconds by default: `:reconcile_poll_interval` was `5_000`,
  `:lifeline_poll_interval` and `:prune_poll_interval` were `60_000`.

## [0.1.0] - 2026-11-17

Initial alpha release.
