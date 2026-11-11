# SPDX-License-Identifier: Apache-2.0

defmodule Steward.TestController do
  use Steward.Controller, steward: Steward.TestSteward

  @impl true
  def workers, do: []

  @impl true
  def load(resource), do: {:ok, resource}
end
