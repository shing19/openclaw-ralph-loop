# Heartbeat State and Recovery Protocol

This document defines the on-disk state model, worker result format, retry rules, and crash recovery behavior for the heartbeat plan.

## Purpose

Heartbeat mode only works if disk state is authoritative.

The controller must be able to reconstruct the workflow from files, even after:

* gateway restart
* heartbeat skip
* worker timeout
* worker crash
* partial failure during reporting

## Authoritative files

Recommended authoritative files:

* `state/projects/<project>.json`
* `state/runs/<run-id>.json`
* `state/locks/<project>.lock`
* `state/locks/<run-id>.lock`
* `state/locks/<task-id>.attempt-<n>.lock`
* `state/plan-state.json`
* `progress.md`
* `results/plan-check/<run-id>.json`
* `results/preflight/<run-id>.json`
* `results/tasks/<task-id>/attempt-<n>.json`
* `logs/plan-check/<run-id>.log`
* `logs/preflight/<run-id>.log`
* `logs/tasks/<task-id>/attempt-<n>.log`

## Run states

Recommended run states:

* `IDLE`
* `PLAN_CHECK_PENDING`
* `PLAN_CHECK_RUNNING`
* `PLAN_READY`
* `PLAN_INVALID`
* `PRECHECK_PENDING`
* `PRECHECK_RUNNING`
* `READY`
* `TASK_READY`
* `TASK_RUNNING`
* `TASK_RETRY_WAIT`
* `WAIT_HUMAN`
* `PAUSED`
* `DONE`
* `FAILED_PRECHECK`
* `FAILED_FATAL`
* `CANCELLED`

## Task attempt schema

The heartbeat controller should not create task attempts until plan normalization succeeds.

## Plan-check result schema

Recommended success result:

```json
{
  "status": "success",
  "sourcePath": "/home/shing/.openclaw/projects/project-a/docs/vision/plan.md",
  "normalizedPath": "/home/shing/.openclaw/projects/project-a/state/plan-state.json",
  "taskCount": 12,
  "warnings": [
    "Generated stable ids because the plan did not include explicit task ids."
  ],
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/plan-check/run-20260323-001.log"
}
```

Recommended failure result:

```json
{
  "status": "failed",
  "sourcePath": "/home/shing/.openclaw/projects/project-a/docs/vision/plan.md",
  "reason": "Could not derive a stable executable task list from the plan.",
  "issues": [
    "No unambiguous task boundaries found.",
    "Multiple checklist styles conflict."
  ],
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/plan-check/run-20260323-001.log"
}
```

Recommended task result file:

```json
{
  "taskId": "task-2",
  "attempt": 1,
  "status": "success",
  "retryable": false,
  "summary": "Completed task-2 and passed validation.",
  "changedFiles": [
    "src/foo.ts",
    "src/bar.ts"
  ],
  "validation": {
    "build": "passed",
    "tests": "passed",
    "lint": "passed",
    "typecheck": "passed"
  },
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/task-2/attempt-1.log",
  "startedAt": "2026-03-23T10:00:00Z",
  "endedAt": "2026-03-23T10:10:00Z"
}
```

Recommended failed result file:

```json
{
  "taskId": "task-2",
  "attempt": 2,
  "status": "failed",
  "retryable": true,
  "failureType": "validation",
  "summary": "Typecheck failed after edits in src/foo.ts.",
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/task-2/attempt-2.log",
  "startedAt": "2026-03-23T10:20:00Z",
  "endedAt": "2026-03-23T10:28:00Z"
}
```

## Current-task schema

Recommended `state/current-task.json`:

```json
{
  "taskId": "task-2",
  "attempt": 1,
  "status": "TASK_RUNNING",
  "workerProcessId": "proc_abc123",
  "startedAt": "2026-03-23T10:00:00Z",
  "deadlineAt": "2026-03-23T10:30:00Z",
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/task-2/attempt-1.log",
  "resultPath": "/home/shing/.openclaw/projects/project-a/results/tasks/task-2/attempt-1.json",
  "lastCheckedAt": "2026-03-23T10:02:00Z"
}
```

## Lock semantics

Recommended rules:

* project lock prevents concurrent controller actions on one project
* run lock prevents concurrent lifecycle mutation of one run
* task-attempt lock prevents duplicate launch of the same task attempt

While a valid task-attempt lock exists:

* the same task attempt must not be relaunched
* heartbeat may only poll or reconcile

## Retry policy

Recommended defaults:

* `maxRetriesPerTask = 2`
* `retryBackoff = 5m`
* no retry for preflight unless explicitly forced by operator
* no automatic retry for failed plan check

Recommended behavior:

1. failed attempt writes result and log
2. controller records `attempt += 1`
3. controller moves to `TASK_RETRY_WAIT`
4. once backoff elapses, controller moves back to `TASK_READY`
5. fresh worker reads prior failure logs before work

## Budget policy

Recommended rule:

* budget is checked at the start of every heartbeat turn

If budget has expired:

* do not launch new workers
* allow result absorption and final reporting
* move the run to `CANCELLED` or `WAIT_HUMAN`

## Reconcile algorithm

On heartbeat after restart or uncertainty, reconcile in this order:

1. read `state/runs/<run-id>.json`
2. if the run is not `*_RUNNING`, stop
3. read `state/current-task.json`
4. check for a completed result file
5. if result file exists, absorb it and clear the task lock
6. if result file does not exist, check for the task-attempt lock
7. if lock exists, check pid or process handle if available
8. if process is alive, keep `TASK_RUNNING`
9. if process is not alive and no result exists, mark failure and create a synthetic failure result
10. if state is inconsistent, move to `WAIT_HUMAN`

## Synthetic failure result

If a worker disappears without a result file, the controller should create a synthetic failure result that includes:

* task id
* attempt number
* failure type
* inferred reason
* prior log path if any
* time of reconcile

This keeps recovery deterministic.

## Reporting failure policy

If task execution succeeded but reporting to Slack failed:

* do not rerun the task
* record the reporting failure separately
* retry reporting only

Execution and reporting are separate concerns.

## Recommended companion docs

This protocol should be used together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-operator-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-plan-normalization.md`
