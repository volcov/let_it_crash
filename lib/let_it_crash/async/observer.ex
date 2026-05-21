defmodule LetItCrash.Async.Observer do
  @moduledoc false

  # Internal lifecycle for `LetItCrash.Async.observe_async/1,2`.
  #
  # On `start/1`, we attach process-scoped `:telemetry` handlers with a
  # unique id (`{:lic_async, ref}` where `ref = make_ref()`). Each handler
  # forwards the event to the calling pid via `send/2`. The handler module
  # is `__MODULE__` and the handler function is a named function — this
  # avoids the "local function passed as handler" warning telemetry logs
  # when given anonymous functions.
  #
  # When `trace: true` (opt-in, default off) we ALSO enable
  # `:erlang.trace(owner, true, [:procs, :set_on_spawn, :monotonic_timestamp])`.
  # Plain `Task`/`Task.Supervisor` work emits no `[:task, :exception]`
  # telemetry, so a raised-and-swallowed exception is invisible to the
  # telemetry path. Process-exit tracing catches it: every spawned child in
  # the owner's subtree reports its own `:spawned` and `:exit`, letting us
  # populate `Report.spawned/completed/crashed` and synthesize a
  # `{[:task, :exit], _, _}` pseudo-event for abnormal exits so
  # `assert_no_silent_swallow/1` sees one uniform exceptions list.
  #
  # On `stop/1`, we detach handlers, tear down the trace, drain accumulated
  # messages (with a bounded settle window for outstanding spawned pids),
  # classify the trace stream, and return a `%LetItCrash.Async.Report{}`.

  alias LetItCrash.Async.Report

  # Telemetry event-name constants — single point of change when upstream
  # libraries rename. Document who emits these as of v0.6.0:
  #
  #   * `[:task, :exception]` — speculative. Pure Elixir `Task` does NOT
  #     emit this event today; we subscribe to it so that libraries which
  #     wrap Task with their own telemetry (and future Elixir versions
  #     that adopt a standard event) work automatically. For raw Task
  #     crashes use `trace: true` (the `[:task, :exit]` pseudo-event path).
  #   * `[:oban, :job, :exception]` — emitted by Oban >= 2.0 when a job
  #     raises and Oban's perform wrapper catches it for retry.
  #   * `[:phoenix, :live_view, :handle_async, :exception]` — emitted by
  #     phoenix_live_view >= 0.20 when an async callback raises.
  @task_exception [:task, :exception]
  @oban_exception [:oban, :job, :exception]
  @live_view_async_exception [:phoenix, :live_view, :handle_async, :exception]

  @default_events [
    @task_exception,
    @oban_exception,
    @live_view_async_exception
  ]

  # Synthesized event name for a trace-observed abnormal process exit. Lets
  # raw-Task crashes flow into `Report.exceptions` alongside real telemetry.
  @task_exit [:task, :exit]

  # Trace flags. `:set_on_spawn` extends tracing to the owner's whole spawn
  # subtree (so children report themselves); `:monotonic_timestamp` stamps
  # each message so spawn/exit times are comparable monotonic ms.
  @trace_flags [:procs, :set_on_spawn, :monotonic_timestamp]

  # Exit reasons that count as a clean finish rather than a crash.
  @clean_exits [:normal, :shutdown]

  @default_settle_ms 50

  @type trace_state :: :off | :on | :unavailable

  @type handle :: %{
          ref: reference(),
          handler_id: term(),
          started_at: integer(),
          owner: pid(),
          trace: boolean(),
          settle: non_neg_integer(),
          trace_state: trace_state()
        }

  @spec start(keyword()) :: handle()
  def start(opts \\ []) do
    events = Keyword.get(opts, :observe, @default_events)
    trace? = Keyword.get(opts, :trace, false)
    settle = Keyword.get(opts, :settle, @default_settle_ms)
    ref = make_ref()
    handler_id = {:lic_async, ref}
    owner = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_event/4,
        %{owner: owner, ref: ref}
      )

    trace_state = if trace?, do: enable_trace(owner), else: :off

    %{
      ref: ref,
      handler_id: handler_id,
      started_at: System.monotonic_time(:millisecond),
      owner: owner,
      trace: trace?,
      settle: settle,
      trace_state: trace_state
    }
  end

  @spec stop(handle()) :: Report.t()
  def stop(%{
        ref: ref,
        handler_id: handler_id,
        started_at: started_at,
        owner: owner,
        trace: trace?,
        settle: settle,
        trace_state: trace_state
      }) do
    ended_at = System.monotonic_time(:millisecond)

    # Detach/teardown BEFORE draining: closing the gate first prevents a
    # concurrent emitter from delivering one more `:lic_async_event` message
    # into the owner's mailbox after we stop reading. Teardown must not raise
    # (Async.observe_async/2 calls stop/1 on its rescue/catch paths too).
    :ok = :telemetry.detach(handler_id)
    if trace_state == :on, do: disable_trace(owner)

    {tele_events, trace_events} = drain(ref, [], [])
    trace_events = settle(trace_events, owner, settle_deadline(settle))

    # Untrace any pids that never exited within the settle window. They stay
    # traced via `:set_on_spawn` inheritance even after we disabled tracing on
    # the owner; untracing them now closes the gate so a later kill (e.g. an
    # `on_exit` cleanup) does not leak a stray `:trace_ts` message into the
    # owner's mailbox. Classification has already captured them as `spawned`.
    leftover = still_running(trace_events, owner)
    Enum.each(leftover, &disable_trace/1)

    spawned = build_spawned(trace_events, owner)
    {completed, crashed} = build_exits(trace_events, owner)

    crash_pseudo_events =
      Enum.map(crashed, fn {pid, reason, _ts} ->
        {@task_exit, %{}, %{pid: pid, reason: reason}}
      end)

    warnings = if trace? and trace_state == :unavailable, do: [:trace_unavailable], else: []

    %Report{
      spawned: spawned,
      completed: completed,
      crashed: crashed,
      exceptions: tele_events ++ crash_pseudo_events,
      warnings: warnings,
      duration_ms: ended_at - started_at,
      started_at: started_at,
      ended_at: ended_at
    }
  end

  @doc false
  def handle_event(event, measurements, metadata, %{owner: owner, ref: ref}) do
    # Telemetry handlers are global: every attached handler fires on every
    # matching event regardless of which process emitted. To isolate events
    # per `observe_async/1,2` block, we forward only when the emitter is
    # either the owner itself or somewhere in the owner's $callers lineage
    # (Tasks copy $callers from their spawner automatically since OTP 25).
    callers = Process.get(:"$callers", [])

    if self() == owner or owner in callers do
      send(owner, {:lic_async_event, ref, event, measurements, metadata})
    end
  end

  # --- trace lifecycle -------------------------------------------------------

  # Returns `:on` when the trace was enabled, `:unavailable` when the owner is
  # already traced by another tool (`:erlang.trace/3` raises `ArgumentError`
  # — "can only have one tracer per process"). We never let that crash the
  # caller; the report carries a `:trace_unavailable` warning instead.
  defp enable_trace(owner) do
    _ = :erlang.trace(owner, true, @trace_flags)
    :on
  rescue
    ArgumentError -> :unavailable
  end

  # Untraces `pid`. Safe to call on a pid that has already exited (the pid
  # spec becomes invalid and `:erlang.trace/3` raises `ArgumentError`).
  defp disable_trace(pid) do
    _ = :erlang.trace(pid, false, @trace_flags)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- draining + settle -----------------------------------------------------

  # Non-blocking drain of both telemetry events (`:lic_async_event`, matched by
  # `ref`) and raw trace messages (`:trace_ts`, no ref — temporal isolation
  # comes from the trace being active only between start/stop). Accumulators
  # are reverse-chronological; `settle/3` keeps prepending and order is
  # normalized at classification.
  defp drain(ref, tele, trace) do
    receive do
      {:lic_async_event, ^ref, event, measurements, metadata} ->
        drain(ref, [{event, measurements, metadata} | tele], trace)

      msg when is_tuple(msg) and tuple_size(msg) >= 5 and elem(msg, 0) == :trace_ts ->
        drain(ref, tele, [msg | trace])
    after
      0 -> {Enum.reverse(tele), trace}
    end
  end

  defp settle_deadline(settle), do: System.monotonic_time(:millisecond) + settle

  # Bounded drain (D8): while some spawned pid has no `:exit` yet AND the
  # settle budget remains, block for more trace messages. Stop as soon as
  # nothing is outstanding or the deadline passes. Whatever is still running
  # at the end stays in `spawned` (absent from completed/crashed), which is
  # what drives `assert_all_completed/2`'s `:incomplete` branch.
  defp settle(trace_events, owner, deadline) do
    case still_running(trace_events, owner) do
      [] ->
        trace_events

      _outstanding ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          trace_events
        else
          receive do
            msg when is_tuple(msg) and tuple_size(msg) >= 5 and elem(msg, 0) == :trace_ts ->
              settle([msg | trace_events], owner, deadline)
          after
            remaining -> trace_events
          end
        end
    end
  end

  # --- classification --------------------------------------------------------

  defp still_running(trace_events, owner) do
    spawned_pids =
      for {:trace_ts, child, :spawned, _parent, _mfa, _ts} <- trace_events,
          child != owner,
          do: child

    exited =
      for {:trace_ts, pid, :exit, _reason, _ts} <- trace_events, into: MapSet.new(), do: pid

    spawned_pids
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(exited, &1))
  end

  defp build_spawned(trace_events, owner) do
    for {:trace_ts, child, :spawned, _parent, mfa, ts} <- Enum.reverse(trace_events),
        child != owner do
      {child, kind_from_mfa(mfa), to_ms(ts)}
    end
  end

  defp build_exits(trace_events, owner) do
    exits =
      for {:trace_ts, pid, :exit, reason, ts} <- Enum.reverse(trace_events),
          pid != owner do
        {pid, reason, to_ms(ts)}
      end

    Enum.split_with(exits, fn {_pid, reason, _ts} -> clean_exit?(reason) end)
  end

  defp clean_exit?(reason) when reason in @clean_exits, do: true
  defp clean_exit?({:shutdown, _}), do: true
  defp clean_exit?(_), do: false

  defp kind_from_mfa({module, _fun, _args}) when module in [Task.Supervised, Task], do: :task
  defp kind_from_mfa(_mfa), do: :unknown

  defp to_ms(native_ts), do: System.convert_time_unit(native_ts, :native, :millisecond)
end
