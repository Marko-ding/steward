<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img alt="Steward" src="assets/banner.svg" width="480">
</p>

<!-- MDOC:steward -->

Steward is an [Oban](https://hex.pm/packages/oban) plugin providing resource-oriented
reconciliation of scheduled jobs against a dynamically calculated specification.

Steward is inspired by Kubernetes controllers and borrows some terminology and ideas
from business rule engines, while staying unintrusive on your codebase.

> #### Alpha {: .warning}
>
> Steward is in an early stage of development. Expect bugs and breaking changes to its API
> and database schema between minor versions until 1.0.

## How it works

Steward separates job trigger logic from domain operations to reduce redundancy and
coupling in your domain logic.

Instead of queueing or scheduling jobs in operations, workers evaluate their preconditions
themselves, deciding if and when they need to be run. Steward _reconciles_ these workers
periodically or on demand, enqueueing or updating Oban jobs as needed to keep them in sync
with the calculated _spec_.

To keep the computational effort low, Steward shards the reconciliation loop and resulting
Oban jobs by _resource objects_, which typically correspond to domain (process) entities.
Entities are grouped by a _controller_ which defines the set of workers to reconcile and
serves as centralized boilerplate. Reconciliation of a single object is performed…

- after every job invocation (if job enters terminal state)
- periodically (see the `:reconcile_interval` option of `Steward.Controller`)
- or on demand (see `Steward.Controller.schedule_resource!/2`)

## Installation

### Requirements

  * Elixir 1.16 or later
  * Oban 2.22 or later, tested with the `Oban.Engines.Basic` engine
  * PostgreSQL 12 or later. Steward relies on Postgres features (`jsonb` containment,
    `FOR UPDATE SKIP LOCKED`), so Oban's SQLite and MySQL engines are not supported.

### Dependency

Add `steward` to your dependencies:

```elixir
def deps do
  [
    {:steward, "~> 0.1"}
  ]
end
```

### Database migration

Steward stores resources in a dedicated, versioned table. See `Steward.Migrations` for options
and how to upgrade to newer versions.

```sh
$ mix ecto.gen.migration add_steward
```

```elixir
defmodule MyApp.Repo.Migrations.AddSteward do
  use Ecto.Migration

  def up, do: Steward.Migrations.up(version: 1)
  def down, do: Steward.Migrations.down(version: 1)
end
```

#### Index on `oban_jobs`

Oban jobs managed by Steward are tracked by attributes in their `meta` field. To ensure
performant lookups of these jobs, we recommend adding a dedicated index on the `oban_jobs` table.

See `Steward.Migrations.add_index_to_oban_jobs/1` for options.

```elixir
defmodule MyApp.Repo.Migrations.AddStewardIndexToObanJobs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: Steward.Migrations.add_index_to_oban_jobs(concurrently: true)
  def down, do: Steward.Migrations.remove_index_from_oban_jobs(concurrently: true)
end
```

### Configuration

#### Steward module

Serves as Steward's resource repository, defining which `Ecto.Repo` and table details to
use to access resources. Define a module in your application as follows:

```elixir
defmodule MyApp.Steward do
  use Steward, repo: MyApp.Repo
end
```

See `Steward.Config` for available options.

#### Oban plugin

Your newly defined resource repository implements [Oban](https://github.com/sorentwo/oban)'s
plugin interface. Install and configure Oban as usual. Steward can run on your existing Oban
instance and will gladly ignore foreign jobs, or you can provide it with its own dedicated instance
(recommended, see Oban's docs on [instance isolation](https://hexdocs.pm/oban/isolation.html)).

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10],
  plugins: [
    MyApp.Steward
  ]
```

All of Steward's active components will only run on Oban's peer leader node.

<!-- MDOC:pruner-warning -->

> #### Oban.Pruner {: .warning}
>
> If you enable Oban's pruner with its `:pruner` option, make sure you do not rely
> on Steward's job uniqueness in your workers. Instead, we advise that your worker's
> `c:Steward.Worker.perform/2` implementation mutates application state in a way that
> `c:Steward.Worker.spec/3` preconditions are invalidated.

<!-- MDOC:pruner-warning -->

### Usage

#### Defining a controller

A controller defines the set of workers to reconcile for a resource type and implements
type-specific callbacks used in the reconciliation and in workers.

<!-- MDOC:controller-example -->

```elixir
defmodule MyApp.OrderController do
  use Steward.Controller,
    steward: MyApp.Steward,
    reconcile_interval: :timer.hours(24)

  @impl Steward.Controller
  def workers, do: [MyApp.Steward.FulfillOrderWorker]

  @impl Steward.Controller
  def load(%Steward.Resource{} = resource) do
    case MyApp.Orders.get!(resource.id) do
      # Returning :cancel stops reconciliation of the resource object.
      %{state: :cancelled} -> :cancel
      # The loaded object, passed to the workers' spec/3 and perform/2.
      order -> {:ok, order}
    end
  end
end
```

<!-- MDOC:controller-example -->

See `Steward.Controller` for more information.

#### Defining a worker

<!-- MDOC:worker-example -->

```elixir
defmodule MyApp.Steward.FulfillOrderWorker do
  use Steward.Worker, queue: :default, max_attempts: 5

  @impl Steward.Worker
  def spec(spec, order, _existing_resource_jobs) do
    if order.fulfilled do
      spec
    else
      schedule(spec, %{some: :arg}, scheduled_at: DateTime.add(order.inserted_at, 2, :day))
    end
  end

  @impl Steward.Worker
  def perform(_oban_job, order) do
    # Invalidates the order.fulfilled precondition in spec/3.
    MyApp.Orders.mark_fulfilled!(order)
    :ok
  end
end
```

<!-- MDOC:worker-example -->

See `Steward.Worker` for more information.

#### Testing

Oban doesn't run plugins in its `:manual` and `:inline` testing modes, so Steward's
reconciliation loop won't run in your tests. Trigger it with `Steward.Testing.reconcile/2`:

<!-- MDOC:testing-example -->

```elixir
test "fulfills the order" do
  order = MyApp.Orders.create!()
  {:ok, _} = MyApp.OrderController.create_resource(%{id: order.id})

  {:ok, 1} = Steward.Testing.reconcile(MyApp.Oban, MyApp.Steward)

  assert_enqueued worker: MyApp.Steward.FulfillOrderWorker
end
```

<!-- MDOC:testing-example -->

See `Steward.Testing` for more information.

## Copyright and License

Copyright © 2026, Marko Switzerland AG.

You may use and redistribute Steward and its source code under the Apache 2.0 License,
see the [LICENSE](LICENSE) file for details or visit:

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

<!-- MDOC:steward -->
