defmodule ReuseTest do
  use ExUnit.Case
  doctest Reuse

  test "greets the world" do
    assert Reuse.hello() == :world
  end
end
