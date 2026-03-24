# Ralph Loop Engineering Practices

This note turns the Ralph Loop method into executable engineering practice for iterative code work in this repo.

## What Ralph Loop is for

Use Ralph Loop when you want an agent to work autonomously through a multi-step implementation with frequent verification.

It is best for:

* Multi-step feature work.
* Build-test-fix cycles.
* Lint and type cleanup.
* Test coverage growth.
* Incremental refactors.

It is not ideal for:

* Open-ended brainstorming.
* Large design work without a scoped plan.
* Work that needs constant human approval between steps.

## Core operating rules

The loop is based on a few hard rules:

1. Run environment preflight before the first task.
2. One thing per iteration.
3. Search the codebase before changing anything.
4. Run feedback loops before committing.
5. Track progress between iterations.
6. Prioritize risky or architecture-heavy tasks first.
7. Follow the codebase’s existing patterns.
8. When something fails, identify the missing capability and add it.
9. Preserve failure logs and pass them into retries.

## The loop shape

Use this cycle:

1. Run preflight once before the first task.
2. Read the plan or scope.
3. Read `progress.md` if the task is running in loop mode.
4. Pick the highest-priority task.
5. Search the codebase for existing implementations.
6. Implement one focused change.
7. Run validation: build, tests, lint, typecheck.
8. Preserve logs and summarize failures if validation fails.
9. Fix failures before proceeding or schedule a retry.
10. Commit the change if the loop requires commits.
11. Update progress tracking.
12. Stop or move to the next iteration.

## Preflight gate

Before the loop starts, run a dedicated environment test.

The preflight should verify:

* required docs and plan files can be read
* the workspace can be read
* the workspace can be written to
* a worker can execute a basic command
* a worker can write and delete a temporary file

If preflight fails:

* stop the loop immediately
* write the failure details to a log
* report the failed check and the log path
* do not spend task retries on preflight

## Practical execution cases

### Case 1: Feature slice loop

Use this when building a feature that touches several files or modules.

Example:

* Add a new ACP command to OpenClaw.
* Wire it through the command parser.
* Add a backend handler.
* Add tests.
* Add docs.

How to run it:

1. Start with the highest-risk integration point.
2. Search for existing command registration and backend patterns.
3. Implement only the command parser slice in the first iteration.
4. Run tests and typecheck.
5. Fix the slice until green.
6. Commit.
7. Move to the handler slice.
8. Repeat until the feature is complete.

Why this works:

* You find interface mismatches early.
* You avoid building multiple incomplete layers at once.
* Each iteration leaves the repo in a valid state.

### Case 2: Build-test-fix loop

Use this when a branch already exists and you want the agent to burn down failures.

Example:

* A new refactor broke the build.
* The agent should fix compile errors, then tests, then lint.

How to run it:

1. Run the build.
2. Fix the first blocking compile or type error.
3. Re-run build.
4. Run tests.
5. Fix the first failing test.
6. Re-run tests.
7. Run lint.
8. Fix the first lint violation.
9. Repeat until all mandatory checks pass.

Why this works:

* The feedback loop is tight.
* The agent does not drift into unrelated edits.
* Failures stay localized.

### Case 3: Test coverage loop

Use this when you want the agent to improve coverage on a specific area.

Example:

* Increase coverage for `acp` session resume behavior.
* Add tests for session persistence and cancellation.

How to run it:

1. Read the coverage report or failing test map.
2. Identify the highest-risk uncovered path.
3. Search for existing test helpers.
4. Add one test only.
5. Run the targeted test file.
6. Expand to the broader test suite.
7. Repeat until the coverage target or confidence target is reached.

Why this works:

* Tests stay meaningful instead of being sprayed everywhere.
* Coverage growth follows actual risk.

### Case 4: Cleanup loop

Use this for code smell cleanup or consistency work.

Example:

* Normalize config names.
* Remove duplicated helper logic.
* Fix inconsistent error handling.

How to run it:

1. Scan for a specific smell class.
2. Pick one instance only.
3. Search for existing conventions.
4. Fix it without broad refactors.
5. Run the relevant tests or build.
6. Repeat.

Why this works:

* Cleanup does not explode into a rewrite.
* The codebase gradually becomes more regular.

## Hitl versus AFK

### HITL mode

Use when:

* The task is new or risky.
* You want to observe the first pass.
* The architecture is not yet stable.

Recommended pattern:

* Let the loop run one iteration.
* Inspect output.
* Adjust scope or constraints.
* Continue manually if needed.

### AFK mode

Use when:

* The codebase patterns are stable.
* The task is well-scoped.
* Validation is automated.

Recommended pattern:

* Cap iterations.
* Require every iteration to leave the repo green.
* Stop once the loop hits the cap or the backlog is done.

## What each iteration should produce

Every iteration should leave behind:

* One completed task.
* Passing validation for that task.
* A commit if the workflow uses commits.
* Updated progress notes.
* No unfinished placeholder code.
* A durable log if the task failed.

## Progress tracking template

Use a small session-local file such as `progress.md`.

Keep it concise:

```md
## Done
- [x] Added ACP reference doc

## In progress
- [ ] Wire Codex CLI config example into OpenClaw docs

## Notes
- CLI backend path is simpler than ACP for one-shot execution.
- ACP path is better for thread-bound follow-up.
```

## Good loop prompt

When instructing an agent to run a Ralph Loop, give it a prompt like this:

```text
Context:
- plan.md
- progress.md
- relevant reference docs

Rules:
1. Search before editing.
2. Do one task only per iteration.
3. Run build, test, lint, and typecheck as appropriate.
4. Fix failures before moving on.
5. Commit only when validation passes.
6. Update progress after each iteration.
7. Stop if the task list is done or the iteration cap is reached.
```

## Example task plan

For this repo, a good Ralph Loop plan might look like:

1. Add a reference note for ACP and OpenClaw.
2. Add a reference note for Ralph Loop itself.
3. Add repo-local config examples for the chosen integration path.
4. Add tests for the new config or command paths.
5. Clean up docs and finish with a validation pass.

## Failure handling

If a loop iteration fails:

1. Identify whether the failure is build, test, lint, or missing capability.
2. Preserve the failure log and record its path.
3. Fix the blocking issue first.
4. If the failure exposes a missing abstraction, add it instead of patching symptoms.
5. Re-run the same validation before continuing.

## Retry handling

Meaningful retries must inherit failure context.

When retrying:

1. Start a fresh worker.
2. Pass the attempt number.
3. Pass the previous failure log path or paths.
4. Pass a compact summary of the last failure.
5. Require the worker to read those logs before it edits anything.

Do not reuse the failed worker process.

## Anti-patterns

Avoid these:

* Doing multiple feature slices in one iteration.
* Skipping validation to move faster.
* Using loop mode without progress tracking.
* Trying to solve every failure with a local patch.
* Running infinite autonomous loops.

## Recommended use in this repo

For OpenClaw work, Ralph Loop is a good fit when:

* You are wiring an execution path such as ACP or Codex CLI.
* You want the agent to make incremental changes and validate each one.
* You want documentation, config, and tests to evolve together.

It is a poor fit when:

* You need high-level product decisions first.
* You have no clear plan file.
* The work requires repeated human judgment per step.
