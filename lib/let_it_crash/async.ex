defmodule LetItCrash.Async do
  @moduledoc """
  Test helpers for async work — fire-and-forget Tasks, Oban jobs, LiveView
  `handle_async/3` callbacks, and other process-spawning work that runs
  outside the caller's stack frame.

  `LetItCrash.Async` complements the supervision-focused helpers in
  `LetItCrash` (`crash/2`, `recovered?/2,3`, `assert_supervision_impact/3`).
  Where those test how the supervision tree reacts to crashes, this module
  tests three async failure modes that aren't visible from the caller:

  ## Three async failure modes

  ### 1. Silent swallow

  A Task raises but no one is awaiting it. The supervisor moves on; the
  test passes; no log catches the human's eye. Detected via
  `:task.exception` (and similar) telemetry events:

      report =
        LetItCrash.Async.observe_async(fn ->
          Task.start(fn -> raise "boom" end)
        end)

      {:error, {:silent_swallow, _}} = LetItCrash.Async.assert_no_silent_swallow(report)

  ### 2. Partial state / lost result

  The block finishes but spawned work hasn't completed within the user's
  budget. Detected via wall-clock comparison:

      report = LetItCrash.Async.observe_async(fn -> spawn_slow_task() end)
      :ok = LetItCrash.Async.assert_all_completed(report, within: 1000)

  ### 3. Non-idempotent retry

  A user-visible operation produces different state when re-executed.
  Detected by running the function twice and snapshotting state:

      :ok = LetItCrash.Async.assert_idempotent(
        fn -> MyApp.do_work() end,
        state: &MyApp.snapshot/0
      )

  ## When to use this vs the supervisor helpers

  Use `LetItCrash.crash/2` + `LetItCrash.assert_supervision_impact/3` when
  the question is "does my supervision strategy match what I intend?". Use
  `LetItCrash.Async` when the question is "does my async work actually
  finish, and does it crash loudly when it fails?".

  ## Ecto.Sandbox interaction

  A Task spawned inside an `observe_async/2` block may need to inherit the
  caller's sandboxed connection. v0.5.0 does NOT automate this. Pass the
  `:sandbox` opt to document your test's choice:

      LetItCrash.Async.observe_async(
        fn -> ... end,
        sandbox: :inherit  # default; call Ecto.Adapters.SQL.Sandbox.allow/3 explicitly when needed
      )

  ## Limitations (v0.6.0)

    * **No telemetry from raw `Task`.** Pure Elixir `Task` (whether
      `Task.start/1`, `Task.async/1`, or `Task.Supervisor.async_nolink/3`)
      does NOT emit `[:task, :exception]` events today. The telemetry path
      only sees Oban (`[:oban, :job, :exception]`) and Phoenix LiveView
      (`[:phoenix, :live_view, :handle_async, :exception]`). To catch a raw
      `Task` swallow, pass `trace: true` (see next bullet) or use
      `assert_all_completed/2` to bound the work's wall-clock duration.
    * **Opt-in process-tree tracing (`trace: true`).** When enabled, the
      observer turns on `:erlang.trace(owner, true, [:procs, :set_on_spawn,
      :monotonic_timestamp])` for the duration of the block. This tracks the
      pids spawned in the owner's subtree (`report.spawned`), records which
      finished (`report.completed`) and which exited abnormally
      (`report.crashed`), and synthesizes a `{[:task, :exit], %{},
      %{pid:, reason:}}` entry in `report.exceptions` for each crash — so a
      raw-`Task` silent swallow is caught by `assert_no_silent_swallow/1`,
      and a never-finished pid drives `assert_all_completed/2`'s
      `:incomplete` branch. The `Task` family (`Task.start/1`,
      `Task.async/1`, `Task.async_stream/3`, `Task.Supervisor.*`) is covered
      because it spawns through `Task.Supervised`. **Bare `spawn/1`** is NOT
      tagged as `:task` (it shows up as `kind: :unknown`) and a third-party
      library that wraps `spawn/1` and emits `[:task, :exception]` is still
      filtered by the `$callers` gate (last bullet). Tracing is off by
      default — it adds no overhead and changes no behavior unless requested.
    * **One tracer per process.** `:erlang.trace/3` allows a single tracer.
      If the calling process is already traced by another tool when
      `trace: true` is requested, tracing is skipped and `:trace_unavailable`
      is added to `report.warnings`; the block still runs and the telemetry
      path is unaffected. Nesting two `trace: true` observers in the *same*
      pid is unsupported (the inner teardown would tear down the outer
      trace); cross-process nesting is fine.
    * No `Logger` capture. Tasks that log errors but recover gracefully are
      currently considered "completed normally".
    * Broadway / GenStage are not yet observed.
    * **`$callers` lineage gate (telemetry path).** To isolate concurrent
      observers, the telemetry handler forwards an event only when the
      emitting process is the observer's owner OR has the owner in its
      `:"$callers"` process dictionary. `Task.async/1`, `Task.start/1`, and
      `Task.Supervisor.async_nolink/3` all copy `$callers` automatically, so
      Task-spawned work works as expected. However, raw `spawn/1` (and
      `Process.spawn/1`) do NOT copy `$callers`. A third-party library that
      wraps `spawn/1` and emits `[:task, :exception]` would be silently
      filtered out even though it does emit telemetry. (The `trace: true`
      path does not use this gate — it relies on `:set_on_spawn` subtree
      isolation instead.)

  See `LetItCrash.Async.Report` for the data structure produced by
  `observe_async/1,2`.
  """

  alias LetItCrash.Async.Observer
  alias LetItCrash.Async.Report

  @doc """
  Runs `fun` and returns a `%LetItCrash.Async.Report{}` describing the async
  work observed during the call.

  Telemetry handlers are attached on entry and detached on exit, even when
  `fun` raises. If `fun` raises, the exception is re-raised after the
  observer cleans up — the Report is computed for cleanup purposes but is
  not returned in that path.

  ## Options

    * `:observe` — list of telemetry event names to subscribe to. Defaults
      to the standard Task/Oban/LiveView exception events.
    * `:trace` — `false` (default) or `true`. When `true`, enables
      `:erlang.trace`-based process-exit observation of the block's spawn
      subtree. This populates `report.spawned/completed/crashed` and surfaces
      raw-`Task` crashes (which emit no telemetry) as
      `{[:task, :exit], %{}, %{pid:, reason:}}` entries in `report.exceptions`.
      Off by default — opt in per call. If the calling process is already
      traced by another tool, tracing is skipped and `:trace_unavailable` is
      added to `report.warnings` (the block still runs normally).
    * `:settle` — non-negative integer (default `50`). Milliseconds to wait at
      block exit for outstanding spawned pids to finish before classifying the
      remainder as still-running. Only meaningful with `trace: true`.
    * `:sandbox` — `:inherit` (default) or `:off`. Documentation-only;
      does not change behavior.

  ## Examples

      # An Oban job that raises is caught by Oban's perform wrapper, which
      # emits `[:oban, :job, :exception]`. `observe_async/1` captures it.
      report = LetItCrash.Async.observe_async(fn ->
        :telemetry.execute(
          [:oban, :job, :exception],
          %{duration: 1},
          %{worker: "MyWorker", kind: :error, reason: %RuntimeError{message: "boom"}}
        )
      end)

      assert {:error, {:silent_swallow, _}} =
               LetItCrash.Async.assert_no_silent_swallow(report)

  Pure Elixir `Task.start/1` + `raise` does NOT emit any telemetry today, so
  it will NOT show up in the report on the telemetry path. Pass `trace: true`
  to catch it via process-exit tracing — the crash surfaces as a
  `{[:task, :exit], _, _}` entry in `report.exceptions`:

      report =
        LetItCrash.Async.observe_async(
          fn -> Task.start(fn -> raise "boom" end) end,
          trace: true,
          settle: 100
        )

      assert {:error, {:silent_swallow, _}} =
               LetItCrash.Async.assert_no_silent_swallow(report)

  """
  @spec observe_async((-> any()), keyword()) :: Report.t()
  def observe_async(fun, opts \\ []) when is_function(fun, 0) do
    handle = Observer.start(opts)

    try do
      _ = fun.()
      Observer.stop(handle)
    rescue
      error ->
        _ = Observer.stop(handle)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        _ = Observer.stop(handle)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Asserts that no exception was silently swallowed during the observed block.

  A "silent swallow" is the presence of any exception-shaped telemetry event
  (`:task.exception`, `:oban.job.exception`, `:phoenix.live_view.handle_async.exception`)
  inside the block. If an exception had propagated to the test process, the
  test would have already failed — so the only way exceptions reach this
  Report is by being absorbed by a non-linked Task, a retried Oban job, or
  a swallowed LiveView async.

  When the block was observed with `trace: true`, raw-`Task` crashes (which
  emit no telemetry) also count: they surface as synthesized
  `{[:task, :exit], %{}, %{pid: pid, reason: reason}}` entries, where `reason`
  is the exit reason — typically `{exception, stacktrace}` for a raised error.

  ## Returns

    * `:ok` — no exceptions seen
    * `{:error, {:silent_swallow, list}}` — one or more exception events
      were captured; `list` is the list of `{event, measurements, metadata}`
      tuples

  ## Examples

      report = LetItCrash.Async.observe_async(fn ->
        Task.start(fn -> raise "boom" end)
        Process.sleep(50)
      end)

      {:error, {:silent_swallow, [{[:task, :exception], _, _}]}} =
        LetItCrash.Async.assert_no_silent_swallow(report)

  """
  @spec assert_no_silent_swallow(Report.t(), keyword()) :: :ok | {:error, term()}
  def assert_no_silent_swallow(report, opts \\ [])

  def assert_no_silent_swallow(%Report{exceptions: []}, _opts), do: :ok

  def assert_no_silent_swallow(%Report{exceptions: list}, _opts),
    do: {:error, {:silent_swallow, list}}

  @doc """
  Asserts that the observed block finished within `within:` milliseconds and
  that every spawned process either completed or crashed (no still-running
  work at block exit).

  ## Options

    * `:within` (required) — wall-clock budget in milliseconds; compared
      against `report.duration_ms`

  ## Returns

    * `:ok` — under budget and no in-flight work remains
    * `{:error, {:exceeded_within, %{duration_ms: n, budget_ms: w}}}` — the
      block took longer than `within`
    * `{:error, {:incomplete, list}}` — one or more spawned pids never
      reached either `:completed` or `:crashed` within the settle window.
      `list` is the unfinished `{pid, kind, started_at}` entries. Requires
      `trace: true` on the `observe_async/2` call (without it the spawned
      list is empty and this branch never fires)

  ## Examples

      report = LetItCrash.Async.observe_async(fn ->
        Task.async(fn -> :timer.sleep(50) end) |> Task.await()
      end)

      assert :ok = LetItCrash.Async.assert_all_completed(report, within: 500)

  """
  @spec assert_all_completed(Report.t(), keyword()) :: :ok | {:error, term()}
  def assert_all_completed(%Report{} = report, opts) do
    within = Keyword.fetch!(opts, :within)
    completed_count = length(report.completed) + length(report.crashed)
    spawned_count = length(report.spawned)

    cond do
      report.duration_ms > within ->
        {:error, {:exceeded_within, %{duration_ms: report.duration_ms, budget_ms: within}}}

      spawned_count > 0 and completed_count < spawned_count ->
        # With `trace: true` the Observer tracks individual pids, so this
        # surfaces the spawned pids that never reached `:completed` or
        # `:crashed` within the settle window.
        unfinished = unfinished_spawned(report)
        {:error, {:incomplete, unfinished}}

      true ->
        :ok
    end
  end

  defp unfinished_spawned(%Report{} = report) do
    completed_pids = MapSet.new(report.completed, fn {pid, _, _} -> pid end)
    crashed_pids = MapSet.new(report.crashed, fn {pid, _, _} -> pid end)
    seen = MapSet.union(completed_pids, crashed_pids)

    Enum.reject(report.spawned, fn {pid, _, _} -> MapSet.member?(seen, pid) end)
  end

  @doc """
  Asserts that calling `fun` twice in succession leaves the observed state
  unchanged between the two runs.

  Idempotency requires re-execution by definition, so this assertion takes a
  0-arity function (not a `Report`). The user supplies a `:state` 0-arity
  function that returns a snapshot of whatever state is relevant — e.g.
  the count of rows in a DB table, the contents of an ETS table, the value
  in an Agent. The snapshots must be comparable with `==`.

  The flow:

  1. Run `fun` once.
  2. Snapshot state — call this `after_first`.
  3. Run `fun` again.
  4. Snapshot state — call this `after_second`.
  5. Assert `after_first == after_second`.

  Only the snapshots after each run are compared; an initial pre-run
  snapshot would distinguish a no-op fn from a side-effecting one, but
  that's a different property (purity, not idempotency) and is left for
  the caller to assert separately if needed.

  ## Options

    * `:state` (required) — 0-arity function returning the state snapshot

  ## Returns

    * `:ok` — `fun` is idempotent
    * `{:error, {:state_changed, %{after_first: a, after_second: b}}}` —
      running `fun` a second time changed the snapshot

  ## Examples

      :ok = LetItCrash.Async.assert_idempotent(
        fn -> Map.put(%{}, :a, 1) end,
        state: fn -> :no_persistent_state end
      )

  """
  @spec assert_idempotent((-> any()), keyword()) :: :ok | {:error, term()}
  def assert_idempotent(fun, opts) when is_function(fun, 0) do
    state_fn = Keyword.fetch!(opts, :state)

    _ = fun.()
    after_first = state_fn.()
    _ = fun.()
    after_second = state_fn.()

    if after_first == after_second do
      :ok
    else
      {:error, {:state_changed, %{after_first: after_first, after_second: after_second}}}
    end
  end
end
