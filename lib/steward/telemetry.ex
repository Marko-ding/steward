# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Telemetry do
  @moduledoc """
  Telemetry events emitted by Steward.

  ## Reconciliation

    * `[:steward, :reconciliation, :start | :stop | :exception]` - a reconciliation run,
      which reconciles all due resources in batches. Metadata: `:oban`, `:steward`.
      `:stop` carries `:batch_count` and `:resource_count` measurements. An `:exception`
      event means a whole batch failed (e.g. a resource's controller no longer exists,
      or a database error).

    * `[:steward, :reconciliation, :resource, :start | :stop | :exception]` - a single
      resource, i.e. its `c:Steward.Controller.load/1` and its workers'
      `c:Steward.Worker.spec/3` calls. Metadata: `:steward`, `:controller`, `:resource`.
      An `:exception` event means the resource's reconciliation failed and was rescheduled
      after the `:reconciliation_error_backoff`; the error is also stored on the resource.

  ## Lifeline

    * `[:steward, :lifeline, :rescue_all_stuck, :start | :stop | :exception]` - a lifeline run,
      which reschedules resources stuck in reconciliation for longer than the
      `:lifeline_reconciliation_timeout` (see `Steward.Plugin`). Metadata: `:oban`,
      `:steward`. The `:stop` event adds the `:rescued_count` measurement.

  ## Pruner

    * `[:steward, :pruner, :prune_all_expired, :start | :stop | :exception]` - a pruner run,
      which deletes the jobs of resources cancelled more than `:prune_max_age` ago and marks
      them pruned (see `Steward.Plugin`). Metadata: `:oban`, `:steward`. The `:stop` event
      adds the `:pruned_count` measurement.
  """
  @moduledoc since: "0.1.0"

  @doc false
  @spec span([atom], :telemetry.event_metadata(), :telemetry.span_function()) ::
          :telemetry.span_result()
  def span(event, meta, fun) when is_list(event) do
    :telemetry.span([:steward | event], meta, fun)
  end
end
