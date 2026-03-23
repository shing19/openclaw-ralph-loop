# Heartbeat Controller Spec

This document defines the behavior contract for the heartbeat-based Ralph Loop controller.

The controller is a scheduler, not a coding worker.

## Purpose

The controller exists to:

* discover or load project metadata
* register and track runs
* validate and normalize plans
* run preflight before task work
* launch fresh workers
* poll running workers
* record state transitions
* report meaningful progress to the correct Slack thread

The controller must not do implementation work directly.

## Core invariants

These rules are mandatory:

1. The controller does at most one launch action per run per heartbeat tick.
2. The controller never waits synchronously for a worker to finish.
3. `TASK_RUNNING` is a polling state, not a work state.
4. The controller never relaunches the same `task_id + attempt` while its lock is still valid.
5. The controller always reads state from disk before deciding anything.
6. The controller always writes updated state before exiting the turn.
7. The controller never uses Slack conversation history as the source of truth.
8. The controller must not execute tasks from raw `plan.md` until plan normalization succeeds.

## Turn model

Each heartbeat turn should be short and deterministic.

Per turn, the controller may:

* read registry files
* launch a plan-check worker
* absorb completed worker results
* launch a preflight worker
* launch a task worker
* update state
* send reports

Per turn, the controller must not:

* implement code
* run a whole task itself
* perform multiple retries for the same task
* block for long-running worker execution

The kickoff chat turn is not a worker-launch turn.

Its job is to:

* resolve project context
* resolve document paths
* register the project if needed
* create the run
* return an acknowledgment

It should leave execution to later heartbeat turns.

## Inputs per turn

The controller should reconstruct state from:

* `state/projects/*.json`
* `state/runs/*.json`
* `state/locks/*`
* `progress.md`
* `state/current-task/<run-id>.json`
* result files under `results/`
* log files under `logs/`

At kickoff, the controller should also resolve project paths from:

* explicit `project=<slug>`
* explicit `docs=...`
* explicit absolute paths
* current channel registration mapping

## Behavior by run state

### `IDLE`

Do nothing.

### `PLAN_CHECK_PENDING`

If no plan-check worker is active:

* create lock
* launch one fresh plan-check worker
* move to `PLAN_CHECK_RUNNING`

### `PLAN_CHECK_RUNNING`

* check result file
* if complete, absorb result
* if still running, update `lastCheckedAt` and move on

### `PLAN_READY`

* move to `PRECHECK_PENDING`

### `PLAN_INVALID`

Do not launch more work.

### `PRECHECK_PENDING`

If no preflight worker is active:

* create lock
* launch one fresh preflight worker
* move to `PRECHECK_RUNNING`

### `PRECHECK_RUNNING`

* check result file
* if complete, absorb result
* if still running, update `lastCheckedAt` and move on

### `READY`

* select next runnable task
* move to `TASK_READY`

### `TASK_READY`

If no active task attempt lock exists:

* read `progress.md`
* check for unresolved blocking issues
* verify that the selected task has no unresolved fatal or blocked prior entry
* verify that completed prior tasks have durable result evidence
* launch one fresh task worker
* move to `TASK_RUNNING`

### `TASK_RUNNING`

* check result file
* if result exists, absorb it
* if process is still alive, update `lastCheckedAt`
* do not relaunch the same task

### `TASK_RETRY_WAIT`

If retry delay has elapsed and retry budget remains:

* read `progress.md`
* inspect the last failure class and error fingerprint
* if the failure is non-retryable, move to `WAIT_HUMAN` or `FAILED_FATAL`
* if the same error fingerprint already exhausted its budget, move to `WAIT_HUMAN` or `FAILED_FATAL`
* if unresolved blocking issues remain in progress, do not relaunch
* otherwise promote back to `TASK_READY`

### `WAIT_HUMAN`

Do not auto-progress.

Only process:

* status requests
* watcher updates
* explicit operator commands

### `DONE`

Do not launch more work.

### `FAILED_PRECHECK`

Do not launch more work.

### `FAILED_FATAL`

Do not launch more work.

### `CANCELLED`

Do not launch more work.

## Polling behavior

Polling is the heartbeat controller's most important behavior.

When a task is still running:

1. Check whether the task result file exists.
2. If it does not, check whether the worker process is still alive.
3. If it is still alive, write `lastCheckedAt`.
4. Leave the run in `TASK_RUNNING`.
5. Move on to other runs.

The controller must not interpret "still running" as "needs relaunch".

## Reporting behavior

The controller should only send operator-facing messages when:

* kickoff succeeds
* registration fails
* plan validation fails
* preflight fails
* a task completes
* a task enters retry with useful context
* a run enters `WAIT_HUMAN`
* a run finishes
* a run is cancelled
* an explicit `status` command is issued

Routine no-op heartbeat ticks should not emit user-visible messages.

Kickoff success messages should clearly state:

* the resolved project
* the resolved plan path
* the `runId`
* the next state, usually `PLAN_CHECK_PENDING`

## Delivery model

Heartbeat should not rely on `target: "last"` for reporting.

Instead:

* each run stores its own `reportTarget`
* each report is sent explicitly to that target

## Retry behavior

Retries must be meaningful.

On retry:

* launch a fresh worker
* increment `attempt`
* pass prior failure log paths
* pass the prior failure summary
* pass only a bounded recent log list plus a condensed summary
* require the worker to read the old logs before it starts
* require the worker to read `progress.md` before it starts

## Failure classification behavior

The controller must not treat all failed task results the same.

Recommended rule:

* `validation`, `transient_exec`, and some `external_dependency` failures may be retried
* `worker_contract`, `tooling_config`, `environment`, `input_contract`, and `state_integrity` failures must not enter blind retry
* `interrupted` failures must trigger reconcile and explicit state transition, not indefinite `TASK_RUNNING`
* `blocked_human` should move directly to `WAIT_HUMAN`

If a failure is non-retryable:

* stop launching task workers
* write the blocking reason to run state
* report the exact failure class and log path

## Budget behavior

At the start of every heartbeat turn:

* check `budgetUntil`

If the budget has expired:

* do not launch new workers
* allow only result absorption and final reporting
* move the run to `CANCELLED` or `WAIT_HUMAN` depending on policy

## No-op heartbeat response

If a heartbeat turn finds no actionable work, the controller should return:

```text
HEARTBEAT_OK
```

This keeps idle ticks quiet and cheap.

## `HEARTBEAT.md` template

The project-wide `HEARTBEAT.md` should stay short and operational.

Recommended template:

```md
You are the Ralph Loop heartbeat controller.

On every heartbeat:
- Read the run registry and project registry from disk.
- Reconstruct state before deciding anything.
- Perform at most one launch action per run.
- Never wait for a worker to finish.
- Treat TASK_RUNNING as poll-only.
- Never relaunch the same task attempt while its lock exists.
- Report only meaningful state changes.
- If there is no actionable work, respond with HEARTBEAT_OK.
```

## Recommended companion docs

This spec should be used together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-operator-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-plan-normalization.md`
