# SPDX-License-Identifier: Apache-2.0

defmodule Steward do
  @moduledoc Steward.Utils.extract_from_readme("steward")
  @moduledoc since: "0.1.0"

  defmacro __using__(opts) do
    quote do
      use Supervisor

      @behaviour Steward.Config
      @behaviour Oban.Plugin

      @after_compile __MODULE__

      @steward_config Steward.Config.new(unquote(opts))

      @doc false
      def __after_compile__(_env, _bytecode) do
        Steward.Config.validate_config!(unquote(opts))
      end

      @doc false
      @impl Steward.Config
      def __steward_config__, do: @steward_config

      @doc false
      @impl Oban.Plugin
      def start_link(opts) do
        conf = Keyword.fetch!(opts, :conf)
        name = Keyword.get(opts, :name, Oban.Registry.via(conf.name, {:plugin, __MODULE__}))
        opts = Keyword.put(opts, :steward, __MODULE__)

        Supervisor.start_link(__MODULE__, opts, name: name)
      end

      @doc false
      @impl Supervisor
      defdelegate init(opts), to: Steward.Plugin

      @doc false
      @impl Oban.Plugin
      defdelegate validate(opts), to: Steward.Plugin, as: :validate_opts
    end
  end
end
