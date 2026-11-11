# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin.Lifeline do
  @moduledoc false

  # Rescues resources stuck in `:reconciling`, e.g. after a node crashed between claiming and
  # releasing them (see `Steward.Reconciliation.Locking`). Without it, such resources would
  # never be reconciled again, as only `:scheduled` resources are claimed.

  use GenServer
  import Ecto.Query
  alias Steward.Resource
  alias Steward.Telemetry

  @default_reconciliation_timeout :timer.hours(24)

  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    conf = Keyword.fetch!(opts, :conf)
    steward = Keyword.fetch!(opts, :steward)

    name =
      Keyword.get(opts, :name, Oban.Registry.via(conf.name, {:plugin, {steward, __MODULE__}}))

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    case Keyword.get(opts, :lifeline_reconciliation_timeout, @default_reconciliation_timeout) do
      :infinity -> :ignore
      _timeout -> {:ok, opts |> Map.new() |> schedule_poll()}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {:noreply, state |> rescue_all_stuck_if_leader() |> schedule_poll()}
  end

  defp rescue_all_stuck_if_leader(%{conf: conf, steward: steward} = state) do
    if Oban.Peer.leader?(conf) do
      meta = %{oban: conf.name, steward: steward}

      Telemetry.span([:lifeline, :rescue_all_stuck], meta, fn ->
        count =
          rescue_all_stuck(
            steward,
            state |> Map.take([:lifeline_reconciliation_timeout]) |> Enum.into([])
          )

        {count, %{rescued_count: count}, meta}
      end)
    end

    state
  end

  # Schedules resources reconciling for longer than `:lifeline_reconciliation_timeout` for
  # immediate reconciliation. Resources scheduled mid-reconciliation keep their due time.
  # Returns the number of rescued resources.
  #
  # A reconciliation that merely took longer than the timeout is not aborted. When it
  # finishes, releasing the resource is a no-op, as it's no longer `:reconciling` (see
  # `Steward.Reconciliation.Locking.release_batch/2`), and the resource is reconciled again.
  @spec rescue_all_stuck(module, keyword) :: non_neg_integer
  def rescue_all_stuck(steward, opts \\ []) do
    %{repo: repo, table: table, prefix: prefix} = steward.__steward_config__()
    timeout = Keyword.get(opts, :lifeline_reconciliation_timeout, @default_reconciliation_timeout)

    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -timeout, :millisecond)

    {count, _} =
      {table, Resource}
      |> where([r], r.reconciliation_state == :reconciling)
      |> where([r], r.reconciliation_state_set_at <= ^cutoff)
      |> update([r],
        set: [
          reconciliation_due_at:
            coalesce(r.reconciliation_due_at, type(^now, :utc_datetime_usec)),
          reconciliation_state: :scheduled,
          reconciliation_state_set_at: ^now,
          updated_at: ^now
        ]
      )
      |> repo.update_all([], prefix: prefix)

    count
  end

  defp schedule_poll(state) do
    lifeline_poll_interval = Map.get(state, :lifeline_poll_interval, 60_000)

    Process.send_after(self(), :poll, lifeline_poll_interval)

    state
  end
end
