defmodule LetItCrash.AsyncTest do
  use ExUnit.Case, async: true
  use LetItCrash

  alias LetItCrash.Async
  alias LetItCrash.Async.Report

  doctest LetItCrash.Async

  describe "observe_async/1,2" do
    test "returns a %Report{} for a no-op block" do
      report = Async.observe_async(fn -> :ok end)

      assert %Report{} = report
      assert report.exceptions == []
      assert report.spawned == []
      assert is_integer(report.started_at)
      assert is_integer(report.ended_at)
      assert report.duration_ms >= 0
    end

    test "captures :task.exception telemetry events emitted during the block" do
      report =
        Async.observe_async(fn ->
          :telemetry.execute(
            [:task, :exception],
            %{duration: 1},
            %{kind: :error, reason: %RuntimeError{message: "boom"}}
          )

          :ok
        end)

      assert [
               {[:task, :exception], %{duration: 1},
                %{kind: :error, reason: %RuntimeError{message: "boom"}}}
             ] = report.exceptions
    end

    test "captures :oban.job.exception events" do
      report =
        Async.observe_async(fn ->
          :telemetry.execute(
            [:oban, :job, :exception],
            %{duration: 2},
            %{worker: "MyWorker"}
          )

          :ok
        end)

      assert [{[:oban, :job, :exception], _, %{worker: "MyWorker"}}] = report.exceptions
    end

    test "detaches telemetry handlers after the block (success path)" do
      # Observer attaches a SINGLE handler id (`{:lic_async, ref}`) that
      # covers all three default events via `:telemetry.attach_many/4`.
      # Checking one event surface is therefore sufficient to detect leaks
      # across all three.
      handlers_before = :telemetry.list_handlers([:task, :exception])
      handler_ids_before = MapSet.new(handlers_before, & &1.id)

      _report = Async.observe_async(fn -> :ok end)

      handlers_after = :telemetry.list_handlers([:task, :exception])
      handler_ids_after = MapSet.new(handlers_after, & &1.id)

      assert handler_ids_before == handler_ids_after
    end

    test "detaches telemetry handlers even if the block raises" do
      handlers_before = :telemetry.list_handlers([:task, :exception])
      handler_ids_before = MapSet.new(handlers_before, & &1.id)

      assert_raise RuntimeError, "boom", fn ->
        Async.observe_async(fn -> raise "boom" end)
      end

      handlers_after = :telemetry.list_handlers([:task, :exception])
      handler_ids_after = MapSet.new(handlers_after, & &1.id)

      assert handler_ids_before == handler_ids_after
    end

    test "re-raises caller exceptions (does not swallow them)" do
      assert_raise ArgumentError, "nope", fn ->
        Async.observe_async(fn -> raise ArgumentError, "nope" end)
      end
    end

    test "two concurrent observers do not see each other's events" do
      # Spawn two tasks each running their own observe_async block. Each
      # emits its own telemetry event with distinguishing metadata. Confirm
      # each report contains only its own event.
      #
      # `Task.start/1` (not `start_link`) so a task crash surfaces as
      # `assert_receive` timeout, not as test-process death.
      parent = self()

      Task.start(fn ->
        report =
          Async.observe_async(fn ->
            :telemetry.execute([:task, :exception], %{}, %{from: :a})
            :ok
          end)

        send(parent, {:report_a, report})
      end)

      Task.start(fn ->
        report =
          Async.observe_async(fn ->
            :telemetry.execute([:task, :exception], %{}, %{from: :b})
            :ok
          end)

        send(parent, {:report_b, report})
      end)

      assert_receive {:report_a, %Report{exceptions: a_exceptions}}, 500
      assert_receive {:report_b, %Report{exceptions: b_exceptions}}, 500

      assert Enum.all?(a_exceptions, fn {_, _, meta} -> meta.from == :a end)
      assert Enum.all?(b_exceptions, fn {_, _, meta} -> meta.from == :b end)
    end

    test "is available unqualified via `use LetItCrash`" do
      # `use LetItCrash` is invoked at the top of this module. If
      # `observe_async/1` is not imported, this line would raise
      # CompileError at compile time.
      report = observe_async(fn -> :ok end)
      assert %Report{} = report
    end
  end

  describe "assert_no_silent_swallow/1,2" do
    test "returns :ok when no exceptions were captured" do
      report = Async.observe_async(fn -> :ok end)
      assert Async.assert_no_silent_swallow(report) == :ok
    end

    test "returns {:error, {:silent_swallow, _}} when an exception event was captured" do
      report =
        Async.observe_async(fn ->
          :telemetry.execute(
            [:task, :exception],
            %{duration: 1},
            %{kind: :error, reason: :boom}
          )
        end)

      assert {:error, {:silent_swallow, [{[:task, :exception], _, _}]}} =
               Async.assert_no_silent_swallow(report)
    end

    test "is available unqualified via `use LetItCrash`" do
      report = observe_async(fn -> :ok end)
      assert assert_no_silent_swallow(report) == :ok
    end
  end

  describe "assert_all_completed/2" do
    test "returns :ok when duration is within budget" do
      report = Async.observe_async(fn -> :ok end)
      assert Async.assert_all_completed(report, within: 1000) == :ok
    end

    test "returns :ok when duration_ms equals budget (> not >=)" do
      # Pins the strict `>` semantics of `assert_all_completed/2`. A future
      # change to `>=` would silently break: a block with duration_ms == 0
      # and `within: 0` is currently considered :ok, not exceeded.
      report = Async.observe_async(fn -> :ok end)
      assert report.duration_ms >= 0
      assert Async.assert_all_completed(report, within: report.duration_ms) == :ok
    end

    test "returns {:error, :exceeded_within} when the block runs longer than the budget" do
      report = Async.observe_async(fn -> Process.sleep(60) end)

      assert {:error, {:exceeded_within, %{budget_ms: 10, duration_ms: d}}} =
               Async.assert_all_completed(report, within: 10)

      assert d >= 50
    end

    test "raises KeyError when :within is missing" do
      report = Async.observe_async(fn -> :ok end)
      assert_raise KeyError, fn -> Async.assert_all_completed(report, []) end
    end
  end

  describe "assert_idempotent/2" do
    test "returns :ok when the function does not change observed state" do
      result =
        Async.assert_idempotent(
          fn -> :ok end,
          state: fn -> :stable end
        )

      assert result == :ok
    end

    test "returns {:error, {:state_changed, _}} when the function mutates state on each call" do
      counter =
        start_supervised!(%{id: :idem_counter, start: {Agent, :start_link, [fn -> 0 end]}})

      result =
        Async.assert_idempotent(
          fn -> Agent.update(counter, &(&1 + 1)) end,
          state: fn -> Agent.get(counter, & &1) end
        )

      assert {:error, {:state_changed, %{after_first: a, after_second: b}}} = result
      assert b == a + 1
    end

    test "raises KeyError when :state is missing" do
      assert_raise KeyError, fn -> Async.assert_idempotent(fn -> :ok end, []) end
    end
  end
end
