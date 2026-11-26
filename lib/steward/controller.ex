# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Controller do
  @moduledoc """
  A controller groups resources of one type and defines the workers to reconcile for them.

  The centralized `c:load/1` callback is used to load domain data for
  reconciliation and worker runs.

  ## Using this module

      #{Steward.Utils.extract_from_readme("controller-example")}

  `use Steward.Controller` also defines shorthands for managing the controller's resources,
  e.g. `MyController.schedule_resource!(id)` for `schedule_resource!(MyController, id)`. See
  `create_resource/3`, `upsert_resource/3`, `get_resource/2`, `list_resources_by_meta/2`,
  `schedule_resource!/2`, `schedule_resources/2`, `process_resource/4`, `cancel_resource!/2` and
  `resume_resource!/2`.

  ## Options

    * `:steward` - the module defined with `use Steward`, which stores this controller's
      resources. Required.

    * `:reconcile_interval` - how long after a reconciliation a resource is reconciled again,
      in milliseconds. Defaults to `:infinity`, i.e. resources are only reconciled after their
      jobs ran and when scheduled on demand, see below.

  ## Recurring reconciliation vs. on-demand reconciliation

  Use the `:reconcile_interval` option with caution. A frequently recurring reconciliation spends
  compute on resources that haven't changed, up to the point where individual "poller workers"
  require less resources. It is typically preferable to explicitly schedule your resource for
  reconciliation when external state is modified, hence in your domain operations.

  See the `Steward.Controller.process_resource/4` function for a common integration pattern.

  However, a recurring but infrequent reconciliation may serve as a safety net to protect against
  accidentally forgetting about the `process_resource/4` or `schedule_resource!/2` in a code path.
  """

  @moduledoc since: "0.1.0"

  import Ecto.Query
  import Oban.Validation, only: [validate_schema!: 2]
  import Steward.Utils, only: [controller_to_string!: 1]
  alias Steward.Controller.Query
  alias Steward.Resource
  alias Steward.ResourceAlreadyPrunedError
  alias Steward.ResourceNotFoundError

  @typedoc """
  Function passed to `process_resource/4`. Returns `{schedule?, result}`: when `schedule?` is
  true, the resource is scheduled for reconciliation; `result` is passed through.
  """
  @type processor :: (object -> {boolean, term})

  @typedoc """
  Arbitrary domain data returned by `c:load/1`, passed to `c:Steward.Worker.spec/3`,
  `c:Steward.Worker.perform/2` and the `t:processor/0` of `process_resource/4`.
  """
  @type object :: term

  @doc false
  @callback __steward__() :: module

  @doc false
  @callback __steward_controller_config__() :: map

  @doc """
  Called to fetch the set of related workers for this controller.
  """
  @doc since: "0.1.0"
  @callback workers() :: [module]

  @doc """
  Called with the resource before reconciliation and processing.

  Returns `{:ok, object}` with arbitrary domain data, e.g. the domain entity the resource
  corresponds to. The loaded object is passed to `c:Steward.Worker.spec/3`,
  `c:Steward.Worker.perform/2`, and to the function given to `Steward.Controller.process_resource/4`.
  Include the resource (or parts of it, like its `:meta`) in the loaded object if these need it.

  Return `:cancel` if the given resource is not relevant anymore and should be removed from
  the reconciliation loop. Its pending jobs are deleted, yet currently executing jobs continue
  to run.

  Implementation should ideally be pure and must be free of side effects on Steward resources,
  e.g. no calls to `schedule_resource!/2`.
  """
  @doc since: "0.1.0"
  @callback load(Steward.Resource.t()) :: {:ok, object} | :cancel

  defmacro __using__(opts) do
    # Expand aliases (e.g. the `:steward` module) as if inside a function, so they become
    # runtime rather than compile-time dependencies of the controller.
    opts = Macro.expand_literals(opts, %{__CALLER__ | function: {:__steward__, 0}})

    quote do
      alias Steward.Controller
      alias Steward.Resource

      @behaviour Controller

      # Validated here rather than in the macro, so that options may be expressions like
      # `:timer.hours(24)` instead of literals only.
      @steward_controller_opts Controller.validate_opts!(unquote(opts))

      @doc false
      @impl Controller
      def __steward__, do: Keyword.fetch!(@steward_controller_opts, :steward)

      @doc false
      @impl Controller
      def __steward_controller_config__ do
        %{
          reconcile_interval:
            Keyword.get(@steward_controller_opts, :reconcile_interval, :infinity)
        }
      end

      if Keyword.get(@steward_controller_opts, :shorthands, true) do
        use Steward.Controller.Shorthands
      end
    end
  end

  @doc false
  @spec validate_opts!(keyword) :: keyword
  def validate_opts!(opts) do
    validate_schema!(opts,
      steward: :any,
      reconcile_interval: :timeout,
      shorthands: :boolean
    )

    if not Keyword.has_key?(opts, :steward) do
      raise ArgumentError, "missing required option :steward"
    end

    opts
  end

  @doc """
  Creates a new resource and schedules it for immediate reconciliation.

  ## Associating a resource with a domain entity

  To associate a resource with a domain entity of your choice, you have the following options:

  - The `:meta` field (map) can carry arbitrary domain information, like foreign keys. Look up
    resources by it with `list_resources_by_meta/2`.
  - You may force the (UUID) `:id` attribute to associate the record with a domain entity.
  - You can store the resource's id on your domain entity.

  ## Example

      create_resource(MyController, %{id: "1d7a1e1c-6a52-4f0e-9a8e-2f4c1b5d3e9a"})

  or

      create_resource(MyController, %{meta: %{order_id: 123}})

  Last argument is passed as options to `c:Ecto.Repo.insert/2`.
  """
  @doc since: "0.1.0"
  @spec create_resource(module) :: {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  @spec create_resource(module, map) ::
          {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  @spec create_resource(module, map, keyword) ::
          {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  def create_resource(controller, user_attrs \\ %{}, opts \\ []) do
    %{repo: repo, prefix: prefix, table: table} = controller.__steward__().__steward_config__()

    %Steward.Resource{}
    |> Ecto.put_meta(prefix: prefix, source: table)
    |> Steward.Resource.create_changeset(user_attrs, %{
      controller: controller_to_string!(controller)
    })
    |> repo.insert(opts)
  end

  @doc """
  Creates a resource, or schedules the existing resource with the same id, for reconciliation.

  Useful with a caller-supplied `:id` (see `create_resource/3`), e.g. to make sure a domain
  entity is reconciled without knowing whether its resource was created yet. Without an `:id`,
  this is equivalent to `create_resource/3`.

  An existing resource is scheduled as with `schedule_resource!/2`, keeping its `:meta`: the
  given `:meta` only applies to newly created resources.

  Returns an error changeset with an error on `:cancelled_at` if the existing resource is
  cancelled. See `resume_resource!/2`.

  ## Example

      upsert_resource(MyController, %{id: order.id, meta: %{order_id: order.id}})

  Last argument is passed as options to `c:Ecto.Repo.insert/2`.
  """
  @doc since: "0.2.0"
  @spec upsert_resource(module) :: {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  @spec upsert_resource(module, map) ::
          {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  @spec upsert_resource(module, map, keyword) ::
          {:ok, Steward.Resource.t()} | {:error, Ecto.Changeset.t()}
  def upsert_resource(controller, user_attrs \\ %{}, opts \\ []) do
    now = DateTime.utc_now()

    # Cancelled resources are skipped by the update, which Ecto reports as stale.
    on_conflict =
      controller
      |> Query.resources()
      |> where([r], is_nil(r.cancelled_at))
      |> Query.schedule(now)
      |> update(set: [updated_at: type(^now, :utc_datetime_usec)])

    create_resource(
      controller,
      user_attrs,
      Keyword.merge(opts,
        on_conflict: on_conflict,
        conflict_target: [:controller, :id],
        returning: true,
        allow_stale: false,
        stale_error_field: :cancelled_at,
        stale_error_message: "is cancelled"
      )
    )
  end

  @doc """
  Fetches a `Steward.Resource` by id.
  """
  @doc since: "0.1.0"
  @spec get_resource(module, Resource.id()) :: {:ok, Steward.Resource.t()} | {:error, :not_found}
  def get_resource(controller, resource_id) do
    controller
    |> Query.resource(resource_id)
    |> repo(controller).one()
    |> case do
      nil -> {:error, :not_found}
      resource -> {:ok, resource}
    end
  end

  @doc """
  Lists the resources whose `:meta` contains `meta`.

  Matches by JSON containment: a resource matches if its `:meta` has all keys of `meta` with
  equal values. Nested maps match partially as well, lists match if they contain all given
  elements.

  Values are compared in their JSON form, e.g. atoms match strings.

  Uses the GIN index on `:meta` created by `Steward.Migrations.up/1`. If you chose not to create
  this index in your migration, this function's query will result in a full table scan.

  ## Example

      list_resources_by_meta(MyController, %{"order_id" => 123})
  """
  @doc since: "0.1.0"
  @spec list_resources_by_meta(module, map) :: [Steward.Resource.t()]
  def list_resources_by_meta(controller, meta) when is_map(meta) do
    controller
    |> Query.resources_by_meta(meta)
    |> repo(controller).all()
  end

  @doc """
  Loads a resource, processes it through a handler, and optionally schedules it for
  reconciliation.

  `fun` receives the loaded object (see `c:load/1`) and returns `{schedule?, result}`. When `schedule?`
  is true, the resource is scheduled for reconciliation. `result` is returned.

  If `c:Steward.Controller.load/1` returns `:cancel`, `fun` is not called and this function
  returns `:cancelled`. The resource is cancelled and the resource's next reconciliation
  will delete its pending jobs.

  If the resource is already cancelled (based on the given struct), again `fun` is not called
  and this function returns `:cancelled`.

  ## Exception handling

  If `fun` raises, throws or exits, the resource is scheduled for reconciliation before the
  error is re-raised, to avoid silently dropping it from its reconciliation loop. Pass
  `schedule_on_error: false` to disable this.

  ## Transactions

  Must not be called within a database transaction, and raises if it is. Scheduling on
  error would be rolled back together with the transaction, silently dropping the resource
  from its reconciliation loop. `fun` may open transactions of its own.

  ## Integration example

      defmodule MyApp.OrderController do
        [...]

        def process_order(order, fun) do
          # See `create_resource/3` for options for how to connect a resource to a domain entity.
          {:ok, resource} = get_resource(order.steward_resource_id)

          process_resource(resource, fn loaded_order ->
            # You could have more centralized boilerplate here, like transaction & locking.

            # Reconcile after the function exits.
            {true, fun.(loaded_order)}
          end)
        end
      end

      # In operations:
      def cancel_order(order) do
        OrderController.process_order(order, fn loaded_order ->
          # ...
        end)
      end
  """
  @doc since: "0.1.0"
  @spec process_resource(module, Resource.t(), processor) :: :cancelled | term
  @spec process_resource(module, Resource.t(), processor, keyword) :: :cancelled | term
  def process_resource(controller, %Resource{} = resource, fun, opts \\ []) do
    %{repo: repo} = controller.__steward__().__steward_config__()

    cond do
      Resource.cancelled?(resource) ->
        :cancelled

      repo.in_transaction?() ->
        raise "#{controller_to_string!(controller)}: " <>
                "process_resource must not be called within a transaction"

      true ->
        do_process_resource(controller, resource, fun, opts)
    end
  end

  defp do_process_resource(controller, resource, fun, opts) do
    schedule_on_error? = Keyword.get(opts, :schedule_on_error, true)

    case controller.load(resource) do
      {:ok, loaded_object} ->
        {schedule?, result} =
          try do
            {_schedule?, _result} = fun.(loaded_object)
          catch
            kind, reason ->
              if schedule_on_error?, do: schedule_resource!(controller, resource)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        if schedule?, do: schedule_resource!(controller, resource)
        result

      :cancel ->
        cancel_resource!(controller, resource)
        :cancelled
    end
  end

  @doc """
  Schedules the given resource for asynchronous reconciliation.
  """
  @doc since: "0.1.0"
  @spec schedule_resource!(module, Resource.t() | Resource.id()) :: Resource.t()
  def schedule_resource!(controller, resource_or_id) do
    now = DateTime.utc_now()

    controller
    |> Query.resource(resource_or_id)
    |> Query.schedule(now)
    |> update_one!(controller, resource_or_id, now)
  end

  @doc """
  Schedules the resources with the given ids for asynchronous reconciliation.

  Like `schedule_resource!/2`, but for many resources in a single query. Returns the number of
  scheduled resources. Ids of resources that don't exist are ignored.
  """
  @doc since: "0.2.0"
  @spec schedule_resources(module, [Resource.id()]) :: {:ok, non_neg_integer}
  def schedule_resources(_controller, []), do: {:ok, 0}

  def schedule_resources(controller, resource_ids) when is_list(resource_ids) do
    now = DateTime.utc_now()

    {count, _} =
      controller
      |> Query.resources(resource_ids)
      |> Query.schedule(now)
      |> update_all(controller, now)

    {:ok, count}
  end

  @doc """
  Cancels the resource, ending its lifecycle.

  The resource is reconciled one last time, which deletes its pending jobs. Executing jobs run
  to completion. Afterwards, the resource is no longer reconciled.
  """
  @doc since: "0.1.0"
  @spec cancel_resource!(module, Resource.t() | Resource.id()) :: Resource.t()
  def cancel_resource!(controller, resource_or_id) do
    now = DateTime.utc_now()

    controller
    |> Query.resource(resource_or_id)
    |> Query.schedule(now)
    |> Query.cancel(now)
    |> update_one!(controller, resource_or_id, now)
  end

  @doc """
  Resumes a cancelled resource, scheduling it for reconciliation.

  Reconciliation recreates the jobs its workers' specs desire. Jobs that completed before the
  cancellation are kept until the resource is pruned, so they are not enqueued again.

  Raises `Steward.ResourceAlreadyPrunedError` if the resource's jobs were already pruned (see
  the `:prune_max_age` option of `Steward.Plugin`), as its workers' jobs could run again.
  Raises `Steward.ResourceNotFoundError` if the resource doesn't exist.

  Resuming a resource that isn't cancelled only schedules it.
  """
  @doc since: "0.1.0"
  @spec resume_resource!(module, Resource.t() | Resource.id()) :: Resource.t()
  def resume_resource!(controller, resource_or_id) do
    now = DateTime.utc_now()

    controller
    |> Query.resource(resource_or_id)
    |> where([r], is_nil(r.pruned_at))
    |> Query.schedule(now)
    |> Query.resume()
    |> update_all(controller, now)
    |> case do
      {_count, [resource]} ->
        resource

      {_count, []} ->
        # Tell a pruned resource apart from a missing one.
        if controller |> Query.resource(resource_or_id) |> repo(controller).exists?() do
          raise ResourceAlreadyPrunedError,
                "#{controller_to_string!(controller)}: " <>
                  "resource #{inspect(resource_id(resource_or_id))} already pruned"
        else
          raise_not_found!(controller, resource_or_id)
        end
    end
  end

  # Reconciles the resource in the calling process, see `Steward.Reconciliation.reconcile_one/4`.
  # Undocumented while the interface settles.
  @doc false
  @spec reconcile_resource(module, Resource.t() | Resource.id()) :: {:ok, non_neg_integer}
  @spec reconcile_resource(module, Resource.t() | Resource.id(), keyword) ::
          {:ok, non_neg_integer}
  def reconcile_resource(controller, resource_or_id, opts \\ []) do
    {oban, opts} = Keyword.pop(opts, :oban, Oban)

    Steward.Reconciliation.reconcile_one(oban, controller, resource_or_id, opts)
  end

  # Runs an update query on a single resource, touching `updated_at` and returning the
  # updated resource.
  defp update_one!(query, controller, resource_or_id, now) do
    case update_all(query, controller, now) do
      {_count, [resource]} -> resource
      {_count, []} -> raise_not_found!(controller, resource_or_id)
    end
  end

  # Runs an update query, touching `updated_at`. Returns the count and the updated resources.
  defp update_all(query, controller, now) do
    query
    |> select([r], r)
    |> Query.touch(now)
    |> repo(controller).update_all([])
  end

  defp raise_not_found!(controller, resource_or_id) do
    raise ResourceNotFoundError,
          "#{controller_to_string!(controller)}: " <>
            "resource #{inspect(resource_id(resource_or_id))} not found"
  end

  defp repo(controller), do: controller.__steward__().__steward_config__().repo

  defp resource_id(%Resource{id: id}), do: id
  defp resource_id(id) when is_binary(id), do: id
end
