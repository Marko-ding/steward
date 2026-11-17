# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Testing do
  @moduledoc """
  Helpers for testing applications using Steward.

  Oban doesn't run plugins in its `:manual` and `:inline` testing modes, so Steward's
  reconciliation loop is never triggered in your tests. Use `reconcile/2` to run it
  synchronously instead.

  ## Usage

  #{Steward.Utils.extract_from_readme("testing-example")}

  Combined with `Oban.drain_queue/2`, you can run a resource's whole lifecycle: performed jobs
  schedule their resource for reconciliation again, which the next `reconcile/2` picks up.

      {:ok, _} = Steward.Testing.reconcile(MyApp.Oban, MyApp.Steward)
      Oban.drain_queue(queue: :default, with_scheduled: true)

      # The order's job succeeded and scheduled the order for reconciliation again.
      assert {:ok, 1} = Steward.Testing.reconcile(MyApp.Oban, MyApp.Steward)
  """

  @moduledoc since: "0.1.0"

  alias Steward.Reconciliation

  @doc """
  Reconciles all resources of `steward` that are due, in the calling process.

  Resources are due after creation, after `Steward.Controller.schedule_resource!/2`, after one
  of their jobs ran, and when their `:reconcile_interval` elapsed. Resources scheduled during
  the reconciliation are reconciled in the same call.

  Unlike Steward's plugin, this function doesn't rescue errors: when a resource's
  `c:Steward.Controller.load/1` or `c:Steward.Worker.spec/3` raises, or the reconciliation
  fails as a whole, the error is raised in the calling process.

  Returns `{:ok, resource_count}`, the number of reconciled resources.
  """
  @doc since: "0.1.0"
  @spec reconcile(module) :: {:ok, non_neg_integer}
  @spec reconcile(Oban.name(), module) :: {:ok, non_neg_integer}
  def reconcile(oban \\ Oban, steward) do
    Reconciliation.reconcile_all_due(oban, steward, raise_errors: true)
  end
end
