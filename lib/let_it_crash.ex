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

  """

  # ETS table to store original PIDs for recovery tracking
  @table_name :let_it_crash_tracking

  def start_tracking do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table])

      _ ->
        :ok
    end
  end

  @doc """
  Imports LetItCrash testing functions into the current module.
  """
  defmacro __using__(_opts) do
    quote do
      import LetItCrash
    end
  end

  @doc """
  Crashes a process by sending it an exit signal.

  ## Parameters

    * `process` - A PID or registered process name to crash

  ## Examples

      # In your tests:
      {:ok, pid} = MyGenServer.start_link([])
      LetItCrash.crash(pid)

  """
  @spec crash(pid() | atom()) :: :ok | {:error, term()}
  def crash(process) when is_pid(process) do
    # Check if we're linked to avoid crashing the caller
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) ->
        if process in links do
          Process.unlink(process)
        end

      _ ->
        :ok
    end

    Process.exit(process, :shutdown)
    :ok
  end

  def crash(process) when is_atom(process) do
    case Process.whereis(process) do
      nil ->
        {:error, :process_not_found}

      pid ->
        # Store the original PID for recovery tracking
        start_tracking()
        :ets.insert(@table_name, {process, pid})
        crash(pid)
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
    timeout = Keyword.get(opts, :timeout, 1000)
    expect_cleanup = Keyword.get(opts, :expect_cleanup, true)
    expect_recreate = Keyword.get(opts, :expect_recreate, false)

    # Check if table exists
    case :ets.whereis(table) do
      :undefined ->
        {:error, :table_not_found}

      _tid ->
        initial_entry = :ets.lookup(table, key)

        if expect_cleanup do
          case wait_for_ets_cleanup(table, key, timeout) do
            :ok ->
              if expect_recreate do
                wait_for_ets_recreation(table, key, initial_entry, timeout)
              else
                :ok
              end

            error ->
              error
          end
        else
          # If not expecting cleanup, check if we should expect recreation
          if expect_recreate do
            wait_for_ets_recreation(table, key, initial_entry, timeout)
          else
            # Just verify entry still exists
            case :ets.lookup(table, key) do
              [] -> {:error, :entry_unexpectedly_removed}
              _entry -> :ok
            end
          end
        end
    end
  end

  # Private functions

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
    current_time = System.monotonic_time(:millisecond)

    cond do
      current_time > end_time ->
        {:error, :cleanup_timeout}

      true ->
        current_entries = Registry.lookup(registry, key)
        current_pids = Enum.map(current_entries, fn {pid, _} -> pid end)

        # Check if all initial PIDs are gone and new ones appeared
        old_pids_gone = Enum.all?(initial_pids, fn pid -> pid not in current_pids end)
        new_entries_exist = length(current_entries) > 0

        cond do
          # If there were no initial entries, just check that new ones exist
          initial_pids == [] and new_entries_exist ->
            :ok

          # If there were initial entries, check they're gone and new ones exist
          old_pids_gone and new_entries_exist ->
            :ok

          # If there were initial entries and they're gone but no new ones yet
          old_pids_gone and not new_entries_exist ->
            Process.sleep(50)
            wait_for_registry_cleanup(registry, key, initial_pids, end_time)

          # Still have old PIDs, keep waiting
          true ->
            Process.sleep(50)
            wait_for_registry_cleanup(registry, key, initial_pids, end_time)
        end
    end
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
    current_time = System.monotonic_time(:millisecond)

    cond do
      current_time > end_time ->
        {:error, :recreation_timeout}

      true ->
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
end
