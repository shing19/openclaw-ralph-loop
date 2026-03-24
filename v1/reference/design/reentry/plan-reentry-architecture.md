# OpenClaw Ralph Loop Architecture

This note describes how to use OpenClaw as a controller for a long-running Ralph Loop workflow while keeping both controller context and per-iteration worker processes bounded.

## Goal

You want a Slack-triggered agent that can:

1. Receive one instruction message.
2. Run an environment preflight before any Ralph Loop work begins.
3. Read a reference plan and run a Ralph Loop for up to 24 hours.
4. Execute one task at a time.
5. Spawn a short-lived worker process for that task.
6. Persist the result to a progress record.
7. Terminate the worker process.
8. Move to the next task without letting either controller or worker context grow without bound.

## Recommended design

Use a two-layer model:

* **Controller agent**
  * Lives in OpenClaw.
  * Owns the loop state, progress file, and task ordering.
  * Receives Slack messages and decides the next iteration.
  * Never does the heavy implementation work itself.

* **Ephemeral worker**
  * Spawned per iteration.
  * Executes exactly one task.
  * Exits after validation.
  * Is deleted or archived immediately.

This gives you the isolation you want:

* Controller context stays small because it only stores plan, state, and summaries.
* Worker context stays small because each worker is short-lived and discarded after the iteration.

The design now also includes a hard preflight gate:

* No Ralph Loop task may start until environment checks pass.
* If preflight fails, the run ends immediately.
* The failure report and log paths are returned to Slack and written to disk.

## Which OpenClaw features fit this

### 1. Slack routing and reply threading

Slack sessions are routed by channel and can use reply threading controls.

Relevant behavior:

* channel sessions map to `agent:<agentId>:slack:channel:<channelId>`
* DMs can collapse to the agent main session
* `channels.slack.replyToMode` controls automatic threading
* `channels.slack.thread.initialHistoryLimit` controls how much thread history is loaded for a new thread session

Use this for the controller conversation, not for long-lived worker state.

Reference:

* [Slack](https://docs.openclaw.ai/channels/slack)
* [Session Management](https://docs.openclaw.ai/concepts/session)

### 2. Agent loop serialization

OpenClaw agent runs are serialized per session key.

That means the controller can safely own the long-running loop state while avoiding concurrent mutation of the same session lane.

Reference:

* [Agent Loop](https://docs.openclaw.ai/concepts/agent-loop)

### 3. Session pruning

Session pruning trims old tool results from in-memory context before LLM calls.

This is useful for the controller if it will run for many hours and accumulate tool output.

For long-running controller sessions:

* enable pruning
* keep only a small number of recent assistant turns
* prefer TTL-aware pruning for cache-bound providers

Reference:

* [Session Pruning](https://docs.openclaw.ai/concepts/session-pruning)

### 4. Loop detection

OpenClaw can detect repetitive tool loops and dampen or block the next tool-cycle.

This is a good guardrail for a Ralph Loop controller because it protects against accidental retry storms.

Reference:

* [Tool-loop detection](https://docs.openclaw.ai/tools/loop-detection)

### 5. Short-lived worker sessions

For each iteration, use a worker that is:

* spawned for one task
* run with a timeout
* cleaned up or archived immediately

OpenClaw sub-agent docs support:

* `runTimeoutSeconds`
* `thread: true`
* `mode: "session"` for thread-bound follow-up
* `cleanup: "delete"` or `cleanup: "keep"`

For your use case, default the worker to a run-style session, not a persistent one.

Reference:

* [Sub-Agents](https://docs.openclaw.ai/tools/subagents)

## Configuration strategy

### Controller session

Use a controller session that is persistent enough to last the full 24-hour loop, but bounded by pruning and reset rules.

Suggested controls:

* Keep the controller on a dedicated Slack channel or DM.
* Enable reply threading so the conversation stays scoped.
* Set a sensible idle timeout so a dead loop resets instead of lingering forever.
* Enable session maintenance with pruning and capped retention.
* Enable loop detection.

Important: the controller should not accumulate full tool results forever. Store only:

* current task id
* completed task ids
* current plan pointer
* validation result summary
* file list changed in the last iteration

### Worker session

Use a per-iteration worker that is explicitly short-lived.

Suggested controls:

* `runTimeoutSeconds` for hard kill on each iteration
* `cleanup: "delete"` if you want immediate archival after completion
* sandboxed execution when possible
* a narrow allowlist of tools
* no long-lived thread binding unless you truly need it

### Example shape

```ts
{
  session: {
    maintenance: {
      mode: "enforce",
      pruneAfter: "30d",
      maxEntries: 500,
      rotateBytes: "10mb",
    },
  },
  tools: {
    loopDetection: {
      enabled: true,
      historySize: 20,
      warningThreshold: 3,
      criticalThreshold: 6,
      globalCircuitBreakerThreshold: 8,
    },
  },
  channels: {
    slack: {
      enabled: true,
      replyToMode: "all",
      thread: {
        initialHistoryLimit: 10,
      },
    },
  },
  agents: {
    defaults: {
      contextPruning: {
        mode: "cache-ttl",
        ttl: "5m",
      },
      subagents: {
        runTimeoutSeconds: 1800,
        archiveAfterMinutes: 0,
      },
    },
  },
}
```

This is a design sketch, not a copy-paste guarantee. Tune it to your actual channel and runtime support.

## Operating model

### Phase 0: environment preflight

Before any formal task execution, the controller must run a dedicated preflight worker.

The preflight worker validates:

1. Required text inputs exist and are readable.
2. The workspace supports both read and write access.
3. A worker can execute a simple command and return stdout, stderr, and exit status.
4. A worker can perform a temporary write and cleanup cycle.

Recommended checks:

* read `plan.md` and required `reference/*.md`
* create a temporary file under a dedicated scratch path
* write a known string into that file
* read the file back and verify contents
* delete the file
* run a simple command such as `pwd`, `echo`, or `true`

Artifacts:

* `logs/preflight/<run_id>.log`
* a short status record in `progress.md`

If preflight fails:

* the Ralph Loop does not start
* the run enters `FAILED_PRECHECK`
* the controller sends a failure summary and log path back to Slack
* no task worker is launched

If preflight succeeds:

* the run enters `READY`
* the controller announces that formal task execution may begin

### Phase 1: bootstrap

1. User sends a Slack message.
2. Controller agent reads the plan document.
3. Controller creates or resumes a session for the loop.
4. Controller runs the preflight worker.
5. Controller writes a progress file with the initial task list only if preflight passes.

### Phase 2: one Ralph iteration

1. Controller picks exactly one task.
2. Controller spawns a worker for that task.
3. Worker searches the codebase.
4. Worker implements one change only.
5. Worker runs build/test/lint/typecheck as needed.
6. Worker returns a compact summary.
7. Controller records the result.
8. Worker session is terminated or archived.
9. If the task failed, the controller persists the failure log path for any later retry.

### Phase 3: repeat

1. Controller chooses the next highest-priority task.
2. Repeat until all tasks pass or the 24-hour budget ends.

### Phase 4: stop conditions

Stop the loop when:

* the task list is empty
* the 24-hour budget is reached
* the controller hits a circuit breaker
* validation repeatedly fails on the same boundary
* preflight fails
* a task enters a non-retryable blocked state

## How to keep controller context from exploding

The main risk is not the worker. It is the controller accumulating too much history.

Use these rules:

* Write task state to a file, not to the prompt.
* Keep the controller prompt short and stable.
* Feed only the current task plus a compact progress summary into the worker.
* Prune old tool results.
* Save detailed logs to disk, not in conversation context.
* Summarize each iteration before moving on.
* Pass log paths, not raw logs, between iterations.

If you need a durable history, store it as structured notes in `reference/` or a session progress file, not as raw transcript.

## How to keep the worker process from exploding

For each worker:

* give it one task
* give it one workspace
* give it one timeout
* give it a tight tool allowlist
* kill it after the result is returned
* persist its execution log even on failure

The worker should never be the thing that owns the 24-hour budget.

## Good control files

Use separate files for separate responsibilities:

* `plan.md` for the task list
* `progress.md` for iteration state
* `human-review.md` for manual checks
* `logs/` for raw output if needed
* `logs/preflight/` for environment validation runs
* `logs/tasks/<task-id>/attempt-<n>.log` for task execution history

Do not keep the full history in the live prompt.

## Logging and retry model

Every failed preflight or task attempt must leave a durable log artifact on disk.

Recommended metadata per task attempt:

* `task_id`
* `attempt`
* `status`
* `started_at`
* `ended_at`
* `worker_id` or process id
* `log_path`
* `validation_summary`

The controller should write that metadata into `progress.md` or a structured run-state file.

## Retry semantics

Retries must be meaningful, not blind.

For a retried task:

1. The controller increments `attempt`.
2. The controller launches a fresh worker, not the previous worker.
3. The controller passes the new worker:
4. the current task description
5. the current relevant files
6. the attempt number
7. the log path or log paths from previous failed attempts
8. a short failure summary from the previous attempt
9. The worker reads those logs before starting implementation.

This is the minimum contract for iterative recovery.

## Preflight failure policy

Preflight is a hard gate.

If preflight fails:

* do not auto-continue into task execution
* do not consume the task retry budget
* mark the run as failed before work starts
* return the exact failed check and the log path to Slack

The user must fix the environment and explicitly restart the run.

## Task failure policy

Task failures split into three categories:

* retryable execution failure
* blocked failure requiring human intervention
* fatal failure ending the run

For retryable execution failures:

* create a new worker
* pass previous log paths forward
* cap retries per task

For blocked or fatal failures:

* stop creating new workers
* record the final error state
* notify Slack with the log path and reason

## Recommended OpenClaw settings for this pattern

* Slack reply threading on for the controller conversation
* Session pruning enabled for the controller
* Session maintenance enforced
* Loop detection enabled
* Worker run timeout set
* Worker cleanup set to delete or archive
* Thread binding only where it adds value

## Important caveat

OpenClaw’s docs are strong on session routing, thread binding, pruning, and loop detection.

They do not describe this exact 24-hour Ralph Loop pattern as a built-in turnkey feature. So this design is an inference built from the documented primitives:

* serialized agent loops
* session persistence
* session pruning
* thread binding
* short-lived sub-agents
* proactive message send

That means the implementation should treat the controller as a small orchestration layer, not a giant conversational brain.

## Documentation to keep nearby

* [Agent Loop](https://docs.openclaw.ai/concepts/agent-loop)
* [Session Management](https://docs.openclaw.ai/concepts/session)
* [Session Pruning](https://docs.openclaw.ai/concepts/session-pruning)
* [Tool-loop detection](https://docs.openclaw.ai/tools/loop-detection)
* [Sub-Agents](https://docs.openclaw.ai/tools/subagents)
* [Slack](https://docs.openclaw.ai/channels/slack)
* [message CLI](https://docs.openclaw.ai/cli/message)
