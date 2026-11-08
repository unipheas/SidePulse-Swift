# Local agent lifecycle adapter

`sidepulse_agent.py` uses only Python's standard library. Import it from your own
launcher; it does not patch or install anything. Supply the absolute path of your
built/installed `sidepulsectl` if it differs from the default
`/Applications/SidePulse.app/Contents/MacOS/sidepulsectl`.

Each context represents one actual synchronous operation, with a fresh UUID,
monotonic events, and a same-state heartbeat every lease/4 seconds. It emits only
source, run ID, state, sequence and lease. No prompts, arguments, responses, job
stdout/stderr, URLs or credentials are collected. Sources must be fixed safe
labels, never user content. All reporting uses a local subprocess, no network.
CLI output is discarded, including accepted:false (stale/rejected event).

## Dispatcher boundary

Illustrative integration inside the existing dispatcher, around its real job:

```python
from sidepulse_agent import AgentRun

def run_dispatch_job(job):
    with AgentRun('local-dispatch', executable='/absolute/path/sidepulsectl') as run:
        run.set_state('tool_running')
        result = execute_existing_job(job)  # existing dispatcher implementation
        if result.needs_user_input:
            run.needs_input()
        elif not result.success:
            run.blocked()
        return result
```

A successful return must actually mean the work finished successfully. Explicitly
report failures encoded as return values; the adapter cannot infer their meaning.
After resuming from attention, set `working` before continuing. If exiting while
waiting/blocked, that state remains latched until a later state update, visible for up to 24 hours.
Only active working/tool/progress states become unknown when their lease expires.

## Local Ollama request boundary

Wrap the existing request callable, which owns its endpoint, credentials (if any),
HTTP error handling and finite network timeout:

```python
from sidepulse_agent import instrument

@instrument('ollama', executable='/absolute/path/sidepulsectl')
def request_local_model(existing_request, payload):
    return existing_request(payload)  # e.g. urllib client with timeout=120
```

For a streaming urllib response, put the context around both `urlopen` and the
entire response-reading loop, not just construction of a generator. Only exit
successfully after receiving Ollama's final `done: true` response. Raise an error
for early EOF, cancellation, error payloads or disconnects so the adapter reports
`unknown`, or explicitly call `blocked()` for a known failure. Do not wrap async
functions or generators with the synchronous decorator. No model-loaded polling:
a loaded model is not evidence that an agent is working.

## Failure behavior

Missing CLI, nonzero exit, timeout, and rejected metadata cannot fail the job.
Production emission is serialized and each subprocess has a 0.5-second timeout
(configurable up to 2 seconds). A boundary can wait for one in-flight heartbeat
plus its own emission; reporting is best-effort, not zero-latency. Terminal output
is emitted only after heartbeat shutdown has been signaled and under the same
lock. Abrupt process death cannot send a terminal event; lease expiry handles it.
Explicit `KeyboardInterrupt` and other exceptional exits emit `unknown` and
propagate unchanged. The optional injected emitter is for tests and must itself
be bounded; an arbitrary blocking emitter voids the latency guarantee.

Run tests without hardware or the actual CLI:

```sh
python3 -m unittest discover -s Integrations/tests -v
```

## Wrap an existing command

```sh
python3 Integrations/sidepulse_agent.py --source local-worker --executable /absolute/path/sidepulsectl -- your-existing-command
```

The command inherits stdin, stdout and stderr unchanged. Its command line and
payload are never included in telemetry. Exit zero reports completed; a known
nonzero exit reports blocked_error and preserves the exit code. Cancellation or
signal death reports unknown (shell-style exit code). A command launch failure
returns 127 and reports unknown. Nothing is installed automatically.

To acknowledge a latched attention state, use `sidepulsectl agent-event` with the
same `--source` and `--run`, `--state idle_ready`, and a `--sequence` higher than
that run's last emitted sequence. To resume it instead, send working with a higher
sequence and continue heartbeats. The Python context exposes `run_id` and
`sequence` for callers managing this lifecycle. Do not reuse terminal run IDs.

Thread creation failure is ignored so the operation still runs, though no
heartbeat is available in that case. The synchronous decorator rejects coroutine,
generator, and async-generator functions rather than prematurely reporting success.

Every event also includes required `--started-at UNIX_SECONDS`, captured from
`time.time()` once on context entry and reused unchanged. Acknowledgement or
resumption must supply this same value (`run.started_at`), not the current time.
The receiver rejects changed start identity and newly arriving runs older than
24 hours, while continuing to accept heartbeats for an existing active older run.
This permits bounded retention without stale-event resurrection.

The command wrapper forwards SIGTERM to its owned direct child and waits for it,
restoring the previous signal handler afterward. It never signals unrelated
processes. A child that ignores SIGTERM can keep the wrapper waiting; cancellation
of an entire descendant process tree remains the launcher's responsibility.
KeyboardInterrupt terminates the direct child, waits two seconds, then kills that
child if necessary. This does not promise to terminate grandchildren. Invoke the
CLI entry point on the main thread (Python signal handlers require it).
