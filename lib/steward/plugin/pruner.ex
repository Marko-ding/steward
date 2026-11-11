# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin.Pruner do
  @moduledoc false

  use GenServer
  import Ecto.Query
  import Steward.Oban, only: [delete_resource_jobs: 2]
  alias Steward.Resource
  alias Steward.Telemetry

  @default_prune_max_age :timer.hours(24 * 30)

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    steward = Keyword.fetch!(opts, :steward)

    name =
      Keyword.get(opts, :name, Oban.Registry.via(conf.name, {:plugin, {steward, __MODULE__}}))

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # A `:prune_max_age` of `:infinity` disables pruning.
  @impl GenServer
  def init(opts) do
    case Keyword.get(opts, :prune_max_age, @default_prune_max_age) do
      :infinity -> :ignore
      _max_age -> {:ok, opts |> Map.new() |> schedule_poll()}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {:noreply, state |> prune_all_expired() |> schedule_poll()}
  end

  defp prune_all_expired(%{conf: conf, steward: steward} = state) do
    if Oban.Peer.leader?(conf) do
      opts =
        state
        |> Map.take([:prune_batch_size, :prune_max_age])
        |> Enum.into([])

      meta = %{oban: conf.name, steward: steward}

      Telemetry.span([:pruner, :prune_all_expired], meta, fn ->
        count = prune_all_expired(conf.name, steward, opts)
        {count, %{pruned_count: count}, meta}
      end)
    end

    state
  end

  # Deletes all jobs of resources cancelled more than `:prune_max_age` milliseconds ago and marks
  # the resources as pruned. Processes resources in batches of `:prune_batch_size`.
  #
  # Jobs in `executing` state are not deleted (see `Oban.delete_all_jobs/2`), yet the resource is
  # marked as pruned regardless and won't be visited again. A job still executing at prune time
  # (i.e. `:prune_max_age` after its resource was cancelled) therefore remains in `oban_jobs`
  # after it finishes, until Oban's own pruning removes it, if configured.
  #
  # Returns the number of pruned resources.
  @spec prune_all_expired(module, module, keyword) :: non_neg_integer
  def prune_all_expired(oban, steward, opts \\ []) do
    prune_all_expired(oban, steward, opts, 0)
  end

  defp prune_all_expired(oban, steward, opts, acc) do
    case prune_batch(oban, steward, opts) do
      0 -> acc
      count -> prune_all_expired(oban, steward, opts, acc + count)
    end
  end

  # Marks up to `:prune_batch_size` resources cancelled more than `:prune_max_age` ago as
  # pruned and deletes their jobs. Returns the number of pruned resources.
  #
  # Both happen in one transaction, so that a crash in between can't leave the jobs of
  # resources marked pruned behind, as those aren't visited again. This assumes Steward and
  # Oban share their repo. The pruned resources stay locked until the transaction commits, so a
  # concurrent `Steward.Controller.resume_resource!/2` waits and then finds them pruned.
  defp prune_batch(oban, steward, opts) do
    %{repo: repo, table: table, prefix: prefix} = steward.__steward_config__()

    batch_size = Keyword.get(opts, :prune_batch_size, 500)
    max_age = Keyword.get(opts, :prune_max_age, @default_prune_max_age)
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -max_age, :millisecond)

    expired_resources =
      {table, Resource}
      |> where([r], not is_nil(r.cancelled_at) and is_nil(r.pruned_at))
      |> where([r], r.cancelled_at <= ^cutoff)
      |> limit(^batch_size)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([r], %{controller: r.controller, id: r.id})

    {:ok, count} =
      repo.transaction(fn ->
        {count, pruned} =
          {table, Resource}
          |> join(:inner, [r], e in subquery(expired_resources),
            on: r.controller == e.controller and r.id == e.id
          )
          |> update(set: [pruned_at: ^now, updated_at: ^now])
          |> select([r], %{controller: r.controller, id: r.id})
          |> repo.update_all([], prefix: prefix)

        if count > 0, do: delete_resource_jobs(oban, pruned)

        count
      end)

    count
  end

  defp schedule_poll(state) do
    prune_poll_interval = Map.get(state, :prune_poll_interval, 60_000)

    Process.send_after(self(), :poll, prune_poll_interval)

    state
  end
end
