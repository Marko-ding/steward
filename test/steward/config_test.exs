# SPDX-License-Identifier: Apache-2.0

defmodule Steward.ConfigTest do
  use ExUnit.Case, async: true
  alias Steward.Config

  describe "new/1" do
    test "applies defaults" do
      assert Config.new(repo: MyRepo) ==
               %{repo: MyRepo, table: "steward_resources", prefix: "public"}
    end
  end

  describe "validate_config!/1" do
    test "accepts valid options" do
      assert Config.validate_config!(repo: MyRepo, table: "resources", prefix: "steward") == :ok
    end

    test "raises without :repo" do
      assert_raise ArgumentError, ~r/missing required option :repo/, fn ->
        Config.validate_config!(table: "resources")
      end
    end

    test "raises for invalid option types" do
      assert_raise ArgumentError, ~r/expected :table to be a string/, fn ->
        Config.validate_config!(repo: MyRepo, table: :resources)
      end
    end

    test "raises for unknown options" do
      assert_raise ArgumentError, ~r/unknown option :foo/, fn ->
        Config.validate_config!(repo: MyRepo, foo: 1)
      end
    end
  end
end
