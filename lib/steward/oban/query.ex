# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Oban.Query do
  @moduledoc false

  import Ecto.Query
  alias Steward.Resource

  # Query for all jobs of the given resources. Matches the `oban_jobs_steward_resource_index`
  # index added by `Steward.Migrations.add_index_to_oban_jobs/1`.
  @doc false
  @spec resource_jobs([Resource.t(), ...]) :: Ecto.Query.t()
  def resource_jobs([_ | _] = resources) do
    resource_pks = Enum.map(resources, &Map.take(&1, [:controller, :id]))

    from(j in Oban.Job,
      join: v in values(resource_pks, %{controller: :string, id: :string}),
      on:
        fragment("(?->>'steward_controller')", j.meta) == v.controller and
          fragment("(?->>'steward_resource_id')", j.meta) == v.id
    )
  end

  # Query for the jobs with the given ids that are in one of `states`.
  @doc false
  @spec jobs_in_states([pos_integer], [String.t()]) :: Ecto.Query.t()
  def jobs_in_states(job_ids, states) do
    where(Oban.Job, [j], j.id in ^job_ids and j.state in ^states)
  end
end
