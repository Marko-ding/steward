# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :steward,
    adapter: Ecto.Adapters.Postgres
end
