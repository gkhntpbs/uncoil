# Simplification plan

> Companion to `COMPLEXITY_AUDIT.md` (2026-09-05). That file is the diagnosis; this one is the
> plan. Nothing here is implemented. Each phase is meant to be handed to an implementation agent on
> its own; the app must build, test and ship at every phase boundary. Finding ids in brackets
> (`SB-01`, `AP-02`, …) point at the audit.

## A. Executive diagnosis

Uncoil is one idea — *a window that shows every agent you are running, tells you which one needs
you, and lets you start another one in the right place* — wrapped in three products that grew
beside it: a package manager (Extensions, 11 sections), a policy console (Settings, 24 panes, five
of them per-provider matrices) and a task-orchestration suite (Tasks, ~20 named concepts). Each of
those is reachable from the first minute, each has its own vocabulary, and each was given a step in
a 13-page first-run flow. The everyday actions, by contrast, are hover-only (starting a session),
right-click-only (customising a project), or palette-only (a dozen commands).

The cause is structural, not visual. There is no registry that says which agents exist and what
each can do (two enums, ~66 provider checks — `AP-01`, `AP-02`), no registry that says what a
project has (four booleans in a page cache — `PRJ-02`, `RT-01`), no registry of actions (every verb
re-implemented per surface — `PAL-01`), and no place that owns "where does a new feature go", so
each feature adds a tab, a pane, an onboarding step and an attention kind (`ONB-02`, `ATT-08`,
`RT-02`). That is why the product will get worse with every release unless the rules change: the
next test framework, the next agent, the usage rules engine (`UH-02`) and the permission rewrite
(`CP-01`) all currently have nowhere to land except another section.

The fix is to (1) decide the five concepts a user must know, (2) build three small registries the
UI reads instead of hand-maintaining lists, (3) make visibility a consequence of detection, and
(4) move everything that is not one of the five concepts behind the thing it belongs to.

## B. Current-state map (condensed)

```
Main window
├─ Sidebar: projects → groups → sessions → child sessions; Scratch; "Finish setup" row;
│  rail: Settings(+update badge) · Add project · Attention bell · Multi-select · Collapse
├─ Detail: Project (General | Tasks | Run | Tests | Issues) · Group page · Session (+split)
│  Session header: provider · title · (model·effort) · account · usage ring · path · branch/worktree
│                  · status · MCP badge · run/stop · log · editor · handoff · restart
└─ Overlays: Onboarding (13 pages) · New-window question (⌘N) · Command palette (⌘K)
Settings window: General(2) · Agents(7) · Notifications(5) · Appearance(3) · "Uncoil"(6) · About
Extensions window: Overview · Agents · Skills · MCP Servers · MCP Catalog · Skill Catalog ·
                   Assignments · Sources · Security · Updates · Activity  (+ own menu, shortcuts)
Menu bar extra: counters · attention rows · quick launch · task shortcuts · orchestrator stop
Popout window (terminal only) · Attention Center popover · macOS notifications
Per-project config: projects.json · .uncoil/run.json · .uncoil/tests.json · TODO.md ·
  registry.json bindings · Settings › Notifications › Per Project · tasks/*.json · handoff/
```

Six independent routing buses (`MainRoute`, `SettingsRoute`, `ExtensionsCommandBus`,
`ProjectAreaRoute`, `HandoffRoute`, `OnboardingPresenter`) plus string window ids reach these
places (`SHELL-02`).

## C. Complexity inventory — the problems this plan solves

Grouped; full evidence in the audit.

**Critical**
1. No agent registry: `AgentProvider` vs `ExtensionAgentID`, provider facts in ~30 files (`AP-01`, `AP-02`, `S2`, `P3`).
2. No project capability registry: `ProjectAreaFacts` is a page-cache side effect; detection runs once per feature (`PRJ-02`, `RT-01`, `RT-02`, `RT-07`).
3. No action registry: verbs re-implemented per surface, palette-only commands, no menus for Project/Session (`PAL-01`, `PAL-03`, `S4`, `SHELL-07`).
4. Onboarding is a feature tour that duplicates Settings and grows per feature; its resume row is dead (`ONB-01..03`, `P2`).
5. Settings › Agents is five provider matrices; "Uncoil" is a category; Permissions fuses two systems (`S1`, `S4`, `S5`, `CP-01`).
6. Extensions is a second application with ~40% unreachable machinery shown as UI (`EXT-01..04`).
7. "Permission" is three mechanisms with three UIs and six vocabularies (`S2`/session, `CP-01`, `CP-07`, `ATT-03`).
8. Primary action (start a session) is hover-only; session row carries nine signals (`SB-01`, `SB-02`).
9. Tasks: eight start verbs, two pipelines, an orchestrator that never executes (`T1`, `T2`, `T6`).
10. Status/attention/notification vocabularies do not align (10 statuses, 18 kinds, 7 events, 12 task states) (`ATT-01`, `ATT-02`).
11. Shell: `MainWindow` is the composition root; no navigation model (`SHELL-01`, `SHELL-02`).
12. Usage: threshold recomputed in five places; the planned rules engine has no home (`UH-01`, `UH-02`).

**High** — provider vocabulary in generic UI (`AP-04`, `S9`, `ATT-13`), four homes for hooks (`S3`, `AP-06`, `EXT-08`), four surfaces offering "set up" the same feature (`PRJ-03`), project config in seven places (`P8`, `PRJ-09`), launch options asked in three places (`S8`, `T3`), Blueprint/Preset/Quick Launch/Launch Profile overlap (`PRJ-05`, `P1`), sessions listed twice (`SB-03`), Tests has no authoring UI (`RT-05`), ~60 notification controls (`ATT-05`), internal names in copy (`S11`, `EXT-11`, `CP-05`, `ONB-13`).

**Medium/Low** — dead settings and services (`S12`, `ATT-12`, `T12`), Turkish strings in English UI (`RT-09`, `EXT-19`, `CP-13`), docs drift (`P5`, `ONB-18`), naming (`SHELL-10`, `UH-11`, `S10`).

## D. Product model

A user needs five words:

| Concept | Definition | Absorbs (becomes detail of it) |
|---|---|---|
| **Project** | A folder you pointed Uncoil at. It *has* things — a git repo, worktrees, a TODO.md, a run setup, tests, a GitHub remote — and what it has decides what its screen shows. | Scratch (= "no project"), Test Workspace (developer tool), area tabs, offers, blueprint, per-project MCP scope, per-project notifications |
| **Agent** | A CLI Uncoil can run (Claude Code, Codex, …), with its login(s). | provider, ExtensionAgentID, adapter, integration level, hooks, CLI install/update, working mode, run parameters, models/effort |
| **Session** | One agent working in one project (or worktree), with a status. | terminal, child session, sleeping/closed, split/popout, resume, transcript, capabilities, MCP link, usage of its login |
| **Task** | A checkbox in the project's TODO.md that a session can be started on. | dispatch, roles, claims, fingerprints, orchestrator, merge/commit, GitHub issue (a task with a remote source) |
| **Needs you** | The one list of things waiting for the user: permission, reply, failure, limit. | AttentionKind, notification events, reminders, menu-bar counters, sidebar pulse |

Everything else is either **an integration** (MCP servers, skills, GitHub, drivers, Bumblebee,
Sparkle) or **a preference**. Integrations are installed, not configured: they appear in the UI
only once present.

Words that leave the UI: preset, grant, capability key, control plane, adapter, driver, hook,
binding, assignment, adoption, mirror, revision, tracking mode, quarantine, drift, transaction,
fingerprint, claim, lease, orchestrator (as a noun), blueprint (→ "project template"), scratch
(→ "no project"), profile (→ "login").

**Core workflows (the 80–90 %)** — each must be one visible click or one shortcut:
add a project · start an agent in a project · see who needs me and answer · read what a session is
doing · start an agent on a task · run/test the project · switch/cut a worktree · open in editor.

## E. Information architecture

**Sidebar** — projects → sessions only. Groups and child sessions stay as tree structure, nothing
else moves in. Every project row gets a *visible* `+` (new session with the default agent; menu on
click for other agents/logins) — hover strip retired (`SB-01`). Rows show: mark, title, status orb,
one attention dot. Pin/clock/children count move to a tooltip/inspector. Rail: Add project · Needs
you · Settings. Multi-select becomes ⌘/⇧-click only. "Finish setup" row removed (see F).
Scratch becomes a "No project" section at the bottom, shown only when it has sessions.

**Project screen** — header (name, branch, editor, `+ New session`) and *sections that exist only
when the capability is present*: Sessions · Tasks · Run · Tests · Changes (git + PRs) · Issues ·
Files. One `Set up…` popover (not four cards) lists absent capabilities with a single "Look"
action backed by one detector (`PRJ-03`). Project settings (name/mark, template, MCP & skills
scope, notifications override, run/test config) live in one **Project Settings** sheet reachable
from the header gear, the context menu and ⌘I — not in global Settings (`P8`).

**Session screen** — header shrinks to: back · title · status (label + detail on hover) · login ·
`⋯` actions. Branch/worktree, run/log, editor, handoff, restart, split, popout, sleep move into
one **Session** menu (menu bar + `⋯` + context menu, same registry). Usage ring stays only for
logins that can report it; otherwise nothing is drawn (`UH-03`). MCP badge removed; a failed link
becomes a "Needs you" item (`S9`).

**Needs you** — one panel (⇧⌘A, rail bell, menu bar) listing items derived from *one* signal
model (§H). Read/resolve is one state. The menu-bar extra shows the same list and a count; its
launcher and orchestrator controls go (`ATT-17`).

**Settings** (⌘,) — five categories, no matrices:
`General` · `Agents` (one page per installed agent, see G) · `Notifications` (one page) ·
`Appearance` · `Integrations` (GitHub, browser driver, computer driver, security scanner —
each a row that is inert until installed) · `Advanced` (transcripts, data, debug bundle,
developer tools). "Uncoil" category disappears.

**Extensions window** → becomes **Integrations › MCP servers & skills**, a single screen with:
installed list (with per-agent toggles inline), *Add* (catalog, folder, JSON, adopt from an agent
config) and a *Security* disclosure. Sources, Updates, Activity, Assignments, Overview are
removed from the UI until the engine behind them is wired end to end (`EXT-02`, `EXT-03`); the code
stays. Its top-level menu and shortcuts are removed (`PAL-03`).

**Command palette** — reads the action registry; no longer the only home of anything.

**Windows** — ⌘N opens a window immediately (same scope); "New Uncoil Window" and "Open in New
Window" are the only two names (`SHELL-05`, `SHELL-10`).

## F. Onboarding

Principle: **first launch → working session in three actions.** No page explains a feature the
user has not touched.

- **First launch**: one screen. Detected agents listed with a check (installed) or an *Install…*
  link; a default is preselected; one button *Add a project…*. Interface language follows the
  system. Nothing else is asked. Skipping = closing.
- **First project**: folder picker → project appears. No sheet. Name = folder name; template only
  offered when templates exist, as a card *inside the empty Sessions section*.
- **First agent**: `+` on the project row. If the agent needs login, the login sheet appears
  inline. If status tracking needs a hook (Claude), a one-line banner in the session offers
  *Turn on status* with one button; declining is remembered per agent.
- **First optional capability** (Computer Use, browser, Bumblebee, GitHub, tests, run, tasks):
  offered *at the point of use* — the Set up popover, the Integrations row, or the first agent
  request for it — never in advance.
- Recommended vs optional is a property of the capability registry, not of a flow. Onboarding
  therefore has a fixed size: it cannot grow, because it only renders "agents present / project
  present". `OnboardingStep` and the version gate are deleted; "Run again" becomes "Show welcome".

## G. Settings architecture

| Tier | Owns | Home | Inherits from |
|---|---|---|---|
| Global preference | editor, language, quit policy, shortcuts, appearance, notification defaults, usage warn threshold | Settings | — |
| Agent | login(s), default login, default working mode, extra CLI args, binary location, status hook, update | Settings › Agents › *one page per installed agent* | global |
| Project | name/mark, template, MCP & skills scope, run/test config, notification override, default agent | Project Settings sheet (⌘I) | agent + global |
| Session | working mode / model / effort override, capabilities override, login | session `⋯` › Options | project |
| Integration | installed-or-not, credentials, driver permissions | Settings › Integrations (row appears when installed) | — |

Conventions for developers:
1. A setting has exactly one home, chosen by the tier table; onboarding never re-implements a control.
2. Anything derivable from disk or `--help` is detected, cached, and shown read-only (binary path, CLI version, models, scoping support, launcher order).
3. A provider-specific option is rendered by the agent's descriptor on *its* page, never as a matrix across agents.
4. Overrides are explicit and revertible ("Use project default"), stored beside the thing they override (`SessionRecord`, `Project`), never in a parallel table.
5. Experimental features are behind one `Advanced › Experimental` list of toggles read from the capability registry; they add no pane, menu or step.
6. Removed rather than kept dark: Session Presets editor (presets stay as code-defined roles for `create_child`), Run Parameters/Working Mode/CLI Tools/Installed Agents matrices, Quick Launch page (order = installed agents, drag in sidebar `+` menu), Notifications Events/Reminders/Quiet Hours/Per Project panes (one page with three rows; quiet hours defers to macOS Focus), Agent Status Hooks pane, Uncoil MCP pane (status moves to Advanced), Permissions pane (see H), Drivers pane (→ Integrations rows).

## H. Capability system

Three registries, one signal model. Swift-shaped, incremental, each replacing named code.

**`AgentDescriptor`** (`App/Core/Agents/AgentDescriptor.swift`) — one value per agent:
`id`, `displayName`, `mark`, `launchCommand`, `loginCommand`, `configRootEnv`, `resumeStyle`,
`statusSource (.hooks/.appServer/.none)`, `controlPlane (.mcpConfigFile/.cliOverride/.env/.none)`,
`extensionScoping`, `workingModes: [WorkingMode]` (agent-native labels), `launchOptions`
(models/efforts detection), `usageRoute`, `handoffSupport`, `updater`, `configAdapter`.
`AgentRegistry.installed` = descriptors whose binary resolves. Replaces `AgentProvider`'s eleven
computed properties, `ExtensionAgentID`, `AgentIntegration`, `AgentProviderCapabilities`,
`AgentLaunchCatalog` switches, `HandoffProducer.canProduce`, `UsageStore` provider switch
(`AP-02` list). `AgentProvider` stays as the persisted id.

**`ProjectCapabilities`** (`App/Core/Projects/ProjectCapabilities.swift`) — a `Set<Capability>`
per project computed by one `ProjectDetector` (git, worktrees, GitHub remote, TODO sources, run
configs, test suites, Xcode/SwiftPM/Node/Python/Go/Rust/Docker/Maestro stacks) with one cache and
file watchers; stored on `ProjectStore`, not on a page. Sections, offers, header buttons, palette
items and MCP tool availability read it. Replaces `ProjectAreaFacts`, `ProjectPageStore.areaFacts`,
`RunDefaultControl`'s file read, `TodoDiscovery.hasSources` callers, `GitHubRepoDiscovery` callers.
New stack/framework = one `StackDetector` + one `Capability` case; nothing else changes.

**`IntegrationRegistry`** (`App/Core/Integrations/`) — one `Integration` per optional binary or
service (agent-browser, cua-driver, Bumblebee, GitHub, Sparkle): `state (.absent/.installed/.needsPermission/.ready)`,
`install` (always user-approved), `probe`. Settings › Integrations and the "Needs you" list read it.
Replaces `DriverSetupSections` probes, `BumblebeeSetupSection`, onboarding tool cards.

**`ActionRegistry`** (`App/Core/Actions/`) — `Action(id, title, shortcut, icon, scope: .app/.project/.session/.task, isAvailable(ctx), perform(ctx))`.
Main menu, context menus, `⋯` menus, palette and menu-bar extra are generated from it. Replaces
`PaletteAction` + `MainWindow.perform`, `SidebarRowActions`, `ExtensionsCommandBus`, the five restart
implementations (`S17`), `RunRepair`/`TestRepair`/issue hand-off variants (one `handToAgent` action).

**Signal model** — one `Signal(kind: .permission/.reply/.done/.failure/.limit/.login, subject: session|project|login, severity, resolvedWhen)`
raised by sessions, runs, tests, tasks, usage. Status orb, Needs-you list, notifications, menu bar
and sidebar dot render *the same* signals. Replaces the 18 `AttentionKind`s, `unseenAttention`,
read/resolved marks, and the notification ledger's event mapping (`ATT-01`, `ATT-04`).

**Visibility rule**: a view may only gate on a registry value (`agent.supports(x)`,
`project.has(.tests)`, `integration.state`, `action.isAvailable`) — never on `provider == .claude`
or a file read. A lint (grep in CI) enforces it after Phase 3.

## I. Progressive disclosure

- **Level 0 (always)**: sidebar, project sections that exist, session header (6 items), Needs you.
- **Level 1 (one click, contextual)**: `+` menu (other agents/logins), `⋯` menus, Set up popover, Project Settings sheet, Session Options.
- **Level 2 (on demand)**: Task dispatch details (roles, worktree, review) behind *Send with options…*; Integrations window; Advanced settings.
- **Level 3 (opt-in)**: Computer Use, per-session capability overrides, experimental toggles, orchestrator (only after it executes plans).
- **Developer**: test workspace, debug bundle, launch flags — `Advanced › Developer`, never in the palette by default.

Power is preserved by parity, not by visibility: every level-1+ action is in the action registry,
so it has a menu item, a shortcut where sensible, a palette entry and a context-menu entry.

## J. Placement rules for a new feature

1. **Is it a new capability of a project, an agent, or an integration?** → add a case to that registry; UI appears where that registry is rendered. Stop.
2. **Is it an action on an existing concept?** → add an `Action` with a scope; menus/palette/context pick it up. Stop.
3. **Is it a signal the user must act on?** → add a `Signal.kind`; Needs you, notifications and menu bar follow. No new settings.
4. **Does it need configuration?** → find its tier (G). Global only if it is a taste preference independent of any project/agent. Otherwise it goes beside its owner.
5. **Is it optional/experimental?** → `Integration` or `Advanced › Experimental` toggle. Never a step, tab, or category.
6. **Does it still seem to need a sidebar item, tab, settings category or onboarding page?** → it is not one feature; split it, or it is replacing one of the five concepts and needs an owner decision.

## K. Structural code changes

1. `AgentDescriptor` + `AgentRegistry`; delete `ExtensionAgentID` after a mapping period.
2. `ProjectDetector` + `ProjectCapabilities` on `ProjectStore`; `ProjectPageStore` keeps only fetched data (git snapshot, PRs).
3. `ActionRegistry`; `MainWindow.perform` becomes a thin dispatcher; one `Router` replaces the six buses (`SHELL-02`) with `Destination` enum + `openWindow` in one place.
4. `AppServices` composition root started from `UncoilApp` (`SHELL-01`), not from `MainWindow.onAppear`.
5. `Signal` model replacing `AttentionKind`, `unseenAttention`, notification event mapping.
6. `IntegrationRegistry`.
7. `SettingsSchema`: each setting declared once (tier, key, title, keywords) — search, deep links and pages derive from it (`S11`).
8. One `RunnableConfig` model for run.json/tests.json with `kind` (`RT-10`); one `StackDetector` protocol.
9. `ExtensionRegistry` single instance injected (`EXT-04`).
10. One `SessionLaunchRequest` used by every creation path (`S6`); one prompt builder for tasks (`T1`).
11. Delete: `OnboardingStep`/flow/version, `LauncherPrefs` ordering page, dead policy objects (`T12`), `MenuBarPrefs.clickAction`, `AgentProfile`, Backup/Uninstall services until surfaced.

## L. Migration plan

Each phase ships; nothing is half-migrated at a boundary. Unit suite green at every step; UI tests
updated only for flows a phase changes.

**Phase 0 — Registries under the existing UI (no visible change)**
- Objective: introduce `AgentDescriptor/Registry`, `ProjectDetector/Capabilities`, `ActionRegistry`, `Router`, `AppServices`; make existing views read them without changing layout.
- Code: `App/Core/Agents/*`, `App/Core/Projects/ProjectCapabilities.swift`, `App/Core/Actions/*`, `App/Core/Router.swift`, `App/UncoilApp.swift`, `MainWindow.swift` (perform → registry), `ProjectPageStore.swift`, `PaletteModel.swift`.
- Depends on: nothing. Risk: low (adapters wrap existing switches). Tests: registry tables pinned by tests that fail if a provider fact is re-stated outside the descriptor.
- Do not touch yet: Settings, onboarding, Extensions, any copy.

**Phase 1 — Everyday path**
- UX: visible `+` on project rows (retire hover strip); Project screen sections from capabilities; single Set up popover; session header reduced to six items with a `⋯` menu; Project and Session menus in the menu bar with shortcuts; ⌘N opens a window; ⌘I Project Settings sheet (identity + MCP scope + notifications override moved in).
- Code: `SidebarView.swift`, `SidebarOutline.swift`, `ProjectDashboardView.swift`, `ProjectAreaOffers.swift` (delete), `SessionHeaderBar.swift`, `UncoilApp.swift` commands, `ProjectCustomizeSheet.swift` → `ProjectSettingsSheet`, `NotificationSettingsPages.swift` (Per Project moves out).
- Depends on: Phase 0. Risk: medium (most-used surfaces); mitigated by keeping old context-menu items until parity is proven by the action registry test.
- Do not touch yet: Extensions window, Tasks internals, permissions.

**Phase 2 — Onboarding and signals**
- UX: one-screen welcome; contextual hook/login/permission prompts; "Needs you" panel replaces Attention Center; menu bar shows the same list; notification settings collapse to one page.
- Code: delete `App/UI/Onboarding/*` except welcome + chrome, `OnboardingState.swift`; new `App/Core/Signals/*`; `AttentionCenter.swift` → signal adapter; `NotificationPrefs.swift`, `NotificationPolicy.swift`, `MenuBarMonitor*.swift`, `SessionStore+Hooks.swift`.
- Depends on: Phase 1 (contextual prompts need the new `+` and header). Risk: medium (notification behaviour changes; keep event→signal mapping table tested).
- Do not touch yet: Extensions, task orchestration.

**Phase 3 — Settings restructure**
- UX: five categories; one page per installed agent; Integrations category; Advanced; remove matrices, presets editor, Quick Launch, Hooks, Uncoil MCP, Drivers, Permissions panes.
- Code: `SettingsView.swift` (schema-driven), new `AgentSettingsPage` (per descriptor), `IntegrationsSettingsPages.swift`, `DriverSetupSections.swift` → integration rows, `SettingsStore.swift` (drop `configuredPresets`, `launcher`, keep migration), `SettingsSchema.swift`.
- Depends on: Phase 0 (descriptor), Phase 2 (signals for permission requests). Risk: medium (deep links, search); legacy pane ids map to new destinations.
- Do not touch yet: permission model itself (N.5), Extensions engine.

**Phase 4 — Permissions and capabilities as one flow (aligns with TODO N.5)**
- UX: any "may the agent do X" request (control plane, Codex approval, Claude hook) becomes a Signal answered in-session with scope once/session/project/always; per-session capability overrides in Session Options; working-mode labels are the agent's own words; grant keys never shown.
- Code: `PermissionService.swift`, `PermissionNotifications.swift`, `CapabilityCatalog.swift` (grouping becomes the single source), `CodexAppServerSession.swift` approval path, `PrivacySettingsPages.swift` (delete), `TaskDispatchSheet.swift` (drop preset/permission-profile rows).
- Depends on: Phase 2, 3. Risk: high (security-relevant); fail-closed defaults, tests for every route.

**Phase 5 — Extensions → Integrations**
- UX: one MCP servers & skills screen; add paths unified; unreachable sections hidden; Bumblebee as an Integration; top-level Extensions menu removed.
- Code: `ExtensionsView.swift` (split into `IntegrationsMCPScreen`), `ExtensionsCommands.swift` (delete), `ExtensionRegistry.swift` single instance, `ProjectExtensionPicker.swift` (tabs from installed agents, not Quick Launch).
- Depends on: Phase 0, 3. Risk: medium; engine code untouched, only surfaces.

**Phase 6 — Tasks and run/test convergence**
- UX: one *Start on task* verb with *options…*; orchestrator hidden until it executes; Tests gets the same editor as Run; issues become tasks with a remote source; "Fix with agent" is one action.
- Code: `ProjectTasksView.swift` (split), `TaskDispatch.swift`, `TaskOrchestrator*.swift` (gate), `RunConfig.swift`/`TestSuiteConfig.swift` → `RunnableConfig`, `ProjectTestsView.swift`, `RunRepair.swift`/`TestRepair.swift` → one action.
- Depends on: Phase 0, 1. Risk: medium (TODO.md writes; parser tests already exist).

**Phase 7 — Cleanup**
- Delete `ExtensionAgentID`, `AgentIntegration`, dead policy/config objects, Turkish strings in English UI, stale docs (`STATUS.md`, `CLAUDE.md` flags), `LaunchConfig` routes read by production views (move behind `Router`).
- Depends on: all. Risk: low.

## M. Target end state

Opening Uncoil shows projects on the left and, for each, the agents running in it with a colour
that says who needs you. A `+` on any project starts the default agent; a click on the `+` picks
another. The project screen shows only what the folder actually has, and offers to set up the
rest in one place. A session shows a terminal with a six-item header; everything else about it is
one `⋯` away and also in the Session menu, with a shortcut. One panel lists what needs you; the
menu bar shows the same count. Settings has five categories and a page per agent you have
installed, written in that agent's own words. Optional tools appear the day they are installed and
not before. Power users lose nothing: every action has a menu item, shortcut, palette entry and
context-menu entry generated from one list, per-session overrides exist, and the MCP control
plane, orchestration and security scanning are all still there — behind the thing they act on. A
new feature is a registry case and an action, and the interface grows by exactly what that
feature is, nowhere else.
