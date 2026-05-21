# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-05-21

### Added
- **Opt-in process-tree tracing for `observe_async/2` (`trace: true`).** When
  enabled, the observer turns on `:erlang.trace(owner, true, [:procs,
  :set_on_spawn, :monotonic_timestamp])` for the duration of the block and
  classifies the resulting process-exit stream. This makes two previously
  documented-but-empty promises real:
  - **Raw-`Task` silent-swallow detection.** Plain `Task.start/1`,
    `Task.async/1`, `Task.async_stream/3`, and `Task.Supervisor.*` emit no
    `[:task, :exception]` telemetry, so a raised-and-swallowed exception used
    to be invisible. Trace-observed crashes are now synthesized as
    `{[:task, :exit], %{}, %{pid: pid, reason: reason}}` entries in
    `report.exceptions`, so `assert_no_silent_swallow/1` catches them.
  - **Real spawned-pid tracking.** `report.spawned`, `report.completed`, and
    `report.crashed` are now populated from the trace stream. This brings
    `assert_all_completed/2`'s `:incomplete` branch live — it reports which
    spawned pid never finished, instead of always returning `:ok`.
- **`:settle` option for `observe_async/2`** (default `50` ms). At block exit,
  the observer waits up to `:settle` ms for outstanding spawned pids to finish
  before classifying the remainder as still-running (a bounded drain rather
  than a fixed sleep).
- **`:trace_unavailable` warning.** If the calling process is already traced by
  another tool when `trace: true` is requested, tracing is skipped and
  `:trace_unavailable` is added to `report.warnings`; the block still runs and
  the telemetry path is unaffected.

### Changed
- `report.completed` entries sourced from tracing carry the process **exit
  reason** as their `result` (tracing observes exits, not return values).
- Tracing is off by default — existing behavior and performance are unchanged
  unless `trace: true` is passed per call.

### Documentation
- README: new "Catching raw `Task` crashes (`trace: true`)" section with a
  worked example feeding `assert_no_silent_swallow/1` and
  `assert_all_completed/2`, plus notes on the opt-in default and the
  `:trace_unavailable` fallback.
- README: bumped the installation snippet to `~> 0.6.0`.

## [0.5.0] - 2026-05-19

### Added
- **`wait_for_exit/2` function** — monitor-based replacement for `Process.sleep/1`
  calls that wait for a process to die. Returns `:ok` once the target pid is
  no longer alive, or `{:error, :timeout}` after the configurable budget
  (default 1000ms). Handles already-dead pids correctly (monitor fires
  immediately with `:noproc`).
- **`LetItCrash.Async` module** — new public surface for testing async work.
  - `observe_async/1,2` — wrap a block of test code and collect a
    `%LetItCrash.Async.Report{}` describing telemetry exception events
    that fired inside it (Task, Oban, LiveView `handle_async/3`). Handlers
    are isolated per `observe_async` block via `$callers` lineage tracking,
    so two concurrent observers running under `async: true` do not
    cross-pollute their reports.
  - `assert_no_silent_swallow/1,2` — fail when a Task raised but nobody
    noticed.
  - `assert_all_completed/2` — fail when async work did not finish within
    the supplied `:within` wall-clock budget.
  - `assert_idempotent/2` — fail when calling a 0-arity function twice
    produces different observable state. Takes a function (NOT a Report),
    because idempotency by definition requires a second execution. The
    user supplies a `:state` 0-arity snapshot function.
  - `LetItCrash.Async.Report` struct — pure data describing observed
    async work. Fields: `:spawned`, `:completed`, `:crashed`, `:exceptions`,
    `:warnings`, `:duration_ms`, `:started_at`, `:ended_at`.
- **`:telemetry ~> 1.0` runtime dependency** — required for the Async
  observer module. Loosened from a tighter pin so host apps on any
  `1.x` line of telemetry can adopt cleanly.
- **Dependabot config** — `.github/dependabot.yml` opens weekly PRs for
  mix and GitHub Actions updates.
- **AGENTS.md alias style guide** — one alias per line; no
  `alias Foo.{Bar, Baz}` brace form.

### Changed
- **`start_tracking/0`** is now race-safe under concurrent `async: true`
  tests. Previously a TOCTOU window between `:ets.whereis/1` and
  `:ets.new/2` could raise `ArgumentError`; that race is now rescued
  internally (benign — the table exists either way).
- **`use LetItCrash`** now also imports `LetItCrash.Async`, so the new
  observer + assertions are available unqualified in test modules.
- **README leads with a Phoenix + Oban example** showing `observe_async`
  + `assert_no_silent_swallow` + `assert_all_completed` +
  `assert_idempotent`. The supervisor-focused examples remain below.

### Internal
- All seven `Process.sleep(10)` calls in the test suite have been
  replaced with `wait_for_exit/2`. The test suite is now fully
  deterministic with respect to process termination.

### Notes
- `assert_idempotent/2` accepts a `fun`, not a `Report` — this differs
  from an earlier draft because idempotency requires re-execution by
  definition. See `LetItCrash.Async.assert_idempotent/2` docs.
- v0.5.0 does **not** capture `Logger` output, so Tasks that log errors
  but recover gracefully are still considered "completed normally".
- Broadway / GenStage observer support is deferred to a future release.
- The `:sandbox` option on `observe_async/2` is documentation-only in
  this release.

## [0.4.0] - 2026-01-19

### Added
- **`wait_for_process/2` function** - Waits for a registered process to exist and be alive
  - Useful in test setup when ensuring a process is available before interacting with it
  - Configurable `:timeout` (default: 1000ms) and `:interval` (default: 50ms) options
  - Returns `:ok` when process is found, `{:error, :timeout}` otherwise
  - Particularly helpful after starting supervisors or during async initialization

## [0.3.0] - 2025-10-21

### Changed (Breaking)
- **Refactored `crash` API** - Following Elixir best practices, removed `crash!/1` function in favor of `crash/2`
  - `crash!/1` has been removed (the `!` suffix is conventionally reserved for functions that raise exceptions)
  - New signature: `crash(process, type \\ :shutdown)` where `type` can be `:shutdown` or `:kill`
  - Follows the same convention as `Process.exit/2` with the process as the first argument
  - Enables easy piping: `Process.whereis(:name) |> LetItCrash.crash(:kill)`
  - `crash(pid)` - default behavior (`:shutdown` signal)
  - `crash(pid, :kill)` - guarantees termination (cannot be trapped)
  - Maintains support for both PID and registered name with automatic PID tracking
  - Tests updated to use the new API

### Migration Guide
- Replace `crash!(process)` with `crash(process, :kill)`
- `crash(process)` continues to work the same way (uses `:shutdown` by default)
- Argument order follows `Process.exit/2`: process first, type second

## [0.2.0] - 2025-10-01

### Added
- **`crash!/1` function** - "Bang" version that uses `:kill` signal for guaranteed process termination
  - Works with processes that have `Process.flag(:trap_exit, true)`
  - Cannot be trapped by the target process
  - Particularly useful for testing GenServers with cleanup logic in `handle_info({:EXIT, ...})`
  - Supports both PID and registered name with automatic PID tracking
  - Complete test suite including `TrapExitServer` demonstration

### Changed
- Updated module documentation to explain the difference between `crash/1` and `crash!/1`
- Enhanced README with "When to use `crash!/1`?" section and practical examples
- Added comparison table between `:shutdown` and `:kill` exit signals

### Technical Details
- `:kill` exit signal bypasses process trapping mechanisms
- Maintains same API signature as `crash/1` for consistency
- Includes integration tests with supervised trap_exit processes

## [0.1.0] - 2025-01-03

### Core Functions
- `crash/1` - Crashes processes by PID or registered name with automatic PID tracking
- `recovered?/1,2,3` - Detects process recovery after crashes with multiple signatures
  - Automatic PID tracking when crashing by name
  - Configurable timeout and interval options
  - Manual PID comparison support
- `test_restart/2,3` - Tests complete crash/recovery workflow by running functions before and after

### Advanced Testing Functions
- `assert_clean_registry/2,3` - Verifies Registry entries are properly cleaned up on crash and recreated on recovery
- `verify_ets_cleanup/2,3` - Monitors ETS table entries for proper cleanup during process crashes
  - Support for `expect_cleanup` and `expect_recreate` options
  - Configurable timeout for verification
  - Detects resource leaks and improper state management

### Development Infrastructure  
- **Code Quality**: Credo static code analysis integration with strict mode (0 issues)
- **CI/CD Pipeline**: GitHub Actions with comprehensive testing
  - Tests on Elixir 1.17.2 + OTP 26.0 
  - Automated formatting, compilation warnings, and Credo checks
  - 15 tests covering all functionality, 0 failures
- **Documentation**: ExDoc integration with HTML output
  - Complete API documentation with practical examples
  - Advanced usage examples for Registry and ETS testing
  - README and CHANGELOG integration

### Technical Features
- ✅ Safe process crashes (automatic unlink to prevent test failures)
- ✅ Real recovery detection via PID comparison
- ✅ Supervised process support (GenServers, Agents, custom processes)
- ✅ Resource cleanup validation (Registry entries, ETS tables)
- ✅ Simple and intuitive API with comprehensive error handling
- ✅ Zero external runtime dependencies
- ✅ Automatic tracking system using ETS for PID management

### Project Setup
- MIT License with complete contribution guidelines
- Project badges for CI status, license, and Elixir compatibility
- Issue and PR templates for community contributions
- Comprehensive test coverage with realistic usage examples

[0.5.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.5.0
[0.4.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.4.0
[0.3.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.3.0
[0.2.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.2.0
[0.1.0]: https://github.com/volcov/let_it_crash/releases/tag/v0.1.0
