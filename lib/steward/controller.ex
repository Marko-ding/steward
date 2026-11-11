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
  `create_resource/3`, `get_resource/2`, `list_resources_by_meta/2`, `schedule_resource!/2`,
  `process_resource/4`, `cancel_resource!/2` and `resume_resource!/2`.

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
  @type processor :: (Resource.t() -> {boolean, term})

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
  Called with the resource before `c:Steward.Worker.spec/3` and `c:Steward.Worker.perform/2`.

  Implementation may fill the virtual `:object` field in the `Steward.Resource.t` struct
  with arbitrary domain data.

  Return `:cancel` if the given resource is not relevant anymore and should be removed from
  the reconciliation loop. Its pending jobs are deleted, yet currently executing jobs continue
  to run.

  Implementation must be free of side effects on Steward resources, e.g. no calls to
  `schedule_resource!/2`.
  """
  @doc since: "0.1.0"
  @callback load(Steward.Resource.t()) :: {:ok, Steward.Resource.t()} | :cancel

  defmacro __using__(opts) do
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

      @doc "See `Steward.Controller.create_resource/3`."
      @spec create_resource() :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec create_resource(map) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec create_resource(map, keyword) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      def create_resource(attrs \\ %{}, opts \\ []) do
        Controller.create_resource(__MODULE__, attrs, opts)
      end

      @doc "See `Steward.Controller.get_resource/2`."
      @spec get_resource(Resource.id()) :: {:ok, Resource.t()} | {:error, :not_found}
      def get_resource(resource_id) do
        Controller.get_resource(__MODULE__, resource_id)
      end

      @doc "See `Steward.Controller.list_resources_by_meta/2`."
      @spec list_resources_by_meta(map) :: [Resource.t()]
      def list_resources_by_meta(meta) do
        Controller.list_resources_by_meta(__MODULE__, meta)
      end

      @doc "See `Steward.Controller.schedule_resource!/2`."
      @spec schedule_resource!(Resource.t() | Resource.id()) :: Resource.t()
      def schedule_resource!(resource_or_id) do
        Controller.schedule_resource!(__MODULE__, resource_or_id)
      end

      @doc "See `Steward.Controller.process_resource/4`."
      @spec process_resource(Resource.t(), Controller.processor()) :: :cancelled | term
      @spec process_resource(Resource.t(), Controller.processor(), keyword) :: :cancelled | term
      def process_resource(resource, fun, opts \\ []) do
        Controller.process_resource(__MODULE__, resource, fun, opts)
      end

      @doc "See `Steward.Controller.cancel_resource!/2`."
      @spec cancel_resource!(Resource.t() | Resource.id()) :: Steward.Resource.t()
      def cancel_resource!(resource_or_id) do
        Controller.cancel_resource!(__MODULE__, resource_or_id)
      end

      @doc "See `Steward.Controller.resume_resource!/2`."
      @spec resume_resource!(Resource.t() | Resource.id()) :: Steward.Resource.t()
      def resume_resource!(resource_or_id) do
        Controller.resume_resource!(__MODULE__, resource_or_id)
      end
    end
  end

  @doc false
  @spec validate_opts!(keyword) :: keyword
  def validate_opts!(opts) do
    validate_schema!(opts,
      steward: :any,
      reconcile_interval: :timeout
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

  - The `:meta` field (map) can carry arbitrary domain information, like foreign keys.
  - You may force the (UUID) `:id` attribute to associate the record with a domain entity.
  - You can store the resource's id on your domain entity.
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

      list_resources_by_meta(MyController, %{"order_id" => 123})

  Uses the GIN index on `:meta` created by `Steward.Migrations.create_resources/1`. Values are
  compared in their JSON form, e.g. atoms match strings.
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

  `fun` receives the loaded resource and returns `{schedule?, result}`. When `schedule?`
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
          # See `create_resource/3` for options how to connect a resource to a domain entity.
          {:ok, resource} = get_resource(order.steward_resource_id)

          process_resource(resource, fn resource ->
            # You could have more centralized boilerplate here, like transaction & locking.

            # Reconcile after the function exits.
            {true, fun.(resource.object)}
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
        raise "#{controller_to_string!(controller)}: process_resource must not be called within a transaction"

      true ->
        do_process_resource(controller, resource, fun, opts)
    end
  end

  defp do_process_resource(controller, resource, fun, opts) do
    schedule_on_error? = Keyword.get(opts, :schedule_on_error, true)

    case controller.load(resource) do
      {:ok, resource} ->
        {schedule?, result} =
          try do
            fun.(resource)
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
      [resource] ->
        resource

      [] ->
        # Tell a pruned resource apart from a missing one.
        if controller |> Query.resource(resource_or_id) |> repo(controller).exists?() do
          raise ResourceAlreadyPrunedError,
                "#{controller_to_string!(controller)}: resource #{inspect(resource_id(resource_or_id))} already pruned"
        else
          raise_not_found!(controller, resource_or_id)
        end
    end
  end

  # Sets `cancelled_at` without scheduling the resource. Only for use during reconciliation.
  @doc false
  @spec mark_resource_cancelled!(module, Resource.t()) :: Resource.t()
  def mark_resource_cancelled!(controller, %Resource{} = resource) do
    now = DateTime.utc_now()

    controller
    |> Query.resource(resource)
    |> Query.cancel(now)
    |> update_one!(controller, resource, now)
  end

  # Schedules the resource for reconciliation `backoff` milliseconds after a failed
  # reconciliation, storing the error. Only for use during reconciliation.
  @doc false
  @spec reschedule_resource_after_reconciliation_error!(
          module,
          Resource.t(),
          Exception.t(),
          Exception.stacktrace(),
          non_neg_integer
        ) :: Resource.t()
  def reschedule_resource_after_reconciliation_error!(
        controller,
        %Resource{} = resource,
        exception,
        stacktrace,
        backoff
      ) do
    now = DateTime.utc_now()

    controller
    |> Query.resource(resource)
    |> Query.schedule(now, DateTime.add(now, backoff, :millisecond))
    |> update(set: [reconciliation_error: ^Exception.format(:error, exception, stacktrace)])
    |> update_one!(controller, resource, now)
  end

  # Runs an update query on a single resource, touching `updated_at` and returning the
  # updated resource.
  defp update_one!(query, controller, resource_or_id, now) do
    case update_all(query, controller, now) do
      [resource] -> resource
      [] -> raise_not_found!(controller, resource_or_id)
    end
  end

  # Runs an update query, touching `updated_at` and returning the updated resources.
  defp update_all(query, controller, now) do
    {_count, resources} =
      query
      |> select([r], r)
      |> update(set: [updated_at: type(^now, :utc_datetime_usec)])
      |> repo(controller).update_all([])

    resources
  end

  defp raise_not_found!(controller, resource_or_id) do
    raise ResourceNotFoundError,
          "#{controller_to_string!(controller)}: resource #{inspect(resource_id(resource_or_id))} not found"
  end

  defp repo(controller), do: controller.__steward__().__steward_config__().repo

  defp resource_id(%Resource{id: id}), do: id
  defp resource_id(id) when is_binary(id), do: id
end
