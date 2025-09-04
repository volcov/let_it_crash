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

  test "supervised genserver recovers after crash" do
    # Start a supervisor with your GenServer
    {:ok, supervisor} = MySupervisor.start_link()
    {:ok, _pid} = MySupervisor.start_worker(supervisor, :my_worker)
    
    # Crash by name (automatic PID tracking)
    LetItCrash.crash(:my_worker)
    
    # Verify recovery - waits for new PID
    assert LetItCrash.recovered?(:my_worker)
    
    # Clean up
    Process.exit(supervisor, :shutdown)
  end

  test "process state resets after restart" do
    {:ok, supervisor} = MySupervisor.start_link()  
    {:ok, _pid} = MySupervisor.start_worker(supervisor, :stateful_server)
    
    LetItCrash.test_restart(:stateful_server, fn ->
      # This function runs before AND after the crash
      # State will be reset to initial after restart
      MyStatefulServer.increment()
      count = MyStatefulServer.get_count()
      IO.puts("Count: #{count}")  # Will be 1 before crash, 1 after (reset + increment)
    end)
    
    Process.exit(supervisor, :shutdown)
  end

  test "manual PID tracking" do
    {:ok, supervisor} = MySupervisor.start_link()
    {:ok, _pid} = MySupervisor.start_worker(supervisor, :manual_worker)
    
    # Store original PID manually
    original_pid = Process.whereis(:manual_worker)
    LetItCrash.crash(:manual_worker)
    
    # Check recovery with original PID and custom timeout
    assert LetItCrash.recovered?(:manual_worker, original_pid, timeout: 2000)
    
    Process.exit(supervisor, :shutdown)
  end
end
```

## API

### `crash/1`
Crashes a process by PID or registered name. When crashing by name, automatically stores the original PID for recovery tracking.

```elixir
LetItCrash.crash(pid)           # Crash by PID
LetItCrash.crash(:process_name) # Crash by name + auto tracking
```

### `recovered?/1,2,3`
Checks if a registered process has recovered after a crash. Multiple signatures available:

```elixir
# Uses stored PID from crash/1 (recommended)
LetItCrash.recovered?(:process_name)

# With custom timeout/options
LetItCrash.recovered?(:process_name, timeout: 2000, interval: 100)

# Manual PID comparison
LetItCrash.recovered?(:process_name, original_pid)

# Manual PID + options
LetItCrash.recovered?(:process_name, original_pid, timeout: 3000)
```

**Options:**
- `:timeout` - Maximum wait time for recovery (default: 1000ms)
- `:interval` - Polling interval (default: 50ms)

### `test_restart/2,3`
Tests that a process recovers by running the same function before and after crash.

```elixir
# Basic usage
LetItCrash.test_restart(:process_name, fn ->
  # Test logic executed before AND after crash
end)

# With options
LetItCrash.test_restart(:process_name, fn ->
  # Test logic
end, timeout: 2000)
```

## Important Notes

⚠️ **Requires Supervision**: The `recovered?/1` and `test_restart/2` functions only work with supervised processes. Unsupervised processes won't restart after crashes.

🔄 **State Reset**: Process state is reset to initial values after restart (this is normal OTP behavior).

🏷️ **Named Processes**: Recovery detection only works with registered (named) processes.