# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestRepo.Migrations.CreateStewardResources do
  @moduledoc false

  use Ecto.Migration

  def up do
    Steward.Migrations.create_resources()
    Steward.Migrations.add_index_to_oban_jobs()
  end

  def down do
    Steward.Migrations.remove_index_from_oban_jobs()
    Steward.Migrations.drop_resources()
  end
end
