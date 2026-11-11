# SPDX-License-Identifier: Apache-2.0

import Config

if config_env() == :test do
  # Set to :debug to see SQL logs.
  config :logger, level: :info

  config :steward, Steward.TestRepo,
    database: "steward_test",
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 5,
    priv: "test/support/test_repo"

  config :steward, ecto_repos: [Steward.TestRepo]
end
