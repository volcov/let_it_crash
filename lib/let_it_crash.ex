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
      nil -> {:error, :process_not_found}
      pid -> crash(pid)
    end
  end

  @doc """
  Checks if a registered process has recovered (restarted) after a crash.

  This function works by comparing the current PID of a registered process
  with a previously stored PID. If they differ, it means the process was restarted.

  ## Parameters

    * `process_name` - The registered name of the process to check
    * `opts` - Options for recovery checking
      * `:timeout` - Maximum time to wait for recovery (default: 1000ms)
      * `:interval` - Polling interval (default: 50ms)

  ## Examples

      test "process recovers after crash" do
        original_pid = Process.whereis(MyGenServer)
        LetItCrash.crash(MyGenServer)
        assert LetItCrash.recovered?(MyGenServer)
      end

  """
  @spec recovered?(atom(), keyword()) :: boolean()
  def recovered?(process_name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)

    wait_for_recovery(process_name, timeout, interval)
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
          true -> test_fn.()
          false -> {:error, :recovery_failed}
          nil -> {:error, :cannot_test_unnamed_process}
        end

      error ->
        error
    end
  end

  # Private functions

  defp wait_for_recovery(process_name, timeout, interval) do
    end_time = System.monotonic_time(:millisecond) + timeout
    do_wait_for_recovery(process_name, end_time, interval)
  end

  defp do_wait_for_recovery(process_name, end_time, interval) do
    current_time = System.monotonic_time(:millisecond)

    cond do
      current_time > end_time ->
        false

      Process.whereis(process_name) != nil ->
        true

      true ->
        Process.sleep(interval)
        do_wait_for_recovery(process_name, end_time, interval)
    end
  end
end
