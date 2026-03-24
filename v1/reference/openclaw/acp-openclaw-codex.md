# ACP + OpenClaw + Codex CLI

This reference collects the implementation paths, operator flow, and official docs for making OpenClaw hand work to Codex CLI through ACP or the CLI backend.

## What you are trying to achieve

The target behavior is:

1. An OpenClaw agent receives a task.
2. The task is delegated to Codex CLI or an ACP-backed Codex runtime.
3. Codex runs the task in a separate process or session.
4. The result is returned to OpenClaw.
5. Follow-up messages can optionally reuse the same session.

There are two realistic ways to do this in OpenClaw:

* Use Codex CLI as a CLI backend.
* Use ACP to connect OpenClaw to an external coding harness session.

## Recommended mental model

Use this split:

* `CLI backend` for simple process execution and one-shot return values.
* `ACP runtime` for session-bound delegation, where follow-ups should continue the same conversation.

If your goal is specifically "let an OpenClaw agent call Codex CLI and return the result", ACP is the more protocol-shaped option.

If your goal is "just run Codex CLI and collect stdout/stderr", the CLI backend is simpler.

## OpenClaw native paths

### 1. CLI backend

OpenClaw supports CLI backends under `agents.defaults.cliBackends`.

The docs describe the flow as:

1. Select a backend based on the provider prefix, such as `codex-cli/...`.
2. Build a system prompt using OpenClaw prompt and workspace context.
3. Execute the CLI with a session id if the backend supports sessions.
4. Parse output from JSON or plain text.
5. Persist session ids so follow-ups can reuse the same CLI session.

This is the fastest integration if Codex CLI is the thing you want to run.

Key configuration ideas from the docs:

* Backend keys live under `agents.defaults.cliBackends`.
* The provider id becomes the left side of the model ref.
* Session behavior can be controlled with `sessionArg`, `sessionArgs`, `resumeArgs`, `resumeOutput`, and `sessionMode`.
* Image-capable CLIs can receive image file paths through `imageArg`.

Example shape:

```ts
{
  agents: {
    defaults: {
      cliBackends: {
        "codex-cli": {
          command: "codex",
          args: ["--json"],
          output: "json",
          input: "arg",
          modelArg: "--model",
          sessionArg: "--session",
          sessionMode: "existing",
        },
      },
    },
  },
}
```

Important limitation from the docs:

* CLI backends do not receive OpenClaw tools.
* Output is collected and returned after the process exits.
* Streaming is not provided by the backend itself.

### 2. ACP runtime

OpenClaw’s ACP docs describe ACP as the bridge for external harnesses.

The intended use is:

* Spawn a session.
* Bind it to a thread or target it by session key.
* Inspect runtime state.
* Tune model or permissions.
* Continue steering the same session.
* Close or cancel when done.

This is the better fit if you want the OpenClaw side to behave like a controller while Codex remains the executing agent.

## How ACP fits the Codex use case

ACP is useful when Codex should not just be a stateless command line call, but instead behave like a sessionful external worker.

That gives you:

* A stable session boundary.
* Follow-up messages against the same run.
* Better mapping to thread-based workflows.
* A way to keep the Codex runtime separate from OpenClaw-native sub-agents.

### Practical interpretation

For an OpenClaw workflow, ACP usually means:

* OpenClaw starts or targets an ACP session.
* The Codex runtime handles the task.
* OpenClaw records the returned text and session id.
* Later prompts can resume the same session.

That is different from simply shelling out to a CLI once.

## OpenClaw commands and flow

The OpenClaw ACP docs show a quick operator flow around:

* spawning a session
* checking status
* setting model
* changing permissions
* adjusting timeout
* steering the session
* canceling or closing it

Useful command forms mentioned in the docs include:

* `/acp spawn codex --mode persistent --thread auto`
* `/acp status`
* `/acp model <provider/model>`
* `/acp permissions <profile>`
* `/acp timeout <seconds>`
* `/acp steer ...`
* `/acp cancel`
* `/acp close`

Treat these as the operational control surface for ACP sessions in OpenClaw.

## Implementation choices

### Option A: direct CLI backend

Choose this if:

* You want the shortest path to working behavior.
* You do not need ACP-specific semantics.
* You are fine with process-level execution and collected output.

Tradeoffs:

* Less protocol structure.
* No OpenClaw tools inside the backend.
* Session handling depends on the CLI’s own conventions.

### Option B: ACP-backed Codex runtime

Choose this if:

* You want session persistence.
* You want a thread-bound agent.
* You want the external runtime to stay long-lived across turns.

Tradeoffs:

* More moving parts.
* You need ACP runtime configuration and lifecycle handling.
* You need to think about permissions, timeouts, and cancellation.

### Option C: wrapper tool or MCP adapter around Codex CLI

Choose this if:

* You need a custom policy layer.
* You want to sanitize commands.
* You want to expose Codex CLI as a structured tool to OpenClaw.

Tradeoffs:

* Most engineering effort.
* Most control.
* Useful if you want auditable task execution or queue-based operation.

## Suggested architecture for this repo

If this repo wants "OpenClaw agent can delegate to Codex and get results back", the practical progression is:

1. Start with the CLI backend.
2. Add ACP if you need follow-up continuity.
3. Add a wrapper or MCP adapter only if you need policy, logging, or queueing.

## What to document in the project

Keep these together in `reference/`:

* OpenClaw ACP Agents
* OpenClaw CLI Backends
* ACP official docs
* A repo-local example config
* Any notes on session reuse, timeout, and cancellation

## Relevant OpenClaw documentation

* [ACP Agents](https://docs.openclaw.ai/tools/acp-agents)
* [acp CLI](https://docs.openclaw.ai/cli/acp)
* [CLI Backends](https://docs.openclaw.ai/gateway/cli-backends)
* [Multi-Agent Sandbox & Tools](https://docs.openclaw.ai/tools/multi-agent-sandbox-tools)

## Relevant ACP documentation

* [ACP Overview / Clients](https://agentclientprotocol.com/overview/clients)
* [ACP TypeScript SDK](https://agentclientprotocol.com/libraries/typescript)
* [ACP Python SDK](https://agentclientprotocol.com/libraries/python)
* [ACP Community Libraries](https://agentclientprotocol.com/libraries/community)
* [ACP Governance](https://agentclientprotocol.com/community/governance)
* [ACP RFDs](https://agentclientprotocol.com/rfds/about)

## Notes on Codex CLI behavior in OpenClaw

From the OpenClaw CLI backend docs:

* Codex CLI can be addressed with the `codex-cli` provider prefix.
* Resume support is possible, but Codex CLI resume output is less structured than the initial JSONL run.
* CLI backend output is returned after completion, not streamed.

That means the `CLI backend` path is best when you want a bounded execution unit, and the `ACP` path is better when you want a reusable session boundary.

