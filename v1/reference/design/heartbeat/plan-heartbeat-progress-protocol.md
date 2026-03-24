# Heartbeat Progress Protocol

This document defines the required role of `progress.md` in the heartbeat plan.

`progress.md` is not just a human-readable log.

It is a required control file for:

* task visibility
* retry safety
* blocker detection
* recovery after restart

## Purpose

The heartbeat design needs a project-level memory file that survives:

* worker exit
* session pruning
* controller restart
* retry attempts

That file is `progress.md`.

If `progress.md` is missing or stale, the controller loses the ability to distinguish:

* unresolved environment problems
* repeated worker-contract failures
* successfully completed tasks with missing evidence

## Required rules

These rules are mandatory:

1. `progress.md` must exist before the first task worker launches.
2. Every task attempt must update `progress.md` before exit.
3. Every failure entry in `progress.md` must include the log path.
4. Every success entry in `progress.md` must include the result path.
5. The controller must read `progress.md` before launching any task or retry.
6. If `progress.md` records unresolved blocking issues, the controller must not launch more task work.

## Minimum structure

Recommended minimum sections:

```md
# Progress

## Current Run

## Completed Tasks

## Failed or Blocked Tasks

## Open Issues

## Attempt History
```

The exact markdown format may vary, but the information content must stay stable.

## Required entry fields

Each task attempt entry should record:

* `timestamp`
* `runId`
* `taskId`
* `attempt`
* `status`
* `summary`
* `logPath`
* `resultPath`
* `failureClass`, if failed
* `errorFingerprint`, if failed
* `resolved`, if it represents an issue
* `nextAction`

## Success entry requirements

On success, the worker should write:

* task id
* attempt number
* completion summary
* result path
* validation summary
* changed files summary

The controller should then be able to confirm:

* the task is complete in `progress.md`
* the result file exists
* the normalized plan can be advanced

## Failure entry requirements

On failure, the worker must write:

* task id
* attempt number
* failure summary
* failure class
* error fingerprint
* log path
* whether the issue is retryable
* whether the issue is resolved

If the failure is clearly environmental or contractual:

* mark it unresolved
* mark it blocking
* require human or controller action before a new retry

## Progress gate behavior

Before launching a task or retry, the controller must inspect `progress.md` for:

* unresolved project-wide issues
* unresolved issues for the same task
* repeated failure fingerprints
* evidence gaps such as completed tasks without result files

If any of these exist, the controller must not continue blindly.

Recommended behavior:

* move to `WAIT_HUMAN` for unresolved external or environmental blockers
* move to `FAILED_FATAL` for state-integrity or worker-contract failures that make execution unsafe

## Evidence consistency checks

The controller should treat these as consistency violations:

* task marked complete in `progress.md` but no result file exists
* task marked failed in `progress.md` but no log file exists
* task marked retryable in result file but `progress.md` records unresolved blocking issue

Recommended behavior:

* do not launch more task work
* move to `WAIT_HUMAN` or `FAILED_FATAL`
* report the mismatch

## Missing progress file behavior

If `progress.md` is missing:

* kickoff may create an empty skeleton
* task execution must not start until the skeleton exists

If `progress.md` disappears mid-run:

* classify as `state_integrity`
* stop new task launches
* require reconcile or human intervention

## Retry interaction

On retry, the controller must read both:

* `progress.md`
* prior task result files

It is not enough to pass prior log paths alone.

The retry gate must answer:

* is the prior failure unresolved
* is the prior failure the same error fingerprint
* is the prior failure actually retryable
* did the system already exceed the retry budget for this failure family

## Recommended companion docs

Use this protocol together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-worker-protocol.md`
