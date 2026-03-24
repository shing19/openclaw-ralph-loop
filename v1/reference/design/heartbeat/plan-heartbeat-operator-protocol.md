# Heartbeat Operator Protocol

This document defines how humans interact with the heartbeat controller from Slack and how the controller should respond.

## Goals

The operator protocol should:

* keep kickoff messages short
* support automatic project registration
* support multiple channels and threads
* avoid duplicate active runs for the same project
* make status and control actions explicit

## Supported commands

Recommended command surface:

* `start`
* `status`
* `stop`
* `pause`
* `resume`
* `retry`
* `attach`
* `detach`

## `start`

Recommended forms:

```text
@ralph-controller start docs=/abs/path/to/project/docs
```

```text
@ralph-controller start docs=/abs/path/to/project/docs plan=/abs/path/to/project/docs/plan.md
```

```text
Vision: docs/vision/vision.md
Plan: docs/vision/plan.md
```

```text
@ralph-controller start project=<slug>
```

Behavior:

1. validate the request
2. resolve project root using this priority:
3. explicit `project=<slug>`
4. explicit `docs=...`
5. channel registration mapping
6. discover or load the project
7. create or reuse the project registry entry
8. create a new run if there is no active run for that project
9. if there is already an active run for the project, do not start another run automatically
10. optionally attach the current thread as a watcher
11. move the run to `PLAN_CHECK_PENDING`

The kickoff turn should not launch a coding worker.

The kickoff turn should only:

* resolve metadata
* register the project
* create the run
* send an acknowledgment

If the operator sends only relative `Vision:` and `Plan:` paths, the controller should resolve them against the current channel registration mapping before failing.

If there is no channel registration mapping and no explicit `project=` or `docs=` input, registration should fail. The controller should not infer a root from arbitrary process working-directory state.

## Kickoff acknowledgment

If kickoff succeeds, the first reply should include:

* resolved project slug
* resolved project root
* resolved vision path if one was provided
* resolved plan path
* `runId`
* current run state
* next action

Recommended kickoff success message:

```text
Run accepted.

Resolved project:
- project: <slug>
- root: <root>

Resolved inputs:
- vision: <vision-path>
- plan: <plan-path>

Run:
- runId: <run-id>
- state: PLAN_CHECK_PENDING

Next actions:
- run plan check
- if valid, run preflight
- if preflight passes, begin task execution
```

If kickoff fails, the failure should make it explicit that no worker was launched.

Recommended kickoff failure message:

```text
Registration failed.

Reason:
- <reason>

No worker was launched.
No task execution has started.
```

## `status`

Recommended forms:

```text
@ralph-controller status project=<slug>
```

```text
@ralph-controller status run=<run-id>
```

Response should include:

* current run state
* current task id
* current attempt
* last completed task
* next expected action
* log path if the run is blocked or failed

## `stop`

Recommended form:

```text
@ralph-controller stop project=<slug>
```

Behavior:

* mark the run as `CANCELLED`
* do not launch new workers
* optionally signal active workers for termination if that policy is enabled

## `pause`

Recommended form:

```text
@ralph-controller pause project=<slug>
```

Behavior:

* mark the run as `PAUSED`
* do not launch new workers
* allow current worker to finish, unless force-stop is requested

## `resume`

Recommended form:

```text
@ralph-controller resume project=<slug>
```

Behavior:

* move the run back to `READY`, `TASK_READY`, or `TASK_RETRY_WAIT`
* do not reset progress

## `retry`

Recommended form:

```text
@ralph-controller retry project=<slug> task=<task-id>
```

Behavior:

* only valid for blocked or retryable failed tasks
* do not reuse the old worker
* move the task to `TASK_RETRY_WAIT` or `TASK_READY`

## `attach`

Recommended form:

```text
@ralph-controller attach project=<slug>
```

Behavior:

* add the current channel/thread as a watcher
* future reports may be sent there

## `detach`

Recommended form:

```text
@ralph-controller detach project=<slug>
```

Behavior:

* remove the current channel/thread from the watcher list

## Auto-registration rules

If `docs=...` is provided:

* infer the project root
* discover the plan file
* discover supporting docs
* create the project registry entry automatically

If only relative paths are provided:

* first try to resolve them against the current channel's registered project root
* only fail if no channel mapping exists and no explicit root can be inferred

If registration fails:

* do not create a run
* return the exact failure and the missing or ambiguous path

## Multi-channel rules

One project should have at most one active run at a time.

If the same project is started from another channel while already active:

* do not create a duplicate run by default
* return the active `runId`
* offer or automatically perform `attach`

This prevents two threads from racing the same plan.

## Watcher model

Each run should have:

* one primary `reportTarget`
* zero or more watcher targets

Primary target receives all important lifecycle messages.

Watchers may receive:

* finish messages
* failure messages
* status replies
* optional milestone updates

## Report policy

Recommended report policy:

* kickoff success: send
* registration failure: send
* preflight success: optional
* preflight failure: send
* task success: optional milestone or compact success message
* retry start: optional
* blocked state: send
* fatal failure: send
* run completion: send
* explicit `status`: send

Avoid per-tick heartbeat chatter.

## Recommended kickoff validation

On kickoff, validate:

* docs path exists
* docs path is a directory
* root path is writable
* plan path is unique or explicit
* progress file can be created if missing
* if only relative paths are given, channel registration can resolve them

## Recommended companion docs

This protocol should be used together with:

* `reference/design/heartbeat/plan-heartbeat-architecture.md`
* `reference/design/heartbeat/plan-heartbeat-controller-spec.md`
* `reference/design/heartbeat/plan-heartbeat-state-protocol.md`
