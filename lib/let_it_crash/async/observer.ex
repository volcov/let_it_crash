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
  # On `stop/1`, we drain accumulated messages, detach handlers, and return
  # a `%LetItCrash.Async.Report{}`.

  alias LetItCrash.Async.Report

  # Telemetry event-name constants — single point of change when upstream
  # libraries rename. Document who emits these as of v0.5.0:
  #
  #   * `[:task, :exception]` — speculative. Pure Elixir `Task` does NOT
  #     emit this event today; we subscribe to it so that libraries which
  #     wrap Task with their own telemetry (and future Elixir versions
  #     that adopt a standard event) work automatically.
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

  @type handle :: %{
          ref: reference(),
          handler_id: term(),
          started_at: integer(),
          owner: pid()
        }

  @spec start(keyword()) :: handle()
  def start(opts \\ []) do
    events = Keyword.get(opts, :observe, @default_events)
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

    %{
      ref: ref,
      handler_id: handler_id,
      started_at: System.monotonic_time(:millisecond),
      owner: owner
    }
  end

  @spec stop(handle()) :: Report.t()
  def stop(%{ref: ref, handler_id: handler_id, started_at: started_at}) do
    ended_at = System.monotonic_time(:millisecond)
    # Detach BEFORE draining: closing the gate first prevents a concurrent
    # emitter from delivering one more `:lic_async_event` message into the
    # owner's mailbox after we stop reading (which would leak into a later
    # `receive` in the same test process).
    :ok = :telemetry.detach(handler_id)
    exceptions = drain_exceptions(ref, [])

    %Report{
      exceptions: exceptions,
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

  defp drain_exceptions(ref, acc) do
    receive do
      {:lic_async_event, ^ref, event, measurements, metadata} ->
        drain_exceptions(ref, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
