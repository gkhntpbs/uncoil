# Claude Code structured sessions

> **Status: opt-in.** Claude sessions run Claude Code's own TUI in a PTY by
> default. The structured path runs `claude -p` in stream-json mode instead,
> which puts Claude's turns, tool calls and approvals on the AgentSession model
> beside Codex's app server, and gives up the TUI's own prompt, slash commands
> and rendering until Uncoil has a surface of its own for them. Turn it on with
> the `-claude-structured` argument (`LaunchConfig.claudeStructuredEnabled`).

## Protocol

Verified against Claude Code `2.1.283`. Every shape below was recorded from a
real run; the trimmed recordings are `Tests/ClaudeStreamFixtures.swift`.

```text
claude -p --input-format stream-json --output-format stream-json --verbose
          --include-partial-messages --permission-prompt-tool stdio
          (--session-id <uuid> | --resume <id>) [--mcp-config <file> [--strict-mcp-config]]
          [--model …] [--effort …] [--permission-mode … | mode flags]
```

- **Transport:** newline-delimited JSON on the child's stdin/stdout. No PTY — a
  terminal would echo and wrap the JSON. The stdin write end has
  `F_SETNOSIGPIPE`, so a write to a Claude that has exited fails instead of
  ending Uncoil.
- **Handshake:** a `control_request {subtype: initialize}` is answered locally
  (no API call) with a `control_response`. That answer is what marks the session
  ready; anything else before it — the process failing to start, exiting, or
  refusing — falls back to the TUI launch in the same view.
- **Turns:** a `{type: "user", message: {role, content: [...]}}` line starts a
  turn; the process stays up between turns. Images go as `image` content blocks
  (base64, ≤ 5 MB); files are named in the text. Claude does not echo a prompt,
  so the session publishes the user's message itself.
- **Output:** `system/init` names the session; `stream_event`s carry the reply as
  `content_block_*` deltas; each finished block arrives as an `assistant`
  message; tool results arrive as `user` messages holding `tool_result` blocks;
  every turn ends with one `result`.
- **Approvals:** with `--permission-prompt-tool stdio`, a prompt arrives as
  `control_request {subtype: can_use_tool, tool_name, input, permission_suggestions, …}`
  and is answered with `control_response {behavior: allow, updatedInput}` or
  `{behavior: deny, message}`. "For this session" returns Claude's own
  `addRules`/`addDirectories` suggestions with `destination: session`, never
  the settings file they propose — an approval in Uncoil does not rewrite the
  project's `.claude/settings.local.json`. `--permission-prompts host` alone is
  *not* enough: the CLI then denies the tool itself (`system/permission_denied`).
- **Interrupt:** `control_request {subtype: interrupt}`; the turn's `result` then
  has `terminal_reason: aborted_streaming` and the stream carries a
  `[Request interrupted by user]` message.
- **Unknown control requests** are answered with an `error` response, so the CLI
  never waits on Uncoil.

## Mapping to AgentEvent

`ClaudeEventNormalizer` is the only code that reads Claude's lines.

| Claude | AgentEvent |
|---|---|
| `system/init` (new `session_id`) | `sessionBound` |
| `system/status: requesting` | `runState(.active)` |
| `system/permission_denied` | `notice(.warning)` |
| `content_block_start` text / thinking | `itemStarted` agent message / reasoning |
| `content_block_delta` `text_delta` | `itemDelta(.text)` on the same item |
| `assistant` text / thinking block | `itemCompleted` (same id as the stream) |
| `assistant` `tool_use` | `itemStarted`: `Bash` → command, `Edit`/`Write`/`MultiEdit`/`NotebookEdit` → file change, `mcp__server__tool` → MCP tool call, `Task`/`Agent` → delegation, else tool call |
| `user` `tool_result` | `itemCompleted` of that tool, with the output and failed/completed |
| `result` | `turnCompleted` (completed / interrupted / failed) + `runState(.idle)` |
| `can_use_tool` | `approvalRequested` (session) |

A subagent's own messages (`parent_tool_use_id` set) stay out of the main
timeline; the delegation item stands for them.

## Sessions and resume

A new session is launched with `--session-id <uuid>` and the record claims that
id at once, so a session the app quits before its first reply still resumes. A
session with an id is asked of Claude's own transcript store first
(`ClaudeSessionStore`), exactly as the TUI launch does: a transcript that is gone
starts fresh with a notice, rather than handing `--resume` an id Claude would
refuse. On resume the transcript under `~/.claude/projects/<cwd-slug>/` (or the
account's config root) is read through the same normalizer, with the user's own
prompts added, and published as `historyLoaded`.

No process outlives the app: the conversation is Claude's transcript, and the
next launch resumes it.

## When the TUI is used instead

- The flag is off (the default).
- The provider's extra arguments or the session's preset arguments are set —
  they were written for the TUI and could change what `claude -p` is.
- The Claude binary is not found, or the structured session fails before its
  handshake completes.

## Tests

- `ClaudeEventNormalizerTests` — the recorded turns, deltas tied to their items,
  denials, interrupts, tool mapping, subagents, transcript history.
- `ClaudeStreamArgumentsTests` — the command line, resume, launch selection, and
  that "for this session" never targets a settings file.
- `ClaudeStreamSessionTests` — the session driven line by line through a fake
  transport: handshake, submit, approvals, interrupt, unknown requests, early and
  late exits, images, and the control plane driving it exactly like Codex.
- `ClaudeStreamLiveTests` — the installed CLI through the real pipes, handshake
  only (no tokens). Skipped unless `TEST_RUNNER_UNCOIL_LIVE_CLAUDE=1` is set for
  `xcodebuild test`.

Manual acceptance:

```text
-ui-testing -reset-state -fixture demo -route project
-window-width 1100 -window-height 720 -claude-structured -disable-animations
```
