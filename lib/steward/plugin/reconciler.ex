# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin.Reconciler do
  @moduledoc false

  use GenServer
  alias Steward.Reconciliation

  # Upper bound for the poll delay while reconciliation runs keep failing.
  @max_error_poll_interval :timer.minutes(10)

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
    state =
      opts
      |> Map.new()
      |> Map.put_new(:reconcile_poll_interval, 30_000)
      |> Map.put(:attempt, 0)

    {:ok, schedule_poll(state)}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {:noreply, reconcile_all_due(state)}
  end

  defp reconcile_all_due(%{conf: conf, steward: steward} = state) do
    attempt =
      if Oban.Peer.leader?(conf) do
        opts =
          state
          |> Map.take([:reconcile_batch_size, :reconciliation_error_backoff])
          |> Enum.into([])

        case Reconciliation.reconcile_all_due(conf.name, steward, opts) do
          {:ok, _resource_count} -> 0
          :error -> state.attempt + 1
        end
      else
        0
      end

    schedule_poll(%{state | attempt: attempt})
  end

  # Doubles the poll delay after a failed run, capped at `@max_error_poll_interval` (or the
  # regular poll interval, if that is longer).
  defp schedule_poll(%{attempt: attempt, reconcile_poll_interval: interval} = state) do
    # Bounding the exponent keeps the delay computation cheap during long outages; the
    # delay hits the cap long before that.
    backoff = interval * Integer.pow(2, min(attempt, 32))
    delay = max(interval, min(backoff, @max_error_poll_interval))

    Process.send_after(self(), :poll, delay)

    state
  end
end
