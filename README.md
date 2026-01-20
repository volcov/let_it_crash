# LetItCrash

[![CI](https://github.com/volcov/let_it_crash/actions/workflows/ci.yml/badge.svg)](https://github.com/volcov/let_it_crash/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/let_it_crash)](https://hex.pm/packages/let_it_crash)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/let_it_crash)](https://hex.pm/packages/let_it_crash)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/volcov/let_it_crash/blob/main/LICENSE)
[![Elixir Version](https://img.shields.io/badge/elixir-%3E%3D%201.17-blue)](https://elixir-lang.org)

A testing library for crash recovery and OTP supervision behavior in Elixir.

Embrace the "let it crash" philosophy in your tests by easily simulating crashes and verifying that your GenServers and supervised processes recover correctly.

## Why Use LetItCrash?

**We know Elixir/OTP supervision works.** LetItCrash doesn't test if processes restart—it tests if **your application handles restarts correctly**.

Real bugs this library helps catch:
- 🔍 **Resource leaks**: Database connections, file handles, ETS entries not cleaned up
- 🗂️ **Registry inconsistencies**: Stale entries pointing to dead processes  
- 💾 **State corruption**: Shared caches with orphaned data after crashes
- 🔗 **Cascade failures**: Client processes crashing when servers restart
- ⚙️ **Incomplete initialization**: Processes not fully recovering their expected state

*Think of it as integration testing for your crash recovery logic, not unit testing the BEAM.*

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

### `crash/1` and `crash/2`
Crashes a process by PID or registered name. Follows the same convention as `Process.exit/2` 
with the process as the first argument to enable easy piping.

```elixir
# crash/1 - Sends :shutdown signal (can be trapped)
LetItCrash.crash(pid)           # Crash by PID
LetItCrash.crash(:process_name) # Crash by name + auto tracking

# crash/2 - Specify the signal type
LetItCrash.crash(pid, :shutdown)       # Equivalent to crash/1
LetItCrash.crash(pid, :kill)           # :kill signal (cannot be trapped)
LetItCrash.crash(:process_name, :kill) # With registered name

# Piping support:
Process.whereis(:my_process)
|> LetItCrash.crash(:kill)
```

**When to use `:kill`?**

Use `crash(process, :kill)` when testing processes that use `Process.flag(:trap_exit, true)`, 
which is common in GenServers that need to perform cleanup logic on normal exits:

```elixir
defmodule ScoreCoordinator do
  use GenServer

  def init(_) do
    Process.flag(:trap_exit, true)  # Traps normal exits
    {:ok, %{}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Cleanup logic here
    {:noreply, state}
  end
end

# In tests:
test "coordinator recovers from forced crash" do
  {:ok, supervisor} = MySupervisor.start_link()
  {:ok, _pid} = MySupervisor.start_coordinator(supervisor, :coordinator)

  # Use :kill to guarantee termination even with trap_exit
  LetItCrash.crash(:coordinator, :kill)

  assert LetItCrash.recovered?(:coordinator)
end
```

### `wait_for_process/1,2`
Waits for a registered process to exist and be alive. Useful in test setup when you need to ensure a process is available before interacting with it.

```elixir
# Basic usage - waits up to 1000ms (default)
:ok = LetItCrash.wait_for_process(:my_worker)

# With custom timeout for slow-starting processes
:ok = LetItCrash.wait_for_process(:heavy_worker, timeout: 5000)

# With custom polling interval
:ok = LetItCrash.wait_for_process(:worker, timeout: 2000, interval: 100)
```

**Options:**
- `:timeout` - Maximum wait time (default: 1000ms)
- `:interval` - Polling interval (default: 50ms)

**Returns:**
- `:ok` - Process exists and is alive
- `{:error, :timeout}` - Process did not appear within timeout

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

### `assert_clean_registry/2,3`
Verifies that Registry entries are properly cleaned up when a process crashes and recreated when it recovers.

```elixir
# Basic usage - verifies cleanup and re-registration
LetItCrash.assert_clean_registry(MyApp.Registry, :process_name)

# With custom timeout
LetItCrash.assert_clean_registry(MyApp.Registry, :process_name, timeout: 3000)
```

This function ensures your processes properly:
- Remove old Registry entries when crashing
- Create new Registry entries when recovering
- Point to the correct new PID after restart

### `verify_ets_cleanup/2,3`
Monitors ETS table entries to verify proper cleanup during process crashes.

```elixir
# Verify entry is cleaned up (default behavior)
LetItCrash.verify_ets_cleanup(:my_cache, :process_data)

# Custom cleanup expectations
LetItCrash.verify_ets_cleanup(:shared_table, :key, 
  expect_cleanup: true,
  expect_recreate: false,
  timeout: 1500
)

# Verify recreation after cleanup
LetItCrash.verify_ets_cleanup(:cache_table, :data_key,
  expect_cleanup: true,
  expect_recreate: true
)
```

**Options:**
- `:expect_cleanup` - Whether entry should be removed (default: true)
- `:expect_recreate` - Whether entry should be recreated (default: false)  
- `:timeout` - Maximum wait time (default: 1000ms)

## Advanced Usage Examples

### Testing Registry and ETS Cleanup

```elixir
defmodule MyAppTest do
  use ExUnit.Case
  use LetItCrash

  test "server cleans up resources properly on crash" do
    # Setup: Start Registry and ETS table
    {:ok, _} = Registry.start_link(keys: :unique, name: MyApp.Registry)
    :ets.new(:app_cache, [:set, :public, :named_table])
    
    {:ok, supervisor} = MySupervisor.start_link()
    {:ok, _pid} = MySupervisor.start_worker(supervisor, :resource_server)

    # Server registers itself and creates ETS entries
    assert [{_pid, _}] = Registry.lookup(MyApp.Registry, :resource_server)
    :ets.insert(:app_cache, {:server_data, "important_data"})

    # Crash and verify proper cleanup + recovery
    LetItCrash.crash(:resource_server)
    
    # Verify Registry cleanup and re-registration
    assert :ok = LetItCrash.assert_clean_registry(MyApp.Registry, :resource_server)
    
    # Verify ETS cleanup
    assert :ok = LetItCrash.verify_ets_cleanup(:app_cache, :server_data)

    Process.exit(supervisor, :shutdown)
  end
end
```

### Combined Testing Workflow

```elixir
test "complete crash recovery validation" do
  {:ok, supervisor} = MySupervisor.start_link()
  {:ok, _pid} = MySupervisor.start_worker(supervisor, :full_test_server)

  # Test complete recovery workflow
  LetItCrash.test_restart(:full_test_server, fn ->
    # This runs before AND after crash
    MyServer.increment_counter()
    assert MyServer.get_counter() == 1  # Will be reset to 0, then incremented to 1
  end)

  # Verify additional cleanup
  LetItCrash.assert_clean_registry(MyApp.Registry, :full_test_server)
  LetItCrash.verify_ets_cleanup(:server_cache, :counter_data)

  Process.exit(supervisor, :shutdown)
end
```

## Important Notes

⚠️ **Requires Supervision**: The `recovered?/1` and `test_restart/2` functions only work with supervised processes. Unsupervised processes won't restart after crashes.

🔄 **State Reset**: Process state is reset to initial values after restart (this is normal OTP behavior).

🏷️ **Named Processes**: Recovery detection only works with registered (named) processes.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on:

- 🐛 Reporting bugs
- 💡 Suggesting features  
- 🔧 Submitting pull requests
- 🧪 Running tests

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- 📝 [Open an issue](https://github.com/volcov/let_it_crash/issues) for bug reports or feature requests
- 🤝 Check our [Contributing Guide](CONTRIBUTING.md) to help improve the project
- ⭐ Star the project if you find it useful!

---

**Embrace the crash, test the recovery!** 💥➡️✅