defmodule LetItCrashTest do
  use ExUnit.Case
  use LetItCrash

  doctest LetItCrash

  defmodule TestServer do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def get_state(server) do
      GenServer.call(server, :get_state)
    end

    def set_state(server, new_state) do
      GenServer.call(server, {:set_state, new_state})
    end

    @impl true
    def init(:ok), do: {:ok, :initial_state}

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end

    @impl true
    def handle_call({:set_state, new_state}, _from, _state) do
      {:reply, :ok, new_state}
    end
  end

  defmodule TestSupervisor do
    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, :ok, opts)
    end

    def start_supervised_server(supervisor, name) do
      child_spec = %{
        id: name,
        start: {TestServer, :start_link, [[name: name]]},
        restart: :permanent,
        shutdown: 5000,
        type: :worker
      }

      case Supervisor.start_child(supervisor, child_spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        error -> error
      end
    end

    @impl true
    def init(:ok) do
      children = []
      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  describe "crash/1" do
    test "kills a process by PID" do
      {:ok, pid} = Agent.start_link(fn -> 0 end)
      # Unlink to prevent the test process from crashing
      Process.unlink(pid)
      assert Process.alive?(pid)

      LetItCrash.crash(pid)

      refute Process.alive?(pid)
    end

    test "kills a registered process by name" do
      {:ok, pid} = Agent.start_link(fn -> 0 end, name: :test_agent)
      # Unlink to prevent the test process from crashing
      Process.unlink(pid)
      assert Process.whereis(:test_agent) != nil

      LetItCrash.crash(:test_agent)

      # Give it a moment to actually die
      Process.sleep(10)
      assert Process.whereis(:test_agent) == nil
    end

    test "returns error for non-existent process" do
      assert LetItCrash.crash(:non_existent) == {:error, :process_not_found}
    end
  end

  describe "recovered?/2" do
    test "returns false for non-existent process" do
      assert LetItCrash.recovered?(:non_existent) == false
    end

    test "detects when a supervised process recovers after crash" do
      {:ok, supervisor} = TestSupervisor.start_link()
      {:ok, _pid} = TestSupervisor.start_supervised_server(supervisor, :test_recovery_server)

      # Get original PID
      original_pid = Process.whereis(:test_recovery_server)
      assert original_pid != nil

      # Set some state to verify it resets after restart
      TestServer.set_state(:test_recovery_server, :modified_state)
      assert TestServer.get_state(:test_recovery_server) == :modified_state

      # Crash the process
      LetItCrash.crash(:test_recovery_server)

      # Wait a bit for the crash to be processed
      Process.sleep(10)

      # Verify the process recovered (has a new PID)
      assert LetItCrash.recovered?(:test_recovery_server, timeout: 2000)

      # Verify it's a new process with reset state
      new_pid = Process.whereis(:test_recovery_server)
      assert new_pid != nil
      assert new_pid != original_pid
      assert TestServer.get_state(:test_recovery_server) == :initial_state

      # Clean up
      Process.exit(supervisor, :shutdown)
    end

    test "works with automatic PID tracking from crash/1" do
      {:ok, supervisor} = TestSupervisor.start_link()
      {:ok, _pid} = TestSupervisor.start_supervised_server(supervisor, :test_auto_tracking)

      # Crash using atom name (this stores original PID automatically)
      LetItCrash.crash(:test_auto_tracking)

      # Verify recovery without needing to pass original PID
      assert LetItCrash.recovered?(:test_auto_tracking, timeout: 2000)

      # Clean up
      Process.exit(supervisor, :shutdown)
    end

    test "handles timeout when process doesn't recover" do
      # Start a process without supervision
      {:ok, _pid} = TestServer.start_link(name: :unsupervised_server)

      # Crash it
      LetItCrash.crash(:unsupervised_server)

      # Should timeout since there's no supervisor to restart it
      refute LetItCrash.recovered?(:unsupervised_server, timeout: 100)
    end
  end

  describe "test_restart/3" do
    test "executes function before and after crash for PID processes" do
      {:ok, pid} = TestServer.start_link()

      result =
        LetItCrash.test_restart(pid, fn ->
          assert TestServer.get_state(pid) == :initial_state
        end)

      # Since we don't have supervision, this should fail
      assert result == {:error, :cannot_test_unnamed_process}
    end

    test "executes function before and after crash for supervised processes" do
      {:ok, supervisor} = TestSupervisor.start_link()
      {:ok, _pid} = TestSupervisor.start_supervised_server(supervisor, :test_restart_server)

      # This should work since it's a named, supervised process
      result =
        LetItCrash.test_restart(
          :test_restart_server,
          fn ->
            # Verify it starts with initial state
            assert TestServer.get_state(:test_restart_server) == :initial_state
            # Modify the state
            TestServer.set_state(:test_restart_server, :test_value)
            assert TestServer.get_state(:test_restart_server) == :test_value
          end,
          timeout: 2000
        )

      # Should succeed
      assert result == :ok

      # Clean up
      Process.exit(supervisor, :shutdown)
    end
  end

  describe "integration tests" do
    test "complete crash and recovery workflow" do
      {:ok, supervisor} = TestSupervisor.start_link()
      {:ok, original_pid} = TestSupervisor.start_supervised_server(supervisor, :workflow_server)

      # Verify process is running
      assert Process.alive?(original_pid)
      assert TestServer.get_state(:workflow_server) == :initial_state

      # Modify state
      TestServer.set_state(:workflow_server, :working_state)
      assert TestServer.get_state(:workflow_server) == :working_state

      # Crash and verify recovery
      LetItCrash.crash(:workflow_server)
      assert LetItCrash.recovered?(:workflow_server, timeout: 2000)

      # Verify new process with reset state
      new_pid = Process.whereis(:workflow_server)
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
      assert TestServer.get_state(:workflow_server) == :initial_state

      # Clean up
      Process.exit(supervisor, :shutdown)
    end
  end
end
