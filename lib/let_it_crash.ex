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

    Process.exit(process, :kill)
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
end
