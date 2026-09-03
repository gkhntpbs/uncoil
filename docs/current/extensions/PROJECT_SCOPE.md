# Per-project MCP and skill scope

A project says which MCP servers and skills its sessions are handed. The point
is context, not security: an agent given twenty servers and thirty skills pays
for all of them in its context window before it reads a line of code, and most
of them have nothing to do with the project in front of it.

Nothing about the user's own agent configuration is written. The selection is
applied per session, at launch, through each CLI's own per-session mechanism.

## Where the decision lives

`ProjectBinding` (`App/Extensions/ExtensionModels.swift`), stored in the
extension registry alongside packages and agent bindings. Only **exclusions**
are recorded — an allowed extension is the absence of a record.

That asymmetry is the design, not an optimisation. It makes the default
"everything", so a project nobody has configured behaves exactly as it did
before this feature existed, and an extension installed next week reaches every
project that has not explicitly refused it. A stored allow-list would freeze
today's inventory into every project and quietly withhold anything added later.

### Two readings of the same records

`ProjectBinding` is read two different ways, deliberately:

| Reader | Reading | Unnamed project gets |
|---|---|---|
| `SkillAssignment.isActive` (Extensions → Assignments) | **allow**-list — naming a project is how "this extension belongs to that project" is said | nothing |
| `ProjectExtensionScope.allows` (session launch) | **deny**-list — a project allows what it has not refused | everything |

These are not a contradiction to reconcile. The assignment matrix hands an
extension *out* to chosen projects; session launch asks what a session may
load. Sharing one implementation would break one of them: with the allow-list
rule, switching one server off in one project would switch it off in every
project that had never been configured — which is every other project.

## What can actually be enforced

Checked against the installed CLIs' own `--help` and config files. A scoping
claim that quietly does nothing is worse than an admitted gap, because the user
would trim a list, watch the agent load everything anyway, and have no way to
tell which of the two was lying.

| Provider | MCP | Skills | Mechanism |
|---|---|---|---|
| **Claude Code** | strict | **not scoped** | `--mcp-config <file>` + `--strict-mcp-config` |
| **Codex** | strict | strict | `-c mcp_servers.<name>.enabled=false` · `-c 'skills.config=[…]'` |
| **OpenCode** | strict | n/a — reads no skills | `OPENCODE_CONFIG_CONTENT` with `enabled: false` |
| Gemini, Grok, Cursor, Hermes | none | none | no per-session mechanism |

The matrix is `AgentProvider.extensionScoping` (`App/Core/Models.swift`), and
it is what the picker reads to tell the user what will happen. One test
(`testTheScopingMatrixMatchesWhatTheLauncherImplements`) pins the screen and the
launcher to the same answer.

### Why Claude Code skills are not scoped

Claude Code has no per-session skill selection. The one flag that would come
close, `--setting-sources project,local`, drops the user scope — and Uncoil's
own status hooks live in `~/.claude/settings.json`
(`App/Hooks/HookInstaller.swift`), so the session would stop reporting itself
to the app in exchange for a shorter skill list. Delivering skills per session
through `--plugin-dir` would work, but only by removing the global symlinks
Uncoil installs into `~/.claude/skills`, which would take those skills away from
every `claude` the user starts outside Uncoil. Both were considered and
rejected. The picker says so on screen.

## Additive versus subtractive, and why it matters for secrets

Only Claude Code is given an allow-list; Codex and OpenCode are told what to
switch **off**.

That is forced by a real constraint. Reading an agent config deliberately
discards secret environment **values** and keeps only the variable names
(`AgentAdapterSupport.partitionEnvironment`) — a token belongs in the Keychain,
never in a diff. So a server rebuilt from its parsed `MCPServerDefinition` would
start without its credentials, and under `--strict-mcp-config` that broken copy
would be the only one the session got.

Claude's allow-list therefore copies the entries **verbatim** out of the raw
config JSON (`ProjectExtensionScope.filteredMCPServers`), preserving secrets and
any keys Uncoil does not model. Codex and OpenCode never restate an allowed
server at all, so the question does not arise for them.

### Codex's overrides merge, they do not replace

Measured against the installed CLI rather than assumed, because the whole design
of the Codex path turns on it:

```
$ codex doctor --json | …mcp.config
  {"configured servers": "13", "disabled servers": "7", …}
$ codex doctor --json -c 'mcp_servers.maestro.enabled=false' | …mcp.config
  {"configured servers": "13", "disabled servers": "8", …}     # +1 disabled, 13 still defined

$ codex debug prompt-input hi                     → 49 skills listed
$ codex debug prompt-input hi \
    -c 'skills.config=[{path="…/watch/SKILL.md",enabled=false}]'
                                                  → 48 skills, only `watch` gone
```

Two things follow. An override switches one entry off without disturbing its
neighbours' definitions, which is why nothing has to be restated. And an
`enabled = true` entry would be Uncoil asserting a default at length — ~3 KB of
argv for fifty skills — while overruling anything the user had disabled globally
in their own `config.toml`. So only the refused entries are ever named.

`uncoil` — the control-plane server — is excluded from every decision. Dropping
it would cut the session off from the app that started it.

## Layers

```
ProjectExtensionPicker              one view, two homes:
  ├── NewProjectSheet                 asked once, when a folder becomes a project
  └── ProjectCustomizeSheet           the "MCP & Skills" tab, editable any time
            │
            ▼
  ExtensionRegistry.setProjectBindings(_:forProject:)   one write, one audit event
            │
            ▼  registry.json
  ProjectScopeService.resolve(for:projectID:)   reads the records + the agent's
            │                                   live config at launch time
            ▼
  ProjectExtensionScope             pure, no I/O, fully unit-tested
            │
            ▼
  TerminalHost.writeMCPConfig / launchCommand / openCodeConfigContent
```

`ProjectScopeService` is not an `ExtensionRegistry`: the registry is an
observable store that replays an audit log and writes back, and a session launch
must not pay for that. Every failure path in it returns `.unrestricted`, so a
scope that cannot be computed leaves the command line exactly as it found it.
Guessing narrow would strip an agent of tools the user never asked to lose.

The agent's config is read at launch rather than cached, because the user may
have added a server in another window a second ago.

## When a change takes effect

**The next session.** The runtime daemon's `attach` command carries no argv or
environment (`RuntimeClient.openLocked`), so a session already running keeps the
configuration it started with. Restarting or waking the session picks up the new
selection. The picker says this on screen.

## Tests

`Tests/ProjectExtensionScopeTests.swift` — the rule (no records = everything,
one exclusion does not leak to another project, something installed later is
allowed, `uncoil` is never excluded, an agent-scoped record does not bind other
agents), the verbatim allow-list including a secret and an unmodelled key, and
the exact command line each provider gets. The regression that matters most is
`testAnUnrestrictedProjectAddsNothingToTheCommandLine`: every existing user is
on that path.
