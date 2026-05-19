defmodule LetItCrash do
  @moduledoc """
  A testing library for crash recovery and OTP supervision behavior.

  `LetItCrash` helps you test that your GenServers and supervised processes
  recover correctly after crashes, embracing Elixir's "let it crash" philosophy.

  ## Usage

      use LetItCrash

      test "genserver recovers after crash" do
        {:ok, pid} = MyGenServer.start_link([])

        LetItCrash.crash(pid)

        assert LetItCrash.recovered?(MyGenServer)
      end

  ## Crash Functions

  The library provides a `crash/2` function that allows you to specify the type of exit signal.
  It follows the same convention as `Process.exit/2` for consistency and piping support:

    * `crash(pid)` - Sends a `:shutdown` exit signal (default, can be trapped)
    * `crash(pid, :shutdown)` - Explicitly sends `:shutdown` signal
    * `crash(pid, :kill)` - Sends a `:kill` exit signal (cannot be trapped, guarantees termination)

  Use `:kill` when testing processes that trap exits, such as GenServers that
  need to perform cleanup operations.

  ## Async work

  Supervisor recovery is only part of the story. Production failures often
  hide in fire-and-forget Tasks, Oban jobs, and LiveView `handle_async/3`
  callbacks — work that runs outside the caller's stack frame and can fail
  silently. For that, see `LetItCrash.Async`, which provides:

    * `LetItCrash.Async.observe_async/1,2` — wrap a block of test code and
      collect telemetry about every async exception inside it
    * `LetItCrash.Async.assert_no_silent_swallow/1,2` — fail when a Task
      raised but nobody noticed
    * `LetItCrash.Async.assert_all_completed/2` — fail when async work
      didn't finish within a wall-clock budget
    * `LetItCrash.Async.assert_idempotent/2` — fail when running the same
      operation twice produces different observable state

  Both surfaces are imported by `use LetItCrash`.

  """

  # ETS table to store original PIDs for recovery tracking
  @table_name :let_it_crash_tracking

  def start_tracking do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table])
        rescue
          # Another caller created the named table between :ets.whereis/1 and
          # :ets.new/2 — that race is benign; the table exists either way.
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Imports LetItCrash testing functions into the current module.

  This imports both the top-level helpers (`crash/2`, `recovered?/2,3`,
  `wait_for_process/2`, `wait_for_exit/2`, `test_restart/3`,
  `assert_clean_registry/3`, `verify_ets_cleanup/3`,
  `assert_supervision_impact/3`) and the async helpers from
  `LetItCrash.Async` (`observe_async/1,2`, `assert_no_silent_swallow/1,2`,
  `assert_all_completed/2`, `assert_idempotent/2`).
  """
  defmacro __using__(_opts) do
    quote do
      import LetItCrash
      import LetItCrash.Async
    end
  end

  @doc """
  Waits for a registered process to exist and be alive.

  This function is useful in test setup when you need to ensure a process
  is available before interacting with it, particularly after starting
  supervisors or during async initialization.

  ## Parameters

    * `process_name` - The registered name of the process to wait for
    * `opts` - Options for waiting
      * `:timeout` - Maximum time to wait (default: 1000ms)
      * `:interval` - Polling interval (default: 50ms)

  ## Returns

    * `:ok` - Process exists and is alive
    * `{:error, :timeout}` - Process did not appear within timeout

  ## Examples

      test "worker is available after supervisor starts" do
        {:ok, _sup} = MySupervisor.start_link()

        # Wait for the worker to be ready
        :ok = LetItCrash.wait_for_process(:my_worker)

        # Now safe to interact with it
        assert MyWorker.get_status() == :ready
      end

      # With custom timeout for slow-starting processes
      :ok = LetItCrash.wait_for_process(:heavy_worker, timeout: 5000)

  """
  @spec wait_for_process(atom(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_process(process_name, opts \\ []) when is_atom(process_name) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    end_time = System.monotonic_time(:millisecond) + timeout

    do_wait_for_process(process_name, end_time, interval)
  end

  defp do_wait_for_process(process_name, end_time, interval) do
    case Process.whereis(process_name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: :ok,
          else: retry_wait_for_process(process_name, end_time, interval)

      nil ->
        retry_wait_for_process(process_name, end_time, interval)
    end
  end

  defp retry_wait_for_process(process_name, end_time, interval) do
    if System.monotonic_time(:millisecond) > end_time do
      {:error, :timeout}
    else
      Process.sleep(interval)
      do_wait_for_process(process_name, end_time, interval)
    end
  end

  @doc """
  Waits for a process to exit (terminate).

  Uses `Process.monitor/1` to block until the given PID is no longer alive,
  or until the timeout elapses. This is the deterministic replacement for
  `Process.sleep/1` calls that wait "long enough" for a process to die.

  If the process is already dead when the call is made, the monitor fires
  immediately with `:noproc` and the function returns `:ok`.

  ## Parameters

    * `pid` - The PID of the process to wait on
    * `opts` - Options for waiting
      * `:timeout` - Maximum time to wait (default: 1000ms)

  ## Returns

    * `:ok` - The process is no longer alive
    * `{:error, :timeout}` - Process is still alive after the timeout

  ## Examples

      test "process dies after crash" do
        {:ok, pid} = Agent.start_link(fn -> 0 end)
        Process.unlink(pid)

        LetItCrash.crash(pid)

        :ok = LetItCrash.wait_for_exit(pid)
        refute Process.alive?(pid)
      end

      # With custom timeout for slow-terminating processes
      :ok = LetItCrash.wait_for_exit(pid, timeout: 5000)

  """
  @spec wait_for_exit(pid(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_exit(pid, opts \\ []) when is_pid(pid) do
    timeout = Keyword.get(opts, :timeout, 1000)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  @doc """
  Crashes a process by sending it an exit signal.

  Follows the same convention as `Process.exit/2`, with the process as the first argument
  to enable easy piping.

  ## Parameters

    * `process` - A PID or registered process name to crash
    * `type` - The type of exit signal: `:shutdown` (default) or `:kill`

  The `:shutdown` signal can be trapped by processes with `Process.flag(:trap_exit, true)`,
  while `:kill` cannot be trapped and guarantees termination.

  ## Examples

      # Default :shutdown signal:
      {:ok, pid} = MyGenServer.start_link([])
      LetItCrash.crash(pid)

      # Explicitly specifying :shutdown:
      LetItCrash.crash(pid, :shutdown)

      # Piping support:
      Process.whereis(:my_process)
      |> LetItCrash.crash(:kill)

      # For processes with trap_exit, use :kill:
      defmodule ScoreCoordinator do
        use GenServer

        def init(_) do
          Process.flag(:trap_exit, true)
          {:ok, %{}}
        end
      end

      {:ok, pid} = ScoreCoordinator.start_link([])
      LetItCrash.crash(pid, :kill)  # Guarantees termination

  """
  @spec crash(process :: pid() | atom(), type :: :shutdown | :kill) :: :ok | {:error, term()}
  def crash(process, type \\ :shutdown)

  def crash(process, type) when is_pid(process) and type in [:shutdown, :kill] do
    # Check if we're linked to avoid crashing the caller
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if process in links do
          Process.unlink(process)
        end

      _ ->
        :ok
    end

    Process.exit(process, type)
    :ok
  end

  def crash(process, type) when is_atom(process) and type in [:shutdown, :kill] do
    case Process.whereis(process) do
      nil ->
        {:error, :process_not_found}

      pid ->
        # Store the original PID for recovery tracking
        start_tracking()
        :ets.insert(@table_name, {process, pid})
        crash(pid, type)
    end
  end

  @doc """
  Checks if a registered process has recovered (restarted) after a crash.

  This function works by comparing the current PID of a registered process
  with a previously stored PID. If they differ, it means the process was restarted.

  ## Parameters

    * `process_name` - The registered name of the process to check
    * `original_pid` - The PID before the crash (optional, will be retrieved if not provided)
    * `opts` - Options for recovery checking
      * `:timeout` - Maximum time to wait for recovery (default: 1000ms)
      * `:interval` - Polling interval (default: 50ms)

  ## Examples

      test "process recovers after crash" do
        original_pid = Process.whereis(MyGenServer)
        LetItCrash.crash(MyGenServer)
        assert LetItCrash.recovered?(MyGenServer, original_pid)
      end

  """
  @spec recovered?(atom(), pid() | keyword()) :: boolean()
  @spec recovered?(atom(), pid(), keyword()) :: boolean()
  def recovered?(process_name, original_pid_or_opts \\ [])

  def recovered?(process_name, opts) when is_list(opts) do
    # Try to get stored original PID first, fallback to current PID
    original_pid =
      case :ets.whereis(@table_name) do
        :undefined ->
          nil

        _ ->
          case :ets.lookup(@table_name, process_name) do
            [{^process_name, pid}] -> pid
            [] -> nil
          end
      end

    recovered?(process_name, original_pid, opts)
  end

  def recovered?(process_name, original_pid) when is_pid(original_pid) do
    recovered?(process_name, original_pid, [])
  end

  def recovered?(process_name, original_pid, opts)
      when is_pid(original_pid) or is_nil(original_pid) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)

    wait_for_recovery(process_name, original_pid, timeout, interval)
  end

  @doc """
  Tests that a process can recover from a crash by executing a test function
  before and after the crash.

  ## Parameters

    * `process` - PID or registered name of the process to test
    * `test_fn` - Function to execute before and after crash
    * `opts` - Options for the test
      * `:timeout` - Maximum time to wait for recovery (default: 1000ms)

  ## Examples

      test "maintains state after restart" do
        LetItCrash.test_restart(MyStatefulServer, fn ->
          assert MyStatefulServer.get_count() == 0
          MyStatefulServer.increment()
          assert MyStatefulServer.get_count() == 1
        end)
      end

  """
  @spec test_restart(pid() | atom(), function(), keyword()) :: :ok | {:error, term()}
  def test_restart(process, test_fn, opts \\ []) do
    # Execute test function before crash
    test_fn.()

    # Crash the process
    case crash(process) do
      :ok ->
        # Wait for recovery
        process_name = if is_pid(process), do: nil, else: process

        case process_name && recovered?(process_name, opts) do
          # Execute test function after recovery
          true ->
            test_fn.()
            :ok

          false ->
            {:error, :recovery_failed}

          nil ->
            {:error, :cannot_test_unnamed_process}
        end

      error ->
        error
    end
  end

  @doc """
  Asserts that a process properly cleans up its Registry entries on crash and recovery.

  This function verifies that:
  1. The old Registry entry is removed when the process crashes
  2. A new Registry entry is created when the process recovers
  3. The new entry points to the new PID

  ## Parameters

    * `registry` - The Registry module to monitor
    * `process_name` - The registered name/key of the process
    * `opts` - Options for the verification
      * `:timeout` - Maximum time to wait for cleanup and re-registration (default: 2000ms)

  ## Examples

      test "process cleans up registry on restart" do
        {:ok, _pid} = MyServer.start_link(name: :my_server)
        Registry.register(MyApp.Registry, :my_server, %{status: :active})

        LetItCrash.crash(:my_server)
        LetItCrash.assert_clean_registry(MyApp.Registry, :my_server)
      end

  """
  @spec assert_clean_registry(module(), term(), keyword()) :: :ok | {:error, term()}
  def assert_clean_registry(registry, key, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)

    # Get current entries before crash
    initial_entries = Registry.lookup(registry, key)
    initial_pids = Enum.map(initial_entries, fn {pid, _} -> pid end)

    # Wait for registry cleanup and re-registration
    end_time = System.monotonic_time(:millisecond) + timeout
    wait_for_registry_cleanup(registry, key, initial_pids, end_time)
  end

  @doc """
  Verifies that ETS table entries are properly cleaned up when a process crashes.

  This function monitors specific ETS table entries and ensures they are
  cleaned up appropriately during process restart.

  ## Parameters

    * `table` - The ETS table name or reference to monitor
    * `key` - The key to monitor in the ETS table
    * `opts` - Options for the verification
      * `:timeout` - Maximum time to wait for cleanup (default: 1000ms)
      * `:expect_cleanup` - Whether to expect the entry to be cleaned up (default: true)
      * `:expect_recreate` - Whether to expect the entry to be recreated (default: false)

  ## Examples

      test "cleans up ETS entries on crash" do
        :ets.insert(:my_cache, {:server_data, "important"})

        LetItCrash.crash(:my_server)
        LetItCrash.verify_ets_cleanup(:my_cache, :server_data)
      end

      test "recreates ETS entries after recovery" do
        LetItCrash.crash(:my_server)
        LetItCrash.verify_ets_cleanup(:my_cache, :server_data,
          expect_cleanup: true, expect_recreate: true)
      end

  """
  @spec verify_ets_cleanup(atom() | :ets.tid(), term(), keyword()) :: :ok | {:error, term()}
  def verify_ets_cleanup(table, key, opts \\ []) do
    with :ok <- validate_table_exists(table),
         initial_entry <- :ets.lookup(table, key) do
      process_ets_verification(table, key, initial_entry, opts)
    end
  end

  @doc """
  Asserts the impact of crashing a child process on its siblings within a supervision tree.

  Crashes the `target` process and verifies that each process listed in `:expect`
  reaches the expected status (`:restarted`, `:alive`, or `:stopped`).

  This function validates that your chosen supervision strategy (`:one_for_one`,
  `:one_for_all`, `:rest_for_one`) behaves as expected for your specific tree.

  ## Parameters

    * `supervisor` - PID or registered name of the supervisor
    * `target` - Registered name of the child to crash
    * `opts` - Options:
      * `:expect` (required) - Keyword list of `{child_name, expected_status}`
      * `:signal` - Exit signal: `:shutdown` (default) or `:kill`
      * `:timeout` - Max wait time in ms (default: 2000)
      * `:interval` - Polling interval in ms (default: 50)

  ## Expected Statuses

    * `:restarted` - Process is alive with a different PID than before the crash
    * `:alive` - Process is alive with the same PID (unaffected)
    * `:stopped` - Process is no longer registered or alive

  Each status can also be paired with an assertion function that verifies
  application-level behavior after the status is confirmed:

    * `{:restarted, fn -> ... end}` - Verify behavior after restart
    * `{:alive, fn -> ... end}` - Verify the unaffected process is still functional
    * `{:stopped, fn -> ... end}` - Run assertions after confirming the process stopped

  The assertion function runs only after the status is confirmed. If the status
  does not match, the function is never called. If the status matches but the
  function raises, the error propagates as a test failure.

  ## Examples

      # Verify one_for_all restarts all children
      LetItCrash.assert_supervision_impact(:my_sup, :worker_a,
        expect: [
          worker_a: :restarted,
          worker_b: :restarted,
          worker_c: :restarted
        ]
      )

      # Verify one_for_one only restarts the crashed child
      LetItCrash.assert_supervision_impact(:my_sup, :worker_a,
        expect: [
          worker_a: :restarted,
          worker_b: :alive,
          worker_c: :alive
        ]
      )

      # Verify application behavior, not just OTP mechanics
      LetItCrash.assert_supervision_impact(:my_sup, :coordinator,
        expect: [
          coordinator: {:restarted, fn ->
            assert MyCoordinator.get_state() == :idle
          end},
          worker_a: {:alive, fn ->
            assert MyWorker.get_status(:worker_a) == :waiting
          end},
          worker_b: :restarted
        ]
      )

  """
  @spec assert_supervision_impact(pid() | atom(), atom(), keyword()) :: :ok | {:error, term()}
  def assert_supervision_impact(supervisor, target, opts) do
    expect = Keyword.fetch!(opts, :expect)
    signal = Keyword.get(opts, :signal, :shutdown)
    timeout = Keyword.get(opts, :timeout, 2000)
    interval = Keyword.get(opts, :interval, 50)

    supervisor_pid =
      case supervisor do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    if is_nil(supervisor_pid) or not Process.alive?(supervisor_pid) do
      {:error, :supervisor_not_found}
    else
      do_assert_supervision_impact(target, expect, signal, timeout, interval)
    end
  end

  # Private functions

  defp do_assert_supervision_impact(target, expect, signal, timeout, interval) do
    with before_pids when is_map(before_pids) <- snapshot_processes(expect),
         :ok <- crash(target, signal) do
      end_time = System.monotonic_time(:millisecond) + timeout
      wait_for_expectations(expect, before_pids, end_time, interval)
    end
  end

  defp snapshot_processes(expect) do
    Enum.reduce_while(expect, %{}, fn {name, _expected_status}, acc ->
      case Process.whereis(name) do
        nil ->
          {:halt, {:error, [{name, :not_found_before_crash}]}}

        pid ->
          {:cont, Map.put(acc, name, pid)}
      end
    end)
  end

  defp wait_for_expectations(expect, before_pids, end_time, interval) do
    mismatches = compute_mismatches(expect, before_pids)

    cond do
      mismatches == [] ->
        run_assertion_functions(expect)

      System.monotonic_time(:millisecond) > end_time ->
        {:error, mismatches}

      true ->
        Process.sleep(interval)
        wait_for_expectations(expect, before_pids, end_time, interval)
    end
  end

  defp compute_mismatches(expect, before_pids) do
    expect
    |> Enum.reduce([], fn {name, expected}, acc ->
      expected_status = extract_status(expected)
      original_pid = Map.fetch!(before_pids, name)
      actual_status = determine_status(name, original_pid)

      if actual_status == expected_status do
        acc
      else
        [{name, [expected: expected_status, got: actual_status]} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp extract_status({status, fun}) when is_function(fun, 0), do: status
  defp extract_status(status) when is_atom(status), do: status

  defp run_assertion_functions(expect) do
    Enum.each(expect, fn
      {_name, {_status, fun}} when is_function(fun, 0) -> fun.()
      {_name, _status} -> :ok
    end)

    :ok
  end

  defp determine_status(name, original_pid) do
    current_pid = Process.whereis(name)

    cond do
      is_nil(current_pid) ->
        :stopped

      current_pid == original_pid ->
        if Process.alive?(current_pid), do: :alive, else: :stopped

      Process.alive?(current_pid) ->
        :restarted

      true ->
        :stopped
    end
  end

  defp validate_table_exists(table) do
    case :ets.whereis(table) do
      :undefined -> {:error, :table_not_found}
      _tid -> :ok
    end
  end

  defp process_ets_verification(table, key, initial_entry, opts) do
    timeout = Keyword.get(opts, :timeout, 1000)
    expect_cleanup = Keyword.get(opts, :expect_cleanup, true)
    expect_recreate = Keyword.get(opts, :expect_recreate, false)

    cond do
      expect_cleanup and expect_recreate ->
        handle_cleanup_and_recreation(table, key, initial_entry, timeout)

      expect_cleanup ->
        wait_for_ets_cleanup(table, key, timeout)

      expect_recreate ->
        wait_for_ets_recreation(table, key, initial_entry, timeout)

      true ->
        verify_entry_exists(table, key)
    end
  end

  defp handle_cleanup_and_recreation(table, key, initial_entry, timeout) do
    case wait_for_ets_cleanup(table, key, timeout) do
      :ok -> wait_for_ets_recreation(table, key, initial_entry, timeout)
      error -> error
    end
  end

  defp verify_entry_exists(table, key) do
    case :ets.lookup(table, key) do
      [] -> {:error, :entry_unexpectedly_removed}
      _entry -> :ok
    end
  end

  defp wait_for_recovery(process_name, original_pid, timeout, interval) do
    end_time = System.monotonic_time(:millisecond) + timeout
    do_wait_for_recovery(process_name, original_pid, end_time, interval)
  end

  defp do_wait_for_recovery(process_name, original_pid, end_time, interval) do
    current_time = System.monotonic_time(:millisecond)
    current_pid = Process.whereis(process_name)

    cond do
      current_time > end_time ->
        false

      # If no original PID was provided, just check if process exists
      is_nil(original_pid) and current_pid != nil ->
        true

      # If we have original PID, check if current PID is different and not nil
      is_pid(original_pid) and current_pid != nil and current_pid != original_pid ->
        true

      true ->
        Process.sleep(interval)
        do_wait_for_recovery(process_name, original_pid, end_time, interval)
    end
  end

  defp wait_for_registry_cleanup(registry, key, initial_pids, end_time) do
    if System.monotonic_time(:millisecond) > end_time do
      {:error, :cleanup_timeout}
    else
      check_registry_state(registry, key, initial_pids, end_time)
    end
  end

  defp check_registry_state(registry, key, initial_pids, end_time) do
    current_entries = Registry.lookup(registry, key)
    current_pids = Enum.map(current_entries, fn {pid, _} -> pid end)

    old_pids_gone = Enum.all?(initial_pids, fn pid -> pid not in current_pids end)
    new_entries_exist = length(current_entries) > 0

    case {initial_pids == [], old_pids_gone, new_entries_exist} do
      # No initial entries, new ones exist
      {true, _, true} -> :ok
      # Old entries gone, new ones exist
      {false, true, true} -> :ok
      {false, true, false} -> retry_registry_cleanup(registry, key, initial_pids, end_time)
      _ -> retry_registry_cleanup(registry, key, initial_pids, end_time)
    end
  end

  defp retry_registry_cleanup(registry, key, initial_pids, end_time) do
    Process.sleep(50)
    wait_for_registry_cleanup(registry, key, initial_pids, end_time)
  end

  defp wait_for_ets_cleanup(table, key, timeout) do
    end_time = System.monotonic_time(:millisecond) + timeout
    do_wait_for_ets_cleanup(table, key, end_time)
  end

  defp do_wait_for_ets_cleanup(table, key, end_time) do
    current_time = System.monotonic_time(:millisecond)

    cond do
      current_time > end_time ->
        {:error, :cleanup_timeout}

      :ets.lookup(table, key) == [] ->
        :ok

      true ->
        Process.sleep(50)
        do_wait_for_ets_cleanup(table, key, end_time)
    end
  end

  defp wait_for_ets_recreation(table, key, initial_entry, timeout) do
    end_time = System.monotonic_time(:millisecond) + timeout
    do_wait_for_ets_recreation(table, key, initial_entry, end_time)
  end

  defp do_wait_for_ets_recreation(table, key, initial_entry, end_time) do
    if System.monotonic_time(:millisecond) > end_time do
      {:error, :recreation_timeout}
    else
      check_ets_recreation_state(table, key, initial_entry, end_time)
    end
  end

  defp check_ets_recreation_state(table, key, initial_entry, end_time) do
    current_entry = :ets.lookup(table, key)

    cond do
      # Entry was recreated (exists and is different from initial)
      current_entry != [] and current_entry != initial_entry ->
        :ok

      # Entry exists and matches initial (meaning it wasn't cleaned up)
      current_entry == initial_entry ->
        {:error, :entry_not_cleaned_up}

      # Entry doesn't exist yet, keep waiting
      current_entry == [] ->
        Process.sleep(50)
        do_wait_for_ets_recreation(table, key, initial_entry, end_time)
    end
  end
end
