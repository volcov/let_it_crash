# LetItCrash

[![CI](https://github.com/volcov/let_it_crash/actions/workflows/ci.yml/badge.svg)](https://github.com/volcov/let_it_crash/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/volcov/let_it_crash/blob/main/LICENSE) [![Elixir Version](https://img.shields.io/badge/elixir-%3E%3D%201.17-blue)](https://elixir-lang.org)

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