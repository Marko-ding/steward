# SPDX-License-Identifier: Apache-2.0

defmodule Steward.DataCase do
  @moduledoc false

  # The repo, migrations and `Steward.TestOban` are set up once in `test_helper.exs`.

  use ExUnit.CaseTemplate
  alias Ecto.Adapters.SQL.Sandbox
  alias Steward.TestRepo

  using do
    quote do
      use ExUnit.Case, async: false
      use Oban.Testing, repo: Steward.TestRepo
      import Steward.TestUtils
      import Mox
    end
  end

  setup do
    :ok = Sandbox.checkout(TestRepo)
    on_exit(fn -> Sandbox.checkin(TestRepo) end)
    Mox.verify_on_exit!()
    :ok
  end
end
