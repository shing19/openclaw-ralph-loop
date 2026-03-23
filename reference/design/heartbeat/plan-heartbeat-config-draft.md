# Heartbeat Config Draft

This document proposes a concrete first-pass OpenClaw configuration for the heartbeat plan.

It is intentionally conservative:

* one dedicated heartbeat controller agent
* no persistent task sub-agents
* workers launched as fresh `exec` processes
* low heartbeat token cost
* bounded concurrency

## Design stance

The first implementation should use:

* one OpenClaw agent: `ralph-controller`
* one control workspace: `~/.openclaw/projects/_ralph-control`
* one heartbeat loop
* one or more external worker wrapper scripts launched with `exec`

This avoids having to configure a second persistent OpenClaw worker agent before the protocol is proven.

## Recommended `openclaw.json` draft

This is a configuration sketch for `~/.openclaw/openclaw.json`.

Only fields that are documented in OpenClaw's official config reference are included here.

```json5
{
  agents: {
    defaults: {
      workspace: "~/.openclaw/projects/_ralph-control",
      repoRoot: "~/.openclaw/projects/_ralph-control",
      model: {
        primary: "openai/gpt-5-mini",
      },
      models: {
        "openai/gpt-5-mini": { alias: "gpt-mini" },
        "openai/gpt-5.4": { alias: "gpt" },
      },
      timeoutSeconds: 120,
      maxConcurrent: 2,
      contextPruning: {
        mode: "cache-ttl",
        ttl: "15m",
        keepLastAssistants: 1,
        softTrimRatio: 0.3,
        hardClearRatio: 0.5,
        minPrunableToolChars: 50000,
        softTrim: { maxChars: 4000, headChars: 1500, tailChars: 1500 },
        hardClear: {
          enabled: true,
          placeholder: "[Old tool result content cleared]",
        },
      },
      heartbeat: {
        every: "3m",
        model: "openai/gpt-5-mini",
        includeReasoning: false,
        lightContext: true,
        isolatedSession: true,
        session: "main",
        target: "none",
        prompt: "Read HEARTBEAT.md if it exists. Reconstruct run state from disk. Perform only bounded scheduler work. If there is no actionable work, reply HEARTBEAT_OK.",
        ackMaxChars: 300,
        suppressToolErrorWarnings: false,
      },
      sandbox: {
        mode: "off",
      },
    },
    list: [
      {
        id: "ralph-controller",
        default: true,
        name: "Ralph Controller",
        workspace: "~/.openclaw/projects/_ralph-control",
        agentDir: "~/.openclaw/agents/ralph-controller/agent",
        model: "openai/gpt-5-mini",
        tools: {
          profile: "coding",
          allow: ["exec", "process"],
          deny: ["browser", "canvas"],
        },
        heartbeat: {
          every: "3m",
          model: "openai/gpt-5-mini",
          includeReasoning: false,
          lightContext: true,
          isolatedSession: true,
          session: "main",
          target: "none",
          prompt: "Read HEARTBEAT.md if it exists. Reconstruct run state from disk. Perform only bounded scheduler work. If there is no actionable work, reply HEARTBEAT_OK.",
          ackMaxChars: 300,
          suppressToolErrorWarnings: false,
        },
      },
    ],
  },
  session: {
    resetTriggers: ["/new", "/reset"],
    maintenance: {
      mode: "enforce",
      pruneAfter: "30d",
      maxEntries: 500,
      rotateBytes: "10mb",
      resetArchiveRetention: "30d",
      maxDiskBytes: "500mb",
      highWaterBytes: "400mb",
    },
    threadBindings: {
      enabled: true,
      idleHours: 24,
      maxAgeHours: 0,
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
      historySize: 30,
      warningThreshold: 10,
      criticalThreshold: 20,
      globalCircuitBreakerThreshold: 30,
      detectors: {
        genericRepeat: true,
        knownPollNoProgress: true,
        pingPong: true,
      },
    },
    exec: {
      backgroundMs: 10000,
      timeoutSec: 1800,
      cleanupMs: 1800000,
      notifyOnExit: true,
      notifyOnExitEmptySuccess: false,
    },
  },
}
```

## Why this draft looks like this

### `workspace`

The controller should not run inside one project's repo.

Using `~/.openclaw/projects/_ralph-control` as the controller workspace keeps:

* registry files
* `HEARTBEAT.md`
* controller-only logs

separate from project repos.

### `model`

The controller uses `openai/gpt-5-mini` because:

* it is a scheduler, not a coding worker
* heartbeat runs can happen frequently
* lower token cost matters more than deep coding ability here

### `timeoutSeconds`

`120` seconds is deliberate.

A heartbeat turn should be short. If a controller turn takes longer than this, the design is already drifting in the wrong direction.

### `maxConcurrent`

`2` is the recommended starting point.

This is not worker concurrency by itself. It is the maximum number of parallel agent runs across sessions. Keeping it low reduces queue contention and makes the first rollout easier to debug.

### `contextPruning`

The controller reconstructs state from disk, so it benefits from aggressive pruning.

`keepLastAssistants: 1` is enough because persistent transcript memory should not be the source of truth.

### `heartbeat`

Key choices:

* `every: "3m"` gives a reasonable default sweep interval
* `lightContext: true` keeps only `HEARTBEAT.md` from bootstrap files
* `isolatedSession: true` avoids carrying old conversation history forward
* `target: "none"` prevents heartbeat from implicitly reporting to the wrong thread

### `session.maintenance`

Heartbeat mode creates lots of scheduler turns over time.

Maintenance should therefore be `enforce`, not `warn`, so the session store remains bounded.

### `tools.exec`

`notifyOnExit: true` is critical because background worker exit should request another heartbeat.

That reduces mean time to absorb results.

## Expected runtime behavior

With this config:

* Slack kickoff happens in a normal agent turn
* heartbeat wakes the controller every 3 minutes
* worker exits can request an extra heartbeat
* no-op ticks return `HEARTBEAT_OK`
* the controller sends explicit reports using stored `reportTarget` metadata

## Deliberate omissions

This draft does not yet define:

* a second persistent worker agent
* ACP runtime defaults
* `cliBackends` for worker execution

Those can be added later if the wrapper-script approach proves too limited.

## Wrapper-script assumption

This config assumes task workers are launched as external commands through `exec`.

For example:

* `~/.openclaw/projects/_ralph-control/bin/ralph-preflight`
* `~/.openclaw/projects/_ralph-control/bin/ralph-run-task`

Those wrappers are responsible for:

* launching the actual coding runtime
* writing logs
* writing result JSON
* exiting cleanly

## Recommended rollout order

1. Create the controller workspace.
2. Add `AGENTS.md` and `HEARTBEAT.md` for `ralph-controller`.
3. Apply the OpenClaw config.
4. Validate heartbeat with no active runs.
5. Add preflight wrapper.
6. Add task wrapper.
7. Test one project, then multiple projects.

## Official references

This draft relies on these documented OpenClaw config surfaces:

* `agents.defaults.workspace`
* `agents.defaults.repoRoot`
* `agents.defaults.timeoutSeconds`
* `agents.defaults.maxConcurrent`
* `agents.defaults.contextPruning`
* `agents.defaults.heartbeat`
* `agents.list`
* `session.maintenance`
* `session.threadBindings`
* `channels.defaults.heartbeat`
* `channels.slack.replyToMode`
* `tools.exec`
* `tools.loopDetection`

