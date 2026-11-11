# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestRepo.Migrations.CreateObanJobs do
  @moduledoc false

  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end
