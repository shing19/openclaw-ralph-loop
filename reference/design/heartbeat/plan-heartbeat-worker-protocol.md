# Heartbeat Worker Protocol

This document defines the runtime contract for the heartbeat workers.

The heartbeat design is not complete unless the worker layer is specified as tightly as the controller layer.

## Purpose

The worker protocol exists to prevent three classes of failure:

* wrapper drift, where the controller launches a worker but the worker no longer knows how to call its runtime correctly
* meaningless retries, where the same non-fixable failure repeats with no new information
* evidence gaps, where a worker exits without durable logs, result files, or progress updates

## Worker types

Recommended first-pass workers:

* `ralph-plan-check`
* `ralph-preflight`
* `ralph-run-task`

All three workers must:

* be launched as fresh processes
* write a durable log
* write a result file
* exit cleanly with a deterministic result contract

## Shared worker contract

Every worker invocation should receive explicit file paths and identifiers.

Minimum shared inputs:

* `runId`
* `project`
* `projectRoot`
* `planPath`
* `progressPath`
* `logPath`
* `resultPath`

Minimum shared outputs:

* durable log at `logPath`
* structured result JSON at `resultPath`
* explicit `status`
* explicit `startedAt`
* explicit `endedAt`

## Task worker contract

`ralph-run-task` should receive at least:

* `runId`
* `project`
* `projectRoot`
* `taskId`
* `attempt`
* `taskDescription`
* `planStatePath`
* `progressPath`
* `validationCommands`
* `logPath`
* `resultPath`
* `priorFailureSummary`
* `priorLogPathsRecent`
* `retryBudgetRemaining`

Recommended rule:

* `priorLogPathsRecent` should include only the most recent 5 log paths
* older failures should be condensed into `priorFailureSummary`

## Runtime smoke test requirements

Preflight is not sufficient if it only proves that the machine can run arbitrary shell commands.

The worker protocol must validate the actual task runtime.

Recommended rule:

* `ralph-preflight` must verify that the exact task runtime wrapper works
* if the task worker depends on `codex`, preflight must run a `codex` smoke test through the same wrapper path and argument shape that `ralph-run-task` will use

Examples of valid smoke tests:

* `codex exec --help`
* a minimal non-destructive one-line `codex exec` run

Examples of invalid smoke tests:

* `echo hello`
* calling a different binary than the real task worker will use

If the runtime smoke test fails:

* classify the failure as `worker_contract` or `tooling_config`
* mark it non-retryable
* stop before task execution

## Progress requirements

The task worker must treat `progress.md` as a gate, not as an optional note.

Before work starts, `ralph-run-task` must:

1. read `progress.md`
2. check for unresolved issues related to:
3. the same `taskId`
4. project-wide environment or tooling failures
5. prior fatal or blocked outcomes that were not resolved

If unresolved blocking issues exist:

* do not continue with normal task execution
* return a non-retryable result or a `blocked` result
* point to the unresolved progress entry

After work finishes, `ralph-run-task` must update `progress.md` before exit:

* on success, record completion summary and evidence paths
* on failure, record failure summary, failure class, and log path

## Failure classification

Every failed worker result must include a `failureClass`.

Recommended classes:

* `validation`
* `transient_exec`
* `external_dependency`
* `worker_contract`
* `tooling_config`
* `environment`
* `input_contract`
* `state_integrity`
* `interrupted`
* `blocked_human`
* `unknown`

Recommended retry policy by class:

* `validation`: retryable
* `transient_exec`: retryable
* `external_dependency`: retryable with small budget
* `worker_contract`: non-retryable
* `tooling_config`: non-retryable
* `environment`: non-retryable
* `input_contract`: non-retryable
* `state_integrity`: non-retryable
* `interrupted`: non-retryable until controller reconcile decides otherwise
* `blocked_human`: non-retryable until operator action
* `unknown`: retry once at most, then escalate

## Interruption protocol

Task workers must support best-effort cleanup on abnormal termination.

Recommended rule:

* `ralph-run-task` must install cleanup traps for `SIGTERM`, `SIGINT`, and shell `EXIT`
* cleanup must be idempotent
* cleanup must not assume the main runtime exited normally

Minimum best-effort cleanup responsibilities:

* write a failure result if no final result exists yet
* update `progress.md` with an interrupted entry and log path
* annotate the result with `failureClass: interrupted`
* include `exitCause` when known, for example `sigterm`, `sigint`, `oom_kill`, or `shell_exit`
* release or mark stale the task-attempt lock if the worker owns it

Recommended shape for an interrupted result:

```json
{
  "taskId": "T023",
  "attempt": 1,
  "status": "failed",
  "retryable": false,
  "failureClass": "interrupted",
  "exitCause": "sigterm",
  "errorFingerprint": "worker-interrupted-sigterm",
  "summary": "Worker was interrupted before it could write a normal result.",
  "progressUpdated": true,
  "progressPath": "/home/shing/.openclaw/projects/project-a/progress.md",
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/T023/attempt-1.log",
  "startedAt": "2026-03-24T00:39:00Z",
  "endedAt": "2026-03-24T00:53:00Z"
}
```

Worker-side cleanup is best-effort only.

The controller must still assume cleanup can be skipped entirely if the worker is killed hard enough.

## Error fingerprint

Every failed task result should also include:

* `errorFingerprint`

This should be a stable identifier for the failure family.

Examples:

* `codex-cli-unknown-flag`
* `missing-progress-file`
* `typecheck-src-foo-ts`
* `worker-interrupted-sigterm`

The retry system should budget both:

* by task attempt count
* by repeating `errorFingerprint`

Recommended first-pass rule:

* total task retries capped at 3
* same `errorFingerprint` may repeat at most 1 time before escalation

## Task result schema extensions

Recommended successful task result:

```json
{
  "taskId": "T022",
  "attempt": 1,
  "status": "success",
  "retryable": false,
  "summary": "Completed task T022 and passed validation.",
  "changedFiles": [
    "src/example.ts"
  ],
  "validation": {
    "tests": "passed",
    "lint": "passed"
  },
  "progressUpdated": true,
  "progressPath": "/home/shing/.openclaw/projects/project-a/progress.md",
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/T022/attempt-1.log",
  "startedAt": "2026-03-24T10:00:00Z",
  "endedAt": "2026-03-24T10:10:00Z"
}
```

Recommended failed task result:

```json
{
  "taskId": "T022",
  "attempt": 2,
  "status": "failed",
  "retryable": false,
  "failureClass": "worker_contract",
  "errorFingerprint": "codex-cli-unknown-flag",
  "summary": "Task worker could not invoke codex with the configured arguments.",
  "progressUpdated": true,
  "progressPath": "/home/shing/.openclaw/projects/project-a/progress.md",
  "logPath": "/home/shing/.openclaw/projects/project-a/logs/tasks/T022/attempt-2.log",
  "startedAt": "2026-03-24T10:20:00Z",
  "endedAt": "2026-03-24T10:21:00Z"
}
```

## Commit metadata

Commit behavior is optional, but if enabled it must be explicit.

Recommended rule:

* if the run policy requires commits, the worker result must include `commit`
* if commit behavior is disabled, omit `commit`

Recommended shape:

```json
{
  "commit": {
    "enabled": true,
    "hash": "abc1234",
    "message": "Implement T022"
  }
}
```

## Required worker guarantees

The worker protocol is not satisfied unless all of these are true:

* worker always writes a log
* worker always writes a result or a synthetic failure result
* worker always updates `progress.md`
* worker always reads `progress.md` before task execution
* worker installs best-effort interruption cleanup
* worker never retries by itself
* worker never hides runtime invocation errors inside a generic retryable failure

## Recommended companion docs

Use this protocol together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-progress-protocol.md`
