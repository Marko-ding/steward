# SPDX-License-Identifier: Apache-2.0

defmodule Steward.IntegrationTest do
  # Runs an order's whole lifecycle through real controller and worker modules, triggering
  # reconciliation with `Steward.Testing.reconcile/2` and running jobs with `Oban.drain_queue/2`.

  use Steward.DataCase
  alias Steward.TestOban
  alias Steward.TestSteward

  defmodule Orders do
    # In-memory order store standing in for the application's domain data.

    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def get(id), do: Agent.get(__MODULE__, &Map.get(&1, id))
    def put(order), do: Agent.update(__MODULE__, &Map.put(&1, order.id, order))
    def update!(id, fun), do: Agent.update(__MODULE__, &Map.update!(&1, id, fun))
    def delete(id), do: Agent.update(__MODULE__, &Map.delete(&1, id))
  end

  defmodule OrderController do
    use Steward.Controller, steward: Steward.TestSteward

    @impl true
    def workers,
      do: [Steward.IntegrationTest.ReminderWorker, Steward.IntegrationTest.FulfillWorker]

    @impl true
    def load(resource) do
      case Orders.get(resource.id) do
        nil -> :cancel
        order -> {:ok, order}
      end
    end
  end

  defmodule ReminderWorker do
    # Reminds the customer to pay one day after placing an unpaid order.

    use Steward.Worker, queue: :default

    @impl Steward.Worker
    def spec(spec, order, _jobs) do
      if order.paid_at do
        spec
      else
        schedule(spec, %{}, scheduled_at: DateTime.add(order.placed_at, 1, :day))
      end
    end

    @impl Steward.Worker
    def perform(_job, order) do
      Orders.update!(order.id, &%{&1 | reminded?: true})
      :ok
    end
  end

  defmodule FulfillWorker do
    # Fulfills a paid order right away.

    use Steward.Worker, queue: :default

    @impl Steward.Worker
    def spec(spec, order, _jobs) do
      if order.paid_at && !order.fulfilled?, do: schedule(spec), else: spec
    end

    @impl Steward.Worker
    def perform(_job, order) do
      Orders.update!(order.id, &%{&1 | fulfilled?: true})
      :ok
    end
  end

  setup do
    start_supervised!(Orders)
    :ok
  end

  defp reconcile, do: Steward.Testing.reconcile(TestOban, TestSteward)
  defp drain, do: Oban.drain_queue(TestOban, queue: :default, with_scheduled: true)

  defp place_order do
    order = %{
      id: Ecto.UUID.generate(),
      placed_at: DateTime.utc_now(),
      paid_at: nil,
      reminded?: false,
      fulfilled?: false
    }

    Orders.put(order)
    {:ok, _resource} = OrderController.create_resource(%{id: order.id})
    order
  end

  defp pay_order(order) do
    {:ok, resource} = OrderController.get_resource(order.id)

    OrderController.process_resource(resource, fn _resource ->
      {true, Orders.update!(order.id, &%{&1 | paid_at: DateTime.utc_now()})}
    end)
  end

  test "schedules a reminder, replaces it with fulfillment once paid, then settles" do
    order = place_order()

    assert {:ok, 1} = reconcile()

    assert_enqueued(
      worker: ReminderWorker,
      scheduled_at: {DateTime.add(order.placed_at, 1, :day), delta: 1}
    )

    refute_enqueued(worker: FulfillWorker)

    pay_order(order)
    assert {:ok, 1} = reconcile()

    refute_enqueued(worker: ReminderWorker)
    assert_enqueued(worker: FulfillWorker)

    assert %{success: 1} = drain()
    assert %{fulfilled?: true, reminded?: false} = Orders.get(order.id)

    # The fulfillment job scheduled the order for reconciliation, which desires no more jobs.
    assert {:ok, 1} = reconcile()
    refute_enqueued(worker: ReminderWorker)
    refute_enqueued(worker: FulfillWorker)
    assert {:ok, 0} = reconcile()
  end

  test "reminds the customer of an unpaid order" do
    order = place_order()
    assert {:ok, 1} = reconcile()

    assert %{success: 1} = drain()
    assert %{reminded?: true, fulfilled?: false} = Orders.get(order.id)

    # The completed reminder isn't enqueued again.
    assert {:ok, 1} = reconcile()
    refute_enqueued(worker: ReminderWorker)
    assert {:ok, 0} = reconcile()
  end

  test "cancels the resource and deletes its pending jobs once the order is gone" do
    order = place_order()
    assert {:ok, 1} = reconcile()
    assert_enqueued(worker: ReminderWorker)

    Orders.delete(order.id)
    OrderController.schedule_resource!(order.id)
    assert {:ok, 1} = reconcile()

    refute_enqueued(worker: ReminderWorker)
    assert {:ok, resource} = OrderController.get_resource(order.id)
    assert Steward.Resource.cancelled?(resource)
    assert {:ok, 0} = reconcile()
  end
end
