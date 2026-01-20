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

    test "supports piping for better composability" do
      {:ok, pid} = Agent.start_link(fn -> 0 end, name: :pipeable_agent)
      Process.unlink(pid)

      # Test piping support
      result =
        Process.whereis(:pipeable_agent)
        |> LetItCrash.crash()

      assert result == :ok

      # Give it a moment to actually die
      Process.sleep(10)
      assert Process.whereis(:pipeable_agent) == nil
    end
  end

  describe "crash/2 with :kill type" do
    defmodule TrapExitServer do
      use GenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, :ok, opts)
      end

      def get_trap_exit(server) do
        GenServer.call(server, :get_trap_exit)
      end

      @impl true
      def init(:ok) do
        Process.flag(:trap_exit, true)
        {:ok, %{trap_exit: true}}
      end

      @impl true
      def handle_call(:get_trap_exit, _from, state) do
        {:reply, state.trap_exit, state}
      end

      @impl true
      def handle_info({:EXIT, _pid, _reason}, state) do
        # Process continues even after receiving EXIT message
        {:noreply, state}
      end
    end

    test "kills a process with trap_exit by PID" do
      {:ok, pid} = TrapExitServer.start_link()
      Process.unlink(pid)
      assert Process.alive?(pid)
      assert TrapExitServer.get_trap_exit(pid) == true

      LetItCrash.crash(pid, :kill)

      # Give it a moment to process the kill signal
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "kills a registered process with trap_exit by name" do
      {:ok, pid} = TrapExitServer.start_link(name: :test_trap_exit_agent)
      Process.unlink(pid)
      assert Process.whereis(:test_trap_exit_agent) != nil
      assert TrapExitServer.get_trap_exit(:test_trap_exit_agent) == true

      LetItCrash.crash(:test_trap_exit_agent, :kill)

      # Give it a moment to actually die
      Process.sleep(10)
      assert Process.whereis(:test_trap_exit_agent) == nil
    end

    test ":kill signal guarantees termination unlike normal exits" do
      {:ok, pid} = TrapExitServer.start_link()
      Process.unlink(pid)
      assert Process.alive?(pid)
      assert TrapExitServer.get_trap_exit(pid) == true

      # With :kill signal, process cannot trap and will always die
      LetItCrash.crash(pid, :kill)

      # Give it a moment to process the kill signal
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "returns error for non-existent process" do
      assert LetItCrash.crash(:non_existent, :kill) == {:error, :process_not_found}
    end

    test "supports piping with :kill signal" do
      {:ok, pid} = TrapExitServer.start_link(name: :pipeable_trap_exit)
      Process.unlink(pid)

      # Test piping support with :kill
      result =
        Process.whereis(:pipeable_trap_exit)
        |> LetItCrash.crash(:kill)

      assert result == :ok

      # Give it a moment to process the kill signal
      Process.sleep(10)
      assert Process.whereis(:pipeable_trap_exit) == nil
    end

    test "works with supervised trap_exit process" do
      defmodule TrapExitSupervisor do
        use Supervisor

        def start_link(opts \\ []) do
          Supervisor.start_link(__MODULE__, :ok, opts)
        end

        def start_supervised_server(supervisor, name) do
          child_spec = %{
            id: name,
            start: {TrapExitServer, :start_link, [[name: name]]},
            restart: :permanent
          }

          Supervisor.start_child(supervisor, child_spec)
        end

        @impl true
        def init(:ok) do
          Supervisor.init([], strategy: :one_for_one)
        end
      end

      {:ok, supervisor} = TrapExitSupervisor.start_link()

      {:ok, original_pid} =
        TrapExitSupervisor.start_supervised_server(supervisor, :supervised_trap_exit)

      assert Process.alive?(original_pid)
      assert TrapExitServer.get_trap_exit(:supervised_trap_exit) == true

      # Use :kill signal to ensure it terminates
      LetItCrash.crash(:supervised_trap_exit, :kill)

      # Should recover with a new PID
      assert LetItCrash.recovered?(:supervised_trap_exit, timeout: 2000)
      new_pid = Process.whereis(:supervised_trap_exit)
      assert new_pid != original_pid
      assert Process.alive?(new_pid)

      # Clean up
      Process.exit(supervisor, :shutdown)
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

  describe "wait_for_process/2" do
    test "returns :ok immediately when process exists" do
      {:ok, _pid} = TestServer.start_link(name: :existing_process)

      assert LetItCrash.wait_for_process(:existing_process) == :ok

      # Clean up
      Process.whereis(:existing_process) &&
        Process.exit(Process.whereis(:existing_process), :kill)
    end

    test "waits for a process that starts after a delay" do
      # Start a process after 100ms in a separate task
      Task.start(fn ->
        Process.sleep(100)
        TestServer.start_link(name: :delayed_process)
      end)

      # Should wait and find the process
      assert LetItCrash.wait_for_process(:delayed_process, timeout: 500) == :ok

      # Verify it's actually there
      assert Process.whereis(:delayed_process) != nil

      # Clean up
      Process.exit(Process.whereis(:delayed_process), :kill)
    end

    test "returns error on timeout when process never appears" do
      result = LetItCrash.wait_for_process(:never_exists, timeout: 100)

      assert result == {:error, :timeout}
    end

    test "works with supervised processes after supervisor starts" do
      {:ok, supervisor} = TestSupervisor.start_link()
      {:ok, _pid} = TestSupervisor.start_supervised_server(supervisor, :supervised_wait_test)

      # Should find the process
      assert LetItCrash.wait_for_process(:supervised_wait_test) == :ok

      # Clean up
      Process.exit(supervisor, :shutdown)
    end

    test "respects custom interval option" do
      # Start a process after 80ms
      Task.start(fn ->
        Process.sleep(80)
        TestServer.start_link(name: :interval_test_process)
      end)

      # With a longer interval, it should still find the process
      assert LetItCrash.wait_for_process(:interval_test_process, timeout: 500, interval: 25) ==
               :ok

      # Clean up
      Process.exit(Process.whereis(:interval_test_process), :kill)
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

  describe "Registry cleanup testing" do
    setup do
      # Create a test registry for these tests
      {:ok, _} = Registry.start_link(keys: :unique, name: LetItCrashTestRegistry)

      on_exit(fn ->
        Process.whereis(LetItCrashTestRegistry) &&
          Process.exit(Process.whereis(LetItCrashTestRegistry), :kill)
      end)

      :ok
    end

    defmodule RegistryServer do
      use GenServer

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name)
        registry = Keyword.get(opts, :registry)
        GenServer.start_link(__MODULE__, {registry, name}, name: name)
      end

      def init({registry, name}) do
        if registry do
          Registry.register(registry, name, %{status: :active})
        end

        {:ok, %{registry: registry, name: name}}
      end

      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end
    end

    defmodule RegistrySupervisor do
      use Supervisor

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, :ok, opts)
      end

      def start_registry_server(supervisor, name, registry) do
        child_spec = %{
          id: name,
          start: {RegistryServer, :start_link, [[name: name, registry: registry]]},
          restart: :permanent
        }

        Supervisor.start_child(supervisor, child_spec)
      end

      def init(:ok) do
        Supervisor.init([], strategy: :one_for_one)
      end
    end

    test "assert_clean_registry verifies registry cleanup on process restart" do
      {:ok, supervisor} = RegistrySupervisor.start_link()

      {:ok, _pid} =
        RegistrySupervisor.start_registry_server(
          supervisor,
          :registry_test_server,
          LetItCrashTestRegistry
        )

      # Verify process is registered
      entries = Registry.lookup(LetItCrashTestRegistry, :registry_test_server)
      assert length(entries) == 1

      # Crash and verify cleanup
      LetItCrash.crash(:registry_test_server)

      assert LetItCrash.assert_clean_registry(LetItCrashTestRegistry, :registry_test_server) ==
               :ok

      # Clean up
      Process.exit(supervisor, :shutdown)
    end

    test "assert_clean_registry handles timeout" do
      # Test with a process that won't restart
      {:ok, _pid} =
        RegistryServer.start_link(name: :temp_registry_server, registry: LetItCrashTestRegistry)

      LetItCrash.crash(:temp_registry_server)

      # Should timeout since there's no supervisor to restart it
      result =
        LetItCrash.assert_clean_registry(LetItCrashTestRegistry, :temp_registry_server,
          timeout: 100
        )

      assert result == {:error, :cleanup_timeout}
    end
  end

  describe "ETS cleanup testing" do
    setup do
      # Create test ETS table
      :ets.new(:test_ets_table, [:set, :public, :named_table])

      on_exit(fn ->
        if :ets.whereis(:test_ets_table) != :undefined do
          :ets.delete(:test_ets_table)
        end
      end)

      :ok
    end

    defmodule EtsServer do
      use GenServer

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name)
        GenServer.start_link(__MODULE__, :ok, name: name)
      end

      def set_ets_data(server, key, value) do
        GenServer.call(server, {:set_ets, key, value})
      end

      def init(:ok) do
        {:ok, %{}}
      end

      def handle_call({:set_ets, key, value}, _from, state) do
        :ets.insert(:test_ets_table, {key, value})
        {:reply, :ok, state}
      end

      def terminate(_reason, _state) do
        # Clean up ETS entries belonging to this process
        :ets.delete(:test_ets_table, :server_data)
        :ok
      end
    end

    defmodule EtsSupervisor do
      use Supervisor

      def start_link(opts \\ []) do
        Supervisor.start_link(__MODULE__, :ok, opts)
      end

      def start_ets_server(supervisor, name) do
        child_spec = %{
          id: name,
          start: {EtsServer, :start_link, [[name: name]]},
          restart: :permanent
        }

        Supervisor.start_child(supervisor, child_spec)
      end

      def init(:ok) do
        Supervisor.init([], strategy: :one_for_one)
      end
    end

    test "verify_ets_cleanup detects ETS entry cleanup" do
      # Insert initial data manually
      :ets.insert(:test_ets_table, {:server_data, "test_value"})
      assert :ets.lookup(:test_ets_table, :server_data) == [{:server_data, "test_value"}]

      # Manually delete the entry to simulate cleanup
      :ets.delete(:test_ets_table, :server_data)

      # Verify cleanup was detected
      assert LetItCrash.verify_ets_cleanup(:test_ets_table, :server_data) == :ok
    end

    test "verify_ets_cleanup handles table not found" do
      result = LetItCrash.verify_ets_cleanup(:non_existent_table, :some_key)
      assert result == {:error, :table_not_found}
    end

    test "verify_ets_cleanup with expect_recreate option" do
      # Insert initial data
      :ets.insert(:test_ets_table, {:recreate_test, "initial"})

      # Test recreation expectation with the initial entry still present
      # Since we're not cleaning up first and expecting recreation, it should detect
      # that the entry wasn't cleaned up
      result =
        LetItCrash.verify_ets_cleanup(:test_ets_table, :recreate_test,
          expect_cleanup: false,
          expect_recreate: true,
          timeout: 100
        )

      # Should detect that entry wasn't cleaned up
      assert result == {:error, :entry_not_cleaned_up}
    end
  end
end
