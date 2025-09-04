# LetItCrash

A testing library for crash recovery and OTP supervision behavior in Elixir.

Embrace the "let it crash" philosophy in your tests by easily simulating crashes and verifying that your GenServers and supervised processes recover correctly.

## Installation

Add `let_it_crash` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:let_it_crash, "~> 0.1.0", only: :test}
  ]
end
```

## Usage

```elixir
defmodule MyAppTest do
  use ExUnit.Case
  use LetItCrash

  test "genserver recovers after crash" do
    {:ok, pid} = MyGenServer.start_link([])
    
    # Simulate a crash
    LetItCrash.crash(pid)
    
    # Verify recovery (for supervised processes)
    assert LetItCrash.recovered?(MyGenServer)
  end

  test "state is maintained after restart" do
    LetItCrash.test_restart(MyStatefulServer, fn ->
      # This function runs before AND after the crash
      MyStatefulServer.do_something()
      assert MyStatefulServer.get_state() == expected_state
    end)
  end
end
```

## API

- `crash/1` - Crashes a process by PID or registered name
- `recovered?/2` - Checks if a registered process has recovered after a crash  
- `test_restart/3` - Tests that a process recovers by running the same test before and after crash