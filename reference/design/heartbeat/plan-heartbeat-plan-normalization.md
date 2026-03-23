# Heartbeat Plan Normalization

This document defines how the heartbeat controller validates and normalizes `plan.md` before any preflight or task execution begins.

## Purpose

The controller should not drive execution directly from raw natural-language `plan.md`.

Instead, it should:

1. validate that the plan is compatible with Ralph Loop execution
2. normalize it into a stable machine-readable structure
3. use that normalized structure as the execution source of truth

Without this step, different heartbeat turns may interpret the same plan differently.

## Why normalization is required

Heartbeat mode reconstructs state from disk on every wake-up.

That means the controller needs:

* stable task ids
* stable task ordering
* stable completion state
* a clear distinction between machine-executable tasks and human-only review items

Raw prose is not stable enough for that.

## Plan check gate

Plan check is a hard gate.

Execution order should be:

1. registration
2. plan check
3. preflight
4. task execution

If plan check fails:

* do not run preflight
* do not launch task workers
* mark the run as `PLAN_INVALID`
* report the validation failure and log path

## Validation goals

The plan check worker should verify three layers.

### 1. Structural validity

Check that the plan contains:

* recognizable task items
* a stable way to derive task ids
* executable task boundaries
* no ambiguous completion model

### 2. Ralph Loop compatibility

Check that:

* tasks can be advanced one at a time
* tasks are not too large and monolithic
* human-only review items are distinguishable
* dependencies are explicit or inferable
* priorities are explicit or inferable

### 3. Execution readiness

Check that:

* the plan is not missing critical execution context
* the plan does not require hidden environment assumptions
* the controller can decide what the next runnable task is

## Normalized output

The normalized output should be written to:

```text
state/plan-state.json
```

Recommended schema:

```json
{
  "planId": "plan-20260323-a",
  "sourcePath": "/home/shing/.openclaw/projects/project-a/docs/vision/plan.md",
  "status": "ready",
  "tasks": [
    {
      "taskId": "T001",
      "title": "Add command parser slice",
      "status": "pending",
      "priority": "high",
      "type": "implementation",
      "dependsOn": [],
      "human": false
    },
    {
      "taskId": "T002",
      "title": "Manual GUI verification",
      "status": "pending",
      "priority": "medium",
      "type": "review",
      "dependsOn": ["T001"],
      "human": true
    }
  ],
  "notes": [
    "Human review tasks were preserved but excluded from automatic execution."
  ]
}
```

## Task categories

Recommended categories:

* `implementation`
* `test`
* `cleanup`
* `refactor`
* `review`
* `research`

Recommended machine execution rule:

* only tasks with `human: false` are auto-runnable

## Failure conditions

Plan check should fail if:

* no tasks can be extracted
* task ids cannot be made stable
* most tasks are ambiguous prose with no executable boundary
* the plan mixes human-only and machine-only tasks without distinction
* dependencies or sequencing are too unclear to determine the next action

## Repairable findings

Some problems should not hard-fail immediately if the controller can normalize safely.

Examples:

* missing explicit ids, but ids can be generated deterministically
* missing explicit priority, but safe default ordering can be applied
* human review items present, but can be marked as `human: true`

These should be normalized and logged as warnings.

## Result files

Recommended result path:

```text
results/plan-check/<run-id>.json
```

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

## Controller usage rule

After normalization succeeds:

* `plan.md` remains the source artifact for humans
* `state/plan-state.json` becomes the execution artifact for the controller

The controller should not re-parse raw `plan.md` on every heartbeat for task selection.

## Companion docs

Use this together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`

