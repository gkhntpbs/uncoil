# Uncoil Auto — the run harness

Uncoil Auto is a conversation of Uncoil's own (`provider == .uncoil`) from which
a project's agents are directed. A message that names an agent with `@` goes to
that agent's own terminal, as it always has. An **Auto run** — `/auto <task>`, or
any message naming no agent when Settings › Uncoil Auto says so — runs the task
through a harness around the conversation's agent:

```text
                    MAIN AGENT  (the conversation's target)
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
      EXPLORER        WORKER      RESEARCHER     ← sessions of their own
          └─────────────┼─────────────┘
                 AUTO ORCHESTRATOR
                   /             \
                LAYA            ADVISOR
          small decisions       deep review
                   \             /
                     VERIFY  (the project's own test suite)
                        │
                       DONE
```

Native agent sessions are unchanged by any of this. Specialists are ordinary
sessions of the project, created by `ProjectStore` and started by
`TerminalRegistry` like any other, with Main as their parent; every agent keeps
its own approvals, and the user stays the authority on what they ask.

## Where the code is

| File | What it holds |
|---|---|
| `App/Orchestrator/Auto/AutoOrchestrator.swift` | The run: phases, specialists, retries, escalation, verification, cleanup |
| `App/Orchestrator/Auto/AutoHarnessEnvironment+Live.swift` | The app behind the run: session creation, `AutoTurnWatcher`, worktrees, read-only launch per provider |
| `App/Orchestrator/Auto/AutoHandoff.swift` | The `uncoil-handoff` result contract and every role's prompt |
| `App/Orchestrator/Auto/AutoDecisions.swift` | Laya's decisions — schema, options, fallback — and the resolver that applies policy above them |
| `App/Orchestrator/Auto/AutoVerification.swift` | Which suite is run, how, and what changed |
| `App/Orchestrator/Auto/AutoRun.swift` | The persisted run and its diagnostics |
| `App/Orchestrator/Auto/AutoHarnessSettings.swift` | Settings: each role's agent, model and effort, checkpoints, policy, decisions |
| `App/Orchestrator/Auto/LayaSidecar.swift` | The local Laya runtime |
| `App/UI/Chat/AutoRunViews.swift` | The run strip, the panel section, the diagnostics view |

The orchestrator talks to the app only through `AutoHarnessEnvironment`, a set
of closures, so `Tests/AutoHarnessTests.swift` drives every branch without a
provider, a PTY or a window.

## A run

1. **Main** is resolved: the conversation's target, started if it has no session.
2. **Exploration.** The Explorer (and the Researcher, when the research gate
   says so) run in parallel, each one turn, each returning a handoff.
3. **Planning.** Main gets the task and the specialists' digests and answers with
   a plan and a self-contained `worker_task`. An empty one ends the run there.
4. **Advisor, before the plan** (checkpoint). A `revise` or `stop` verdict goes
   back to Main once.
5. **Implementation.** The Worker — in a fresh worktree on an `uncoil/` branch
   when isolation is on — gets the brief. With no Worker, Main implements.
6. **Verification.** After every Worker turn: the project's default suite from
   `.uncoil/tests.json`, or the one suite detected. Never a command an agent
   proposed. The verdict is `passed`, `failed` or `unverified`; the Worker's own
   status is recorded beside it, not instead of it. A worktree with no changes
   fails, whatever the Worker says.
7. **On failure.** Policy first — the retry budget, the repeated-failure
   threshold (same failure signature in a row), the Advisor checkpoint — then,
   within it, the failure-triage decision: `retry`, `return_to_main` or
   `escalate_to_advisor`.
8. **Completion.** The Advisor reviews when its checkpoint is on, or when the
   completion decision recommends it. Main writes the final answer. The
   worktree is never merged: that stays the user's decision.

## Laya

Laya answers `choice` questions over `laya-apple serve`'s
`POST /v1/systemone`, on 127.0.0.1. It takes part in three decisions, each
`off`, `shadow` (default: recorded, the deterministic policy acts) or `active`:

| Decision | Options | Deterministic answer |
|---|---|---|
| Research gate | `no_research`, `research` | keyword gate |
| Failure triage | `retry`, `return_to_main`, `escalate_to_advisor` | retry within budget, else back to Main |
| Completion review | `advisor_not_needed`, `advisor_recommended` | not needed |

A timeout, an error, an answer outside the options or a confidence below the
configured minimum all fall back to the deterministic answer, and the run goes
on. Budgets, thresholds and checkpoints override Laya and say so in the record.
Nothing Laya says is a permission or a verification.

## Diagnostics

Each run keeps — bounded, inside the conversation's file — its participants,
its history, every decision (state, question, options, Laya's distribution,
latency, the deterministic answer, any override, the action) and every
verification (suites with their output tail, changed files, the Worker's
commands, the failure signature). The panel's list icon opens them; Copy as
JSON exports one run.
