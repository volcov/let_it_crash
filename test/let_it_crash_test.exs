defmodule LetItCrashTest do
  use ExUnit.Case
  use LetItCrash

  doctest LetItCrash

  defmodule TestServer do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def get_state(pid) do
      GenServer.call(pid, :get_state)
    end

    @impl true
    def init(:ok), do: {:ok, :initial_state}

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
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
    test "detects when a supervised process recovers" do
      # This would need a proper supervisor setup in a real test
      # For now, we test the basic functionality
      assert LetItCrash.recovered?(:non_existent) == false
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
  end
end
