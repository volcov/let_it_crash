defmodule LetItCrashTest do
  use ExUnit.Case
  doctest LetItCrash

  test "greets the world" do
    assert LetItCrash.hello() == :world
  end
end
