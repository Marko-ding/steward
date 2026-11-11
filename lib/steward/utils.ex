# SPDX-License-Identifier: Apache-2.0

defmodule Steward.Utils do
  @moduledoc false

  import Bitwise, only: [<<<: 2]

  @external_resource readme = Path.join([__DIR__, "../../README.md"])
  @readme File.read!(readme)

  @spec extract_from_readme(binary) :: binary
  def extract_from_readme(marker) do
    @readme
    |> String.split("<!-- MDOC:#{marker} -->")
    |> Enum.fetch!(1)
  end

  @spec controller_to_string!(module) :: String.t()
  def controller_to_string!(controller) when is_atom(controller), do: inspect(controller)

  @spec controller_from_string!(String.t()) :: module
  def controller_from_string!(controller_name) when is_binary(controller_name) do
    controller_name
    |> String.split(".")
    |> Module.safe_concat()
    |> tap(&Code.ensure_loaded!/1)
  rescue
    e in ArgumentError ->
      reraise ArgumentError,
              """
              controller #{controller_name} does not exist: #{Exception.message(e)}

              Resources store their controller by name. When renaming or deleting a controller,
              all resources pointing to it must be updated or deleted manually.
              """,
              __STACKTRACE__
  end

  # 32-bit portable hash as lowercase hex. `:erlang.phash2/2` is stable across nodes and
  # OTP releases and independent of map order.
  @spec hash(term) :: String.t()
  def hash(term) do
    term
    |> :erlang.phash2(1 <<< 32)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  @spec json_roundtrip!(term) :: term
  def json_roundtrip!(value) do
    value
    |> Oban.JSON.encode!()
    |> Oban.JSON.decode!()
  end
end
