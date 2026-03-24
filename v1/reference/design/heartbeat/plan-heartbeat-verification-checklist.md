# Heartbeat Verification Checklist

This document is the acceptance and debug checklist for the heartbeat plan.

Every change to the heartbeat architecture, controller behavior, worker wrapper, or Slack integration should pass this checklist.

Every debugging session should start from this checklist, identify the first failed checkpoint, and only then move into a code fix.

## Purpose

This checklist exists to answer one question:

Can the heartbeat plan reliably accept a run, execute bounded work, persist authoritative state, and report the right result back to the operator?

It is not only a QA document.

It is also:

* an implementation acceptance checklist
* a regression checklist after every optimization
* a debugging entrypoint when the system behaves incorrectly

## How to use it

Use the checklist in this order:

1. configuration and wiring
2. kickoff and registration
3. plan normalization
4. preflight
5. task execution
6. polling and re-entry
7. retry and failure handling
8. completion and reporting

For each checkpoint, record:

* pass or fail
* evidence path
* observed state
* next action

Recommended evidence sources:

* `state/projects/*.json`
* `state/runs/*.json`
* `state/current-task/<run-id>.json`
* `state/plan-state.json`
* `progress.md`
* `results/plan-check/*.json`
* `results/preflight/*.json`
* `results/tasks/*/attempt-*.json`
* `logs/plan-check/*.log`
* `logs/preflight/*.log`
* `logs/tasks/*/attempt-*.log`
* Slack thread messages
* git status and commit history, if commit behavior is enabled

## Global acceptance rule

A run is not considered healthy unless all of these are true:

* configuration is loaded
* kickoff creates the right run state
* plan normalization succeeds or fails cleanly
* preflight succeeds or fails cleanly
* worker execution is observable on disk
* progress is persisted outside session memory
* reporting reaches the correct Slack thread
* failures leave logs and deterministic state
* retries inherit prior failure logs
* no duplicate worker launch happens for one task attempt
* non-retryable failure classes do not enter blind retry

## Phase 1: Configuration and wiring

### Check 1.1: Heartbeat configuration is loaded

Pass criteria:

* heartbeat is enabled for the controller
* heartbeat uses bounded context
* heartbeat does not rely on Slack thread history as source of truth

Expected evidence:

* controller config file
* `HEARTBEAT.md`
* controller startup logs

Failure examples:

* heartbeat never wakes
* heartbeat wakes but runs with the wrong agent identity
* heartbeat wakes but has no access to state files

### Check 1.2: Required file paths are writable

Pass criteria:

* controller can read and write `state/`, `logs/`, and `results/`
* project root, `progress.md`, and plan files are readable

Expected evidence:

* preflight logs
* newly created registry files

Failure examples:

* run creation succeeds but no files appear on disk
* worker result files never materialize

### Check 1.3: Slack routing is wired

Pass criteria:

* kickoff message reaches the controller
* controller can send acknowledgment back to the same Slack thread

Expected evidence:

* kickoff thread contains the acknowledgment
* run record contains the correct `reportTarget`

Failure examples:

* run is created but operator never sees an acknowledgment
* reports go to the wrong channel or wrong thread

## Phase 2: Kickoff and registration

### Check 2.1: Project context resolves correctly

Pass criteria:

* project root is resolved from one of the supported sources:
* `project=<slug>`
* `docs=...`
* explicit absolute paths
* current channel registration mapping

Expected evidence:

* `state/projects/<project>.json`
* kickoff acknowledgment

Failure examples:

* relative paths are interpreted against the wrong root
* channel registration exists but is ignored
* controller guesses a root from unrelated working-directory state

### Check 2.2: Kickoff only creates state and does not launch work

Pass criteria:

* kickoff creates or updates project and run records
* run moves to `PLAN_CHECK_PENDING`
* no plan-check, preflight, or task worker is launched in the kickoff chat turn

Expected evidence:

* `state/runs/<run-id>.json`
* absence of a fresh worker process launched directly from the chat turn
* acknowledgment says next step is plan check

Failure examples:

* kickoff immediately starts a worker
* kickoff jumps directly to `PRECHECK_PENDING` or `TASK_READY`

### Check 2.3: Kickoff acknowledgment is complete

Pass criteria:

* acknowledgment includes project slug
* acknowledgment includes resolved root
* acknowledgment includes plan path
* acknowledgment includes `runId`
* acknowledgment includes next state

Expected evidence:

* Slack acknowledgment message

Failure examples:

* operator cannot tell which project root was chosen
* operator cannot tell whether work has actually started

## Phase 3: Plan normalization

### Check 3.1: Plan-check worker is launched

Pass criteria:

* a fresh plan-check worker is launched on heartbeat after kickoff
* run moves to `PLAN_CHECK_RUNNING`

Expected evidence:

* run state transition
* plan-check worker log

Failure examples:

* run stays in `PLAN_CHECK_PENDING`
* worker never launches

### Check 3.2: Plan-check writes artifacts

Pass criteria:

* `results/plan-check/<run-id>.json` exists
* `logs/plan-check/<run-id>.log` exists
* `state/plan-state.json` exists on success

Expected evidence:

* plan-check result file
* normalized plan file

Failure examples:

* worker exits but result file is missing
* result exists but normalized plan file is missing

### Check 3.3: Invalid plan fails cleanly

Pass criteria:

* invalid plan moves run to `PLAN_INVALID`
* no preflight worker is launched afterward
* operator receives a useful failure message

Expected evidence:

* failed plan-check result
* Slack failure report

Failure examples:

* controller continues to preflight after plan-check failure
* failure report does not say why the plan was rejected

## Phase 4: Preflight

### Check 4.1: Preflight only starts after plan is ready

Pass criteria:

* controller reaches `PLAN_READY` first
* then moves to `PRECHECK_PENDING`

Expected evidence:

* run state transitions in order

Failure examples:

* preflight starts before plan normalization finishes

### Check 4.2: Preflight validates environment capability

Pass criteria:

* required docs are readable
* workspace read/write is verified
* worker can execute a simple command and return status
* worker can write, read back, and delete a temp file
* worker runtime wrapper smoke test passes with the real task runtime

Expected evidence:

* `results/preflight/<run-id>.json`
* `logs/preflight/<run-id>.log`

Failure examples:

* preflight passes without proving file write/delete
* preflight passes but worker execution is not actually available
* preflight passes but the real `codex` worker contract still fails immediately

### Check 4.3: Preflight failure is terminal for the run

Pass criteria:

* failed preflight moves run to `FAILED_PRECHECK`
* no task worker launches after failed preflight
* operator receives explicit failure reason and log path

Expected evidence:

* run state
* failure message

Failure examples:

* task execution starts after failed preflight
* failure message omits the actual error

## Phase 5: Task execution

### Check 5.1: Next task comes from normalized plan

Pass criteria:

* task selection uses `state/plan-state.json`
* controller does not re-interpret raw `plan.md` each turn

Expected evidence:

* selected `taskId` exists in `state/plan-state.json`
* run state and current task file align with normalized plan

Failure examples:

* task ids drift between turns
* controller selects a task that is not in normalized state

### Check 5.2: Worker launch is bounded and locked

Pass criteria:

* controller creates one task-attempt lock
* one fresh worker is launched
* run moves to `TASK_RUNNING`
* duplicate launch of the same `taskId + attempt` does not happen

Expected evidence:

* `state/locks/<task-id>.attempt-<n>.lock`
* `state/current-task/<run-id>.json`

Failure examples:

* the same task attempt is launched twice
* no lock exists for a running task

### Check 5.3: Worker execution leaves durable evidence

Pass criteria:

* task log file exists
* task result file exists
* changed files are listed in the result
* validation results are listed in the result

Expected evidence:

* `results/tasks/<task-id>/attempt-<n>.json`
* `logs/tasks/<task-id>/attempt-<n>.log`

Failure examples:

* code changed but no result file exists
* result file exists but has no validation status

### Check 5.4: Progress is updated after task completion

Pass criteria:

* `progress.md` reflects the new task outcome
* run state advances correctly after result absorption
* failure outcomes are also reflected in `progress.md` with log paths

Expected evidence:

* updated `progress.md`
* updated run record

Failure examples:

* code changes landed but `progress.md` is stale
* task result was absorbed but run state did not move
* task failed but there is no corresponding progress entry with a log path

### Check 5.5: Commit behavior is verified if enabled

This is conditional.

Pass criteria:

* if the run policy says tasks or runs should create git commits, a commit hash is recorded
* if commit behavior is disabled, no commit is required

Expected evidence:

* git log
* run metadata or task result metadata containing commit hash

Failure examples:

* workflow claims to commit but no commit exists
* commit exists but result/report does not mention it when policy requires it

## Phase 6: Polling and re-entry

### Check 6.1: Running tasks are polled, not relaunched

Pass criteria:

* on a later heartbeat, a still-running task stays in `TASK_RUNNING`
* controller updates `lastCheckedAt`
* controller does not launch the same task attempt again

Expected evidence:

* `state/current-task/<run-id>.json`
* stable task-attempt lock

Failure examples:

* every heartbeat spawns another worker
* current task file gets overwritten with a new attempt while the old one still runs

### Check 6.2: Worker exit triggers fast absorption

Pass criteria:

* background worker exit causes prompt heartbeat follow-up
* result is absorbed without waiting for a long idle interval

Expected evidence:

* controller logs
* close timing between worker result write and run state transition

Failure examples:

* worker finishes but controller does not react until much later

## Phase 7: Retry and failure handling

### Check 7.1: Every failure leaves a log

Pass criteria:

* failed plan-check leaves a log
* failed preflight leaves a log
* failed task attempt leaves a log

Expected evidence:

* corresponding files under `logs/`

Failure examples:

* failure is visible in Slack but there is no disk log to inspect

### Check 7.2: Retryable failures enter bounded retry flow

Pass criteria:

* retryable task failure moves to `TASK_RETRY_WAIT`
* retry budget is decremented
* retry does not happen before backoff expires
* non-retryable failure classes do not re-enter retry

Expected evidence:

* run state
* retry metadata in run/task result

Failure examples:

* task failure triggers immediate uncontrolled relaunch
* retry count is not tracked
* worker-contract or environment failures are retried anyway

### Check 7.3: Next worker inherits prior failure logs

Pass criteria:

* new worker receives attempt number
* new worker receives prior log path list
* new worker is told to read prior failure evidence before acting
* new worker reads `progress.md` before acting

Expected evidence:

* task launch payload
* new attempt log referencing prior log paths

Failure examples:

* retry starts from zero context
* controller forgets previous failure logs
* retry ignores unresolved blocking entries in `progress.md`

### Check 7.4: Reporting failure does not rerun execution

Pass criteria:

* if Slack reporting fails, task result remains authoritative
* controller retries reporting only
* controller does not rerun the worker just because notification failed

Expected evidence:

* task result file already exists
* reporting retry log

Failure examples:

* notification error causes duplicate code execution

## Phase 8: Completion and operator visibility

### Check 8.1: Per-round report is sent when required

Pass criteria:

* task completion reports are sent when report policy says they should be
* retry or blocked reports include useful context
* final completion or failure report is always sent

Expected evidence:

* Slack thread messages

Failure examples:

* work finishes but operator never sees result
* report omits current task, next action, or log path

### Check 8.2: Completion leaves the run in a stable terminal state

Pass criteria:

* final run state is one of:
* `DONE`
* `FAILED_PRECHECK`
* `FAILED_FATAL`
* `CANCELLED`
* locks are cleared or archived
* no new workers launch afterward

Expected evidence:

* final run record
* absence of active task lock

Failure examples:

* terminal run keeps launching heartbeat work
* old task lock remains and blocks future work incorrectly

## Multi-project and multi-thread checks

### Check 9.1: One active run per project

Pass criteria:

* same project does not get two active runs at once
* later `start` attaches watcher or returns active run

Expected evidence:

* run registry
* Slack responses

Failure examples:

* same project starts competing runs in different channels

### Check 9.2: Results go to the correct thread

Pass criteria:

* each run stores its own `reportTarget`
* completion and failure messages are posted to the originating thread or attached watcher threads according to policy

Expected evidence:

* run record
* Slack thread history

Failure examples:

* project A result appears in project B channel

## Debug entrypoints by symptom

Use this table to find the first failing layer.

| Symptom | First place to inspect | Likely failure layer |
|---|---|---|
| No kickoff acknowledgment | Slack event handling, operator protocol, controller logs | routing or reporting |
| Kickoff ack exists but no run files | project registration path, file permissions | registration |
| Run stuck in `PLAN_CHECK_PENDING` | heartbeat wake-up, controller launch path | scheduling |
| Plan-check log exists but no result | worker wrapper or result write path | worker I/O |
| Preflight never starts | state transition `PLAN_READY -> PRECHECK_PENDING` | controller state machine |
| Preflight passed but task runtime still fails on first invocation | worker protocol or preflight smoke test | worker contract |
| Preflight passed but task never launches | task selection, lock creation, budget gate | scheduler |
| Task launches twice | lock handling, reconcile logic | duplicate launch protection |
| Worker disappeared and run still says `TASK_RUNNING` forever | interruption cleanup, stale lock handling, synthetic reconcile | crash recovery |
| Code changed but `progress.md` did not update | result absorption path | persistence |
| Infinite retry on same error | retry budget, failure classification, progress gate | retry control |
| Task failed but retry has no context | retry payload builder | retry inheritance |
| Slack report missing but task result exists | reporting path | notification only |
| Final state unclear after restart | reconcile algorithm and synthetic failure generation | crash recovery |

## Recommended test runs

Every meaningful change should run at least these scenarios:

1. happy path
2. invalid plan
3. failed preflight
4. one retryable task failure followed by successful retry
5. long-running task with at least one polling-only heartbeat
6. reporting failure after successful task execution
7. restart or reconcile while a task is in `TASK_RUNNING`
8. duplicate `start` for the same project from another channel
9. kill or restart during active task execution, with no normal result file written

## Acceptance record template

Use this template for each verification pass:

```text
Heartbeat verification run:
- date:
- operator:
- build/config version:
- project:
- runId:

Results:
- config and wiring:
- kickoff and registration:
- plan normalization:
- preflight:
- task execution:
- polling and re-entry:
- retry and failure handling:
- completion and reporting:

Failed checkpoints:
- checkpoint:
  evidence:
  observed:
  expected:
  action:
```
