defmodule LetItCrash.Async.Report do
  @moduledoc """
  Result of a `LetItCrash.Async.observe_async/1,2` block.

  A `Report` records the async work that happened inside an observer block:
  which Tasks/processes were spawned, which completed, which crashed, which
  exceptions were caught by telemetry, plus timing data. The struct is the
  API — its fields are public and stable.

  Three named assertions consume a `Report`:

    * `LetItCrash.Async.assert_no_silent_swallow/1,2`
    * `LetItCrash.Async.assert_all_completed/2`

  (Idempotency uses a function-form assertion that does not consume a
  `Report`; see `LetItCrash.Async.assert_idempotent/2`.)

  ## Fields

    * `:spawned` — list of `{pid, kind, started_at}` for processes observed
      during the block. `kind` is `:task | :unknown`. `started_at` is in
      monotonic milliseconds.
    * `:completed` — list of `{pid, result, finished_at}` for spawned work
      that returned a value.
    * `:crashed` — list of `{pid, reason, finished_at}` for spawned work
      that exited abnormally.
    * `:exceptions` — list of telemetry exception events seen during the
      block. Each entry is `{event_name, measurements, metadata}`.
    * `:warnings` — list of atom hints from the observer
      (e.g. `:no_oban_events_seen`). Reserved; usually empty in v0.5.0.
    * `:duration_ms` — wall-clock duration of the block in milliseconds.
    * `:started_at` — monotonic time (ms) when the block started.
    * `:ended_at` — monotonic time (ms) when the block ended.

  Reports are pure data: no behavior beyond `@type t/0`.
  """

  @type pid_kind :: :task | :unknown

  @type spawned_entry :: {pid(), pid_kind(), integer()}
  @type completed_entry :: {pid(), term(), integer()}
  @type crashed_entry :: {pid(), term(), integer()}
  @type exception_entry :: {[atom()], map(), map()}

  @type t :: %__MODULE__{
          spawned: [spawned_entry()],
          completed: [completed_entry()],
          crashed: [crashed_entry()],
          exceptions: [exception_entry()],
          warnings: [atom()],
          duration_ms: non_neg_integer(),
          started_at: integer() | nil,
          ended_at: integer() | nil
        }

  defstruct spawned: [],
            completed: [],
            crashed: [],
            exceptions: [],
            warnings: [],
            duration_ms: 0,
            started_at: nil,
            ended_at: nil
end
