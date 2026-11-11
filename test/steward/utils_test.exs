# SPDX-License-Identifier: Apache-2.0

defmodule Steward.UtilsTest do
  use ExUnit.Case, async: true
  import Steward.Utils

  describe "controller_to_string!/1" do
    test "returns the module name without the Elixir prefix" do
      assert controller_to_string!(Steward.TestController) == "Steward.TestController"
    end
  end

  describe "controller_from_string!/1" do
    test "returns the module for a known name" do
      assert controller_from_string!("Steward.TestController") == Steward.TestController
    end

    test "raises for an unknown module name" do
      assert_raise ArgumentError, fn -> controller_from_string!("Steward.DoesNotExist") end
    end
  end

  describe "hash/1" do
    test "returns 32 bits as lowercase hex" do
      assert hash(%{a: [1, "b"]}) =~ ~r/^[0-9a-f]{8}$/
    end

    test "is independent of map order" do
      big = Map.new(1..100, &{&1, &1})
      assert hash(big) == hash(big |> Enum.reverse() |> Map.new())
    end
  end
end
