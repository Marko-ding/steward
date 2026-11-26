# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Controller.Shorthands do
  @moduledoc false

  # Defines shorthands for the functions in `Steward.Controller` that take the controller as
  # first argument, e.g. `MyController.schedule_resource!(id)`. Used by `use Steward.Controller`.

  defmacro __using__(_opts) do
    quote do
      alias Steward.Controller
      alias Steward.Resource

      @doc "See `Steward.Controller.create_resource/3`."
      @spec create_resource() :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec create_resource(map) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec create_resource(map, keyword) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      def create_resource(attrs \\ %{}, opts \\ []) do
        Controller.create_resource(__MODULE__, attrs, opts)
      end

      @doc "See `Steward.Controller.upsert_resource/3`."
      @spec upsert_resource() :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec upsert_resource(map) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      @spec upsert_resource(map, keyword) :: {:ok, Resource.t()} | {:error, Ecto.Changeset.t()}
      def upsert_resource(attrs \\ %{}, opts \\ []) do
        Controller.upsert_resource(__MODULE__, attrs, opts)
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

      @doc "See `Steward.Controller.schedule_resources/2`."
      @spec schedule_resources([Resource.id()]) :: {:ok, non_neg_integer}
      def schedule_resources(resource_ids) do
        Controller.schedule_resources(__MODULE__, resource_ids)
      end

      @doc "See `Steward.Controller.process_resource/4`."
      @spec process_resource(Resource.t(), Controller.processor()) :: :cancelled | term
      @spec process_resource(Resource.t(), Controller.processor(), keyword) :: :cancelled | term
      def process_resource(resource, fun, opts \\ []) do
        Controller.process_resource(__MODULE__, resource, fun, opts)
      end

      @doc "See `Steward.Controller.cancel_resource!/2`."
      @spec cancel_resource!(Resource.t() | Resource.id()) :: Resource.t()
      def cancel_resource!(resource_or_id) do
        Controller.cancel_resource!(__MODULE__, resource_or_id)
      end

      @doc "See `Steward.Controller.resume_resource!/2`."
      @spec resume_resource!(Resource.t() | Resource.id()) :: Resource.t()
      def resume_resource!(resource_or_id) do
        Controller.resume_resource!(__MODULE__, resource_or_id)
      end

      @doc false
      @spec reconcile_resource(Resource.t() | Resource.id()) :: {:ok, non_neg_integer}
      @spec reconcile_resource(Resource.t() | Resource.id(), keyword) :: {:ok, non_neg_integer}
      def reconcile_resource(resource_or_id, opts \\ []) do
        Controller.reconcile_resource(__MODULE__, resource_or_id, opts)
      end
    end
  end
end
