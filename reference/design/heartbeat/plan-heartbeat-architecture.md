# OpenClaw Heartbeat Ralph Loop Architecture

This document describes a second full architecture for the Ralph Loop workflow.

The original design used a controller plus a re-entry layer outside the main agent turn. This design replaces that external re-entry mechanism with OpenClaw heartbeat turns.

## Goal

Use OpenClaw heartbeat as the scheduler for a long-running Ralph Loop workflow while preserving the same core guarantees:

* the controller does not accumulate unbounded context
* every task runs in a fresh worker process
* every failed attempt leaves durable logs
* retries inherit prior failure logs
* `progress.md` acts as a required retry gate
* the workflow can continue for many hours without one giant agent run
* multiple projects can be active at the same time
* results can be reported back to the originating Slack thread for each run

## What changes relative to the original plan

The original plan had:

* Slack kickoff
* controller agent
* short-lived worker
* external or separate re-entry layer to wake the controller again

The heartbeat plan changes only one major layer:

* the re-entry layer moves inside OpenClaw and becomes `agents.*.heartbeat`

That means:

* controller wake-ups become periodic heartbeat turns
* each controller turn is isolated and lightweight
* worker completion can request another heartbeat
* the system no longer depends on an external watchdog for normal progression

## Why this is viable in OpenClaw

OpenClaw heartbeat already supports the critical primitives this design needs:

* periodic agent turns
* `isolatedSession: true` for fresh heartbeat sessions with no prior conversation history
* `lightContext: true` to keep only `HEARTBEAT.md` from workspace bootstrap files
* per-agent heartbeat routing
* `HEARTBEAT_OK` suppression for no-op ticks
* background `exec` plus `process` polling
* `tools.exec.notifyOnExit` to request another heartbeat when a background process exits

This means the controller can behave like a bounded scheduler:

* wake
* read state files
* decide one next action
* launch or poll a worker
* read and update `progress.md` and state
* exit

## Architecture

### Layer 1: Slack control surface

Slack remains the operator interface.

It is used for:

* kickoff
* status updates
* failure reporting
* manual stop or override

It is not used as the durable state store.

It is also not used as the run registry.

Each run only stores a `reportTarget` pointing back to the originating channel and thread.

### Layer 2: Heartbeat controller

The controller is a dedicated OpenClaw agent with heartbeat enabled.

Its job is only to:

* read the run state
* validate and normalize the raw plan
* decide what phase the workflow is in
* launch preflight or task workers
* poll running workers
* update `progress.md` and run-state files
* report meaningful state changes

It should not do implementation work directly.

### Layer 3: Fresh worker process

Each task runs in a fresh external worker process.

Recommended worker shape:

* a wrapper script executed by OpenClaw `exec`
* the wrapper launches `codex` or another coding runtime
* stdout and stderr are redirected to a durable log file
* the wrapper writes a small result file on completion
* the wrapper reads `progress.md` before task work
* the wrapper updates `progress.md` before exit
* the wrapper exits

The controller never reuses a worker process across tasks.

### Layer 4: File-based state

Durable workflow state should live on disk, not in the controller transcript.

Recommended files:

* `HEARTBEAT.md`
* controller registry
* per-project config and state
* per-attempt logs and result files

Recommended layout:

```text
~/.openclaw/projects/
  _ralph-control/
    HEARTBEAT.md
    state/
      runs.json
      projects/
        <project>.json
      runs/
        <run-id>.json
      locks/
        <project>.lock
        <run-id>.lock
        <task-id>.attempt-<n>.lock
    logs/
      controller/
  <project-a>/
    docs/
    plan.md or docs/plan.md
    progress.md
    state/
    logs/
      plan-check/
      preflight/
      tasks/
    results/
      plan-check/
      preflight/
      tasks/
```

Recommended project-level files:

* `docs/`
* `plan.md` or `docs/plan.md`
* `progress.md`
* `state/plan-state.json`
* `logs/plan-check/<run_id>.log`
* `results/plan-check/<run_id>.json`
* `logs/preflight/<run_id>.log`
* `logs/tasks/<task-id>/attempt-<n>.log`
* `results/preflight/<run_id>.json`
* `results/tasks/<task-id>/attempt-<n>.json`

## Project registration model

Project registration should be automatic.

The operator should not need to pre-populate a registry file by hand.

### Kickoff forms

Recommended kickoff forms:

```text
@ralph-controller start docs=/abs/path/to/project/docs
```

```text
@ralph-controller start docs=/abs/path/to/project/docs plan=/abs/path/to/project/docs/my-plan.md
```

```text
@ralph-controller start project=<registered-project-slug>
```

If the current Slack channel is already registered to a project root, the controller should also accept a short kickoff that only provides relative document paths:

```text
Vision: docs/vision/vision.md
Plan: docs/vision/plan.md
```

### Discovery rules

If the kickoff provides `docs=...`, the controller should:

1. infer project root as the parent directory of `docs`
2. search for the plan file in this order:
3. `docs/plan.md`
4. `docs/PLAN.md`
5. `plan.md` at project root
6. `docs/*plan*.md`
7. search for project docs in this order:
8. `docs/vision.md`
9. `docs/README.md`
10. `docs/project.md`
11. `docs/design.md`

If exactly one plan candidate is found, register it automatically.

If no plan candidate is found, or more than one likely plan is found, stop and ask the operator for `plan=...`.

If the kickoff provides only relative paths, the controller should first try to resolve them against the current channel registration mapping.

If the current channel is not registered and no explicit `project=` or `docs=` is provided, registration should fail. The controller should not guess a project root from unrelated working-directory context.

### Registry entries

The controller should maintain two registries:

* a stable project registry
* an active run registry

Recommended project registry record:

```json
{
  "project": "project-a",
  "root": "/home/shing/.openclaw/projects/project-a",
  "docsDir": "/home/shing/.openclaw/projects/project-a/docs",
  "planPath": "/home/shing/.openclaw/projects/project-a/docs/plan.md",
  "progressPath": "/home/shing/.openclaw/projects/project-a/progress.md",
  "logDir": "/home/shing/.openclaw/projects/project-a/logs",
  "resultDir": "/home/shing/.openclaw/projects/project-a/results",
  "registeredAt": "2026-03-23T12:00:00Z"
}
```

Recommended run registry record:

```json
{
  "runId": "run-20260323-001",
  "project": "project-a",
  "status": "PLAN_CHECK_PENDING",
  "reportTarget": {
    "channel": "slack",
    "to": "C123456",
    "threadTs": "1711111111.2222"
  },
  "budgetUntil": "2026-03-24T12:00:00Z",
  "createdAt": "2026-03-23T12:00:00Z"
}
```

## Multi-project scheduling

The controller should support multiple active runs at the same time.

It should not dedicate the entire heartbeat cycle to one Slack session.

### Scheduling model

Recommended first-pass scheduling policy:

* any number of active runs may exist in the registry
* each project may have at most one active worker
* global worker concurrency is capped
* round-robin is the default project selection policy
* blocked or waiting runs are skipped quickly

Recommended initial limits:

* `perProjectMaxWorkers = 1`
* `globalMaxWorkers = 2`

Three projects may therefore all be active while only two workers run at the same time.

### Reporting model

Each run reports back to its own stored `reportTarget`.

That means:

* one controller can manage multiple projects
* one heartbeat controller session can send updates to multiple Slack threads
* result reporting does not depend on the controller using `target: "last"`

Do not rely on heartbeat `target: "last"` for multi-project reporting. Use explicit outbound sends to the run's stored `reportTarget`.

## State machine

Recommended controller states:

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
* `DONE`
* `FAILED_PRECHECK`
* `FAILED_FATAL`
* `CANCELLED`

## Trigger conditions

### Trigger 1: Slack kickoff

The kickoff message should create the run-state files and move the controller into `PLAN_CHECK_PENDING`.
The kickoff chat turn should not launch a worker. It should only resolve project context, register or update the project, create the run record, and return a short acknowledgment.

### Trigger 2: heartbeat tick

Each heartbeat tick should:

* read the active run registry
* iterate runs in scheduling order
* decide the next transition for each candidate run
* do a bounded number of state-changing actions

Recommended bound:

* at most one launch action per run per tick
* at most one or two run launches globally per tick
* polling-only checks may occur for more runs

### Trigger 3: worker exit

When a background worker exits, `tools.exec.notifyOnExit` should request another heartbeat. That allows the controller to process the result quickly without waiting for the next full interval.

### Trigger 4: manual stop

A Slack stop command or an on-disk stop flag should transition the run to `CANCELLED`.

## End-to-end flow

### Phase 0: kickoff

1. User sends kickoff in Slack.
2. Controller chat turn validates the message shape.
3. Controller resolves project root from one of:
4. explicit `project=<slug>`
5. explicit `docs=...`
6. current channel registration mapping
7. explicit absolute paths
8. Controller discovers project metadata from `docs` and optional `plan`.
9. Controller registers or updates the project record.
10. Controller creates a run record with the Slack `reportTarget`.
11. Controller writes `progress.md` if missing.
12. Controller sets state to `PLAN_CHECK_PENDING`.
13. Controller returns a short kickoff acknowledgment.
14. No worker is launched in this chat turn.

### Phase 1: plan check

1. Heartbeat wakes the controller.
2. Controller sees `PLAN_CHECK_PENDING`.
3. Controller launches a fresh plan-check worker through `exec`.
4. Worker validates the raw plan structure and Ralph Loop compatibility.
5. Worker writes:
6. `logs/plan-check/<run_id>.log`
7. `results/plan-check/<run_id>.json`
8. `state/plan-state.json`
9. Controller marks `PLAN_CHECK_RUNNING`.
10. Exit current heartbeat turn.

### Phase 2: plan check result handling

1. Worker exit requests another heartbeat.
2. Controller reads the plan-check result file.
3. If plan check failed:
4. mark `PLAN_INVALID`
5. report the validation failure and log path
6. stop the workflow
7. If plan check succeeded:
8. mark `PLAN_READY`
9. move to `PRECHECK_PENDING`

### Phase 3: preflight

1. Heartbeat wakes the controller.
2. Controller sees `PRECHECK_PENDING`.
3. Controller launches a fresh preflight worker through `exec`.
4. Worker checks:
5. required docs exist
6. workspace read access
7. workspace write access
8. simple command execution
9. temporary write-read-delete cycle
10. Worker writes log and result files, then exits.
11. Controller marks `PRECHECK_RUNNING`.
12. Exit current heartbeat turn.

### Phase 4: preflight result handling

1. Worker exit requests another heartbeat.
2. Controller reads the preflight result file.
3. If preflight failed:
4. mark `FAILED_PRECHECK`
5. write failure into `progress.md`
6. send failure report and log path to Slack
7. stop the workflow
8. If preflight succeeded:
9. mark `READY`
10. select the first runnable task
11. move to `TASK_READY`

Preflight should not stop at generic shell checks.

It should also validate the real task runtime contract, including a smoke test of the same wrapper and command shape that the task worker will use.

### Phase 5: task execution

1. Heartbeat wakes the controller.
2. Controller sees `TASK_READY`.
3. Controller chooses exactly one task.
4. Controller launches a fresh worker process.
5. Worker receives:
6. `task_id`
7. task description
8. workspace path
9. validation commands
10. attempt number
11. previous failed log paths, if any
12. condensed prior failure summary
13. Worker reads `progress.md` before work.
14. Worker reads prior logs before work when `attempt > 1`.
15. Worker performs one task only.
16. Worker writes a result file, a durable log, and a progress update, then exits.
17. Controller marks `TASK_RUNNING`.

### Phase 6: task result handling

1. Worker exit requests another heartbeat.
2. Controller reads the task result file.
3. If success:
4. update `progress.md`
5. mark task complete
6. choose next task or mark `DONE`
7. optionally send a short Slack update
8. If retryable failure:
9. persist failure summary and log path
10. inspect failure class and fingerprint
11. increment attempt count only if retry is still allowed
12. move to `TASK_RETRY_WAIT` only if retry budget and progress gate both allow it
13. If blocked or fatal failure:
14. move to `WAIT_HUMAN` or `FAILED_FATAL`
15. send failure report with log path

### Phase 7: running task polling

If a heartbeat wakes while a task is still running:

1. Controller reads the current task state.
2. Controller checks whether the task result file exists.
3. If no result file exists, controller checks the worker process state.
4. If the process is still alive, controller updates `lastCheckedAt` and exits.
5. Controller does not relaunch the same task.
6. Controller moves on to other runnable projects in the same heartbeat turn if concurrency allows.

This is the normal case for long-running tasks.

The controller must poll, not rerun.

## Controller design

The controller should be cheap, short, and deterministic.

Recommended behavior:

* one state transition per heartbeat turn
* no long implementation reasoning in the controller
* no large transcript dependence
* always read state from disk first
* always write the new state before exiting
* never wait synchronously for a worker to finish
* treat `TASK_RUNNING` as a polling state, not a work state
* treat `plan-state.json` as the execution view of the plan

This is what `heartbeat` changes the most: the controller becomes a stateless scheduler that reconstructs its view from files on every wake-up.

## Worker design

The worker should be a process boundary, not an OpenClaw conversation boundary.

Recommended wrapper responsibilities:

* create per-attempt log and result paths
* run the coding runtime
* capture stdout and stderr
* return a machine-readable status artifact
* never reuse a prior process
* write or clear lock files consistently

Recommended entrypoints:

* `bin/ralph-plan-check`
* `bin/ralph-preflight`
* `bin/ralph-run-task`

## Locking model

Heartbeat mode requires explicit locking to avoid duplicate launches.

Recommended locks:

* project lock
* run lock
* task-attempt lock

Recommended behavior:

* when launching a task attempt, create `state/locks/<task-id>.attempt-<n>.lock`
* while that lock exists and there is no completed result file, the controller must not launch the same attempt again
* on successful completion, replace the lock with a result file or clear the lock
* on crash recovery, reconcile lock file, pid file, and result file before deciding whether to retry

Recommended current-task record:

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

## Configuration plan

### Global OpenClaw configuration

Recommended global settings:

```json5
{
  session: {
    maintenance: {
      mode: "enforce",
      pruneAfter: "30d",
      maxEntries: 500,
      rotateBytes: "10mb",
    },
    resetByChannel: {
      slack: { mode: "idle", idleMinutes: 2880 },
    },
  },
  channels: {
    defaults: {
      heartbeat: {
        showOk: false,
        showAlerts: true,
        useIndicator: true,
      },
    },
    slack: {
      replyToMode: "all",
      thread: {
        historyScope: "thread",
        inheritParent: false,
      },
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
    exec: {
      notifyOnExit: true,
      host: "gateway",
      security: "allowlist",
      ask: "off",
    },
  },
}
```

### Controller agent configuration

Recommended controller shape:

```json5
{
  agents: {
    defaults: {
      workspace: "~/.openclaw/projects/openclaw-ralph-loop",
      repoRoot: "~/.openclaw/projects/openclaw-ralph-loop",
      contextPruning: {
        mode: "cache-ttl",
        ttl: "15m",
        keepLastAssistants: 1,
        softTrimRatio: 0.3,
        hardClearRatio: 0.5,
      },
      heartbeat: {
        every: "3m",
        model: "openai/gpt-5.2-mini",
        lightContext: true,
        isolatedSession: true,
        target: "none",
        prompt: "Read HEARTBEAT.md first. Reconstruct state from disk. Perform at most one workflow state transition. If no action is required, reply HEARTBEAT_OK.",
        ackMaxChars: 300,
      },
      maxConcurrent: 2,
    },
    list: [
      {
        id: "ralph-controller",
        default: true,
        tools: {
          allow: ["read", "write", "edit", "apply_patch", "exec", "process"],
          deny: ["browser", "canvas"],
        },
      },
    ],
  },
}
```

### Worker invocation policy

Recommended worker policy:

* do not use a persistent OpenClaw sub-agent for task execution
* invoke a fresh process via `exec`
* run the process under a narrow allowlisted wrapper script
* use `pty: true` only if the worker runtime needs a real terminal
* always redirect output to durable logs
* require the wrapper to write structured failure classes and fingerprints
* require the wrapper to update `progress.md`
* require the wrapper to use a tested runtime contract, not ad hoc CLI flags

## Run selection policy

Heartbeat should not process runs in arbitrary order.

Recommended default selection order:

1. runs with completed worker results waiting to be absorbed
2. runs in `PLAN_CHECK_PENDING`
3. runs in `PRECHECK_PENDING`
4. runs in `TASK_READY`
5. runs in `TASK_RETRY_WAIT`
6. runs in `TASK_RUNNING` for polling only
7. runs in `WAIT_HUMAN`, `DONE`, `FAILED_*`, `CANCELLED` are skipped unless reporting is pending

Tie-breaker:

* round-robin by project
* then oldest `lastScheduledAt`

This prevents one busy project from starving all others.

## Required workspace files

Heartbeat mode makes `HEARTBEAT.md` a first-class control file.

Recommended `HEARTBEAT.md` contents:

* where the run-state files live
* the allowed state transitions
* the stop conditions
* the rule that only one transition is allowed per heartbeat
* the rule that retries must include prior failure logs
* the rule that retries must read `progress.md` before relaunch
* the rule that non-retryable failure classes must stop blind retries
* the run selection order
* the rule that `TASK_RUNNING` only polls
* the rule that reporting uses stored `reportTarget`

This file should stay short because it is loaded on every heartbeat turn.

## Failure handling

### Preflight failure

If preflight fails:

* stop immediately
* mark `FAILED_PRECHECK`
* send the exact failed check and log path
* do not start task execution

### Worker crash or timeout

If a worker crashes or times out:

* write a failure result
* preserve the log path
* mark the task as retryable or fatal
* on retry, pass the prior logs forward

If a worker is interrupted by gateway restart, `SIGTERM`, `SIGINT`, or hard kill:

* the worker should perform best-effort trap cleanup
* if worker-side cleanup does not happen, controller reconcile must synthesize the failure
* stale task locks must be cleared or archived
* `progress.md` must still receive an interrupted or synthetic failure entry
* the run must not remain indefinitely in `TASK_RUNNING`

### Gateway restart

Heartbeat mode reduces restart impact, but it does not eliminate it.

Important limitation:

* OpenClaw background `process` state is in memory and can be lost on restart

Because of that, the durable source of truth must be the on-disk lock, result, and log files, not the in-memory process handle alone.

On startup or next heartbeat after a restart, the controller should reconcile:

* run state file
* worker result file
* worker lock file
* pid file if you choose to persist one

## Behavior with multiple active projects

If the controller sees three unfinished projects:

* all three may remain active in the run registry
* at most `globalMaxWorkers` may run at once
* each project is still limited to one active worker
* a running project does not block polling or launches for other projects

Example:

* project A is `TASK_RUNNING`
* project B is `TASK_READY`
* project C is `TASK_READY`

With `globalMaxWorkers = 2`:

* heartbeat polls project A
* launches project B if a slot is free
* leaves project C queued until a future tick or exit-triggered heartbeat

This is the intended steady-state behavior.

## Stop conditions

Stop the workflow when:

* all tasks are complete
* plan check fails
* preflight fails
* a fatal task failure occurs
* the time budget is reached
* the operator sends stop
* the controller hits a circuit breaker

## Why choose this design

Choose the heartbeat design when you want:

* built-in re-entry without an external watchdog
* bounded controller context on every wake-up
* lower token cost via `isolatedSession: true` and `lightContext: true`
* a scheduler that can recover by rereading files
* automatic project registration from `docs` paths
* one controller managing many projects and many report threads

Do not choose it if you need:

* ultra-low-latency orchestration
* strict guarantees tied to a single continuously running process
* a design with zero dependence on periodic ticks

## References

This design depends on the following OpenClaw capabilities:

* heartbeat configuration
* isolated heartbeat sessions
* heartbeat lightweight context
* `HEARTBEAT_OK` response contract
* background exec and process polling
* notify-on-exit heartbeat wake-up
* session pruning
* session maintenance

## Companion docs

Use this architecture doc together with:

* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-operator-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-plan-normalization.md`
* `reference/design/heartbeat/plan-heartbeat-worker-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-progress-protocol.md`
* `reference/design/heartbeat/plan-heartbeat-verification-checklist.md`
