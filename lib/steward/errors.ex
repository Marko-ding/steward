# SPDX-License-Identifier: Apache-2.0

defmodule Steward.ResourceNotFoundError do
  @moduledoc """
  Raised when a resource doesn't exist for the given controller, e.g. by
  `Steward.Controller.schedule_resource!/2`.
  """

  @moduledoc since: "0.1.0"

  defexception [:message]
end

defmodule Steward.ResourceAlreadyPrunedError do
  @moduledoc """
  Raised when resuming a resource whose jobs were already pruned, see
  `Steward.Controller.resume_resource!/2`.
  """

  @moduledoc since: "0.1.0"

  defexception [:message]
end
