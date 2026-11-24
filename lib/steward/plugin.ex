# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Plugin do
  @moduledoc """
  Supervisor for Steward's active components.

  > **NOTE:** Do not use this directly, use `Steward`.

  ## Usage

  After defining your application's plugin module with `use Steward`, you can add it to the list
  of plugins in your Oban configuration:

      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [MyApp.Steward]

  ### Options

  You may pass options to the plugin as usual.

      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [{MyApp.Steward, reconcile_batch_size: 10}]

    * `:reconcile_poll_interval` - how often to check for due resources, in milliseconds.
      Defaults to `30_000`. While reconciliation runs fail as a whole (e.g. the database is
      unavailable), the interval doubles after each failed run, up to 10 minutes, and is
      reset after the next successful run.
    * `:reconcile_batch_size` - resources reconciled per poll. Defaults to `10`.
    * `:reconciliation_error_backoff` - how long after a failed reconciliation (i.e.
      `c:Steward.Controller.load/1` or `c:Steward.Worker.spec/3` raised) a resource is
      reconciled again, in milliseconds. The error is stored in the resource's
      `:reconciliation_error` field. Errors affecting a whole batch of resources back off
      the whole batch, without storing the error. Defaults to 1 hour.
    * `:prune_poll_interval` - how often to prune, in milliseconds. Defaults to `30_000`.
    * `:prune_batch_size` - resources pruned per batch. Defaults to `500`.
    * `:prune_max_age` - how long after cancellation a resource's jobs are deleted, in
      milliseconds, or `:infinity` to disable pruning. Defaults to 30 days.
    * `:lifeline_poll_interval` - how often to rescue resources stuck in reconciliation, in
      milliseconds. Defaults to `30_000`.
    * `:lifeline_reconciliation_timeout` - how long a resource may stay in reconciliation, in
      milliseconds, before it's considered stuck (e.g. after a node crashed mid-reconciliation)
      and scheduled again, or `:infinity` to disable rescuing stuck resources. Defaults to
      1 day.
  """

  @moduledoc since: "0.1.0"

  import Oban.Validation, only: [validate_schema: 2]
  alias Steward.Plugin.Lifeline
  alias Steward.Plugin.Pruner
  alias Steward.Plugin.Reconciler

  @pruner_opts [:conf, :steward, :prune_batch_size, :prune_poll_interval, :prune_max_age]
  @reconciler_opts [
    :conf,
    :steward,
    :reconcile_batch_size,
    :reconcile_poll_interval,
    :reconciliation_error_backoff
  ]

  @lifeline_opts [:conf, :steward, :lifeline_poll_interval, :lifeline_reconciliation_timeout]

  @doc false
  @spec init(keyword) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    children = [
      {Pruner, Keyword.take(opts, @pruner_opts)},
      {Reconciler, Keyword.take(opts, @reconciler_opts)},
      {Lifeline, Keyword.take(opts, @lifeline_opts)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec validate_opts(keyword) :: :ok | {:error, term}
  def validate_opts(opts) do
    validate_schema(opts,
      conf: :any,
      name: :any,
      steward: :any,
      reconcile_batch_size: :pos_integer,
      reconcile_poll_interval: :pos_integer,
      reconciliation_error_backoff: :non_neg_integer,
      prune_batch_size: :pos_integer,
      prune_poll_interval: :pos_integer,
      prune_max_age: :timeout,
      lifeline_poll_interval: :pos_integer,
      lifeline_reconciliation_timeout: :timeout
    )
  end
end
