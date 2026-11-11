# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Config do
  @moduledoc """
  Interface and validation for global Steward configuration.

  > **NOTE:** Do not use this directly, use `Steward`.

  ## Usage

  Define your Steward configuration on a custom module in your application.

      defmodule MyApp.Steward do
        use Steward, repo: MyApp.Repo
      end

  ### Options

    * `:repo` - the `Ecto.Repo` storing resources. Required.
    * `:table` - the resources table. Defaults to `"steward_resources"`.
    * `:prefix` - the resources table's schema. Defaults to `"public"`.

  The behaviour of Steward's background processes is configured on the plugin, see
  `Steward.Plugin`.
  """

  @moduledoc since: "0.1.0"

  import Oban.Validation, only: [validate_schema!: 2]

  @type t :: %{
          repo: module,
          table: String.t(),
          prefix: String.t()
        }

  @doc false
  @callback __steward_config__() :: t

  # Lenient on purpose: invalid options are reported by `validate_config!/1` after compilation.
  @doc false
  @spec new(keyword) :: t
  def new(opts) do
    %{
      repo: Keyword.get(opts, :repo),
      table: Keyword.get(opts, :table, "steward_resources"),
      prefix: Keyword.get(opts, :prefix, "public")
    }
  end

  @doc false
  @spec validate_config!(keyword) :: :ok
  def validate_config!(opts) do
    validate_schema!(opts,
      repo: :atom,
      table: :string,
      prefix: :string
    )

    if not Keyword.has_key?(opts, :repo) do
      raise ArgumentError, "missing required option :repo"
    end

    :ok
  end
end
