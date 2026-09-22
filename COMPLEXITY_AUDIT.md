# Product complexity audit — current state

> Generated 2026-09-05 from a code-level audit of the `edge` branch (0.2.0). Fifteen subsystem readers each followed real user flows through the code and recorded surfaces, concepts, configuration points, visibility gates and complexity findings. Findings are **unverified** (the adversarial verification pass was not run); treat file:line references as pointers to check, not as settled facts. This file is the raw material for the restructuring plan; it proposes nothing.

## How to read this

- **Severity**: critical = blocks a coherent mental model or compounds with every new feature; high = a real cost in everyday workflows; medium = friction; low = polish.
- **Concept flags**: `U` user-facing, `i` internal; `!` = an internal name is shown to the user as-is.
- **Config flags**: `INF` = could be inferred or defaulted away instead of configured.

**Totals:** 282 findings — 35 critical, 86 high, 121 medium, 40 low — across 15 subsystems.

## Critical findings across the product

- **SHELL-01** (Application shell, navigation and routin): MainWindow is the app's composition root: a SwiftUI view starts three servers, two background loops and the update check — `App/UI/MainWindow.swift:315`; `App/UI/MainWindow.swift:823`; `App/UI/MainWindow.swift:998`
- **SHELL-02** (Application shell, navigation and routin): No navigation model: three MainSelection cases plus six independent singleton route buses, string window ids and a test-only launch route — `App/UI/MainWindow.swift:3`; `App/UI/MenuBarMonitorView.swift:6`; `App/UI/Settings/SettingsView.swift:5`
- **SB-01** (Sidebar): The primary action (start a session) is a hover-only strip with a hidden right-click inside it — `App/UI/SidebarView.swift:604`; `App/UI/SidebarView.swift:680`; `App/UI/SessionDetailView.swift:249`
- **SB-02** (Sidebar): A session row carries up to nine signals plus four invisible gestures — `App/UI/SidebarView.swift:861`; `App/UI/SidebarView.swift:874`; `App/UI/SidebarView.swift:889`
- **PRJ-01** (Project screen): The project 'General' page is a git dashboard, a setup wizard, a session list and a file browser at once — `App/UI/ProjectDashboardView.swift:179`; `App/UI/ProjectDashboardView.swift:269`; `App/UI/ProjectDashboardView.swift:519`
- **PRJ-02** (Project screen): ProjectAreaFacts is the seed of a capability registry but lives as a per-screen snapshot, and each new area must be threaded through five places — `App/Core/ProjectAreaAvailability.swift:80`; `App/Core/ProjectAreaAvailability.swift:15`; `App/Core/ProjectPageStore.swift:108`
- **RT-01** (Project dashboard areas Run, Tests and I): The project's stack is detected once per feature, never once per project — `App/Core/RunDetection.swift:39`; `App/Core/TestDetection.swift:25`; `App/Core/GitHubIssues.swift:219`
- **RT-02** (Project dashboard areas Run, Tests and I): No framework/run-kind registry: adding a test framework touches ~9 places, a run kind ~7 — `App/Core/TestSuiteConfig.swift:10`; `App/Core/TestDetection.swift:36`; `App/Core/TestOutputParser.swift:95`
- **T1** (Tasks area and task orchestration): Eight verbs start an agent on a task, through two different pipelines with different prompts, state handling and attention behaviour — `App/UI/ProjectTasksView.swift:786`; `App/UI/ProjectTasksView.swift:1134`; `App/UI/ProjectTasksView.swift:1137`
- **T2** (Tasks area and task orchestration): The orchestrator is a facade: the plan is computed and persisted but never executed, 'Stop the Orchestrator' stops nothing, and its invisible settings gate every merge — `App/UI/ProjectTasksView.swift:1495`; `App/UI/ProjectTasksView.swift:1327`; `App/Tasks/TaskOrchestrator.swift:185`
- **S1** (Session screen and terminal): The session header is a fourteen-control dashboard that mixes identity, metadata, status, project actions and account economics on one bar — `App/UI/SessionHeaderBar.swift:83`; `App/UI/SessionHeaderBar.swift:113`; `App/UI/SessionHeaderBar.swift:130`
- **S2** (Session screen and terminal): 'Permission' is three different mechanisms with three different UIs, two of which share one status — `App/Hooks/SessionStore+Hooks.swift:85`; `App/UI/SessionDetailView.swift:41`; `App/Core/LaunchConfig.swift:87`
- **UH-01** (Usage tracking and handoff): The one decision ("is this account low?") is recomputed in five views/services with the global threshold, and N.7.5 would add a sixth trigger — `App/UI/SessionHeaderBar.swift:65`; `App/UI/SessionHeaderBar.swift:317`; `App/UI/UsageChip.swift:207`
- **UH-02** (Usage tracking and handoff): N.7.5's rules engine has no home: its eight concepts map onto five different existing surfaces and two colliding verbs — `TODO.md:404`; `TODO.md:410`; `TODO.md:415`
- **ONB-01** (First-run onboarding): The 'Finish setup' resume row is unreachable, yet three pages, the About copy and the CHANGELOG promise it — `App/UI/Onboarding/OnboardingView.swift:125`; `App/Core/SettingsStore.swift:736`; `App/Core/OnboardingState.swift:89`
- **ONB-02** (First-run onboarding): Setup is a tour of every subsystem: 13 pages, 11 'actionable', zero required, and it grows by one page per feature — `App/Core/OnboardingState.swift:9`; `App/Core/OnboardingState.swift:48`; `App/Core/OnboardingState.swift:61`
- **S1** (Global Settings window): Seven 'Agents' panes are per-provider matrices that grow by construction with every new provider — `App/UI/Settings/SettingsView.swift:108`; `App/Core/Models.swift:40`; `App/UI/Settings/AgentSettingsPages.swift:20`
- **S2** (Global Settings window): Two agent identity enums feed different panes; Amp exists only in Installed Agents — `App/Extensions/ExtensionModels.swift:8`; `App/Extensions/ExtensionModels.swift:43`; `App/Core/Models.swift:20`
- **S3** (Global Settings window): Claude hook install has four surfaces and two services; the dedicated Hooks pane is a Claude-only subset of Installed Agents — `App/UI/Settings/PrivacySettingsPages.swift:341`; `App/UI/Settings/PrivacySettingsPages.swift:375`; `App/Extensions/AgentHookupService.swift:186`
- **S4** (Global Settings window): Permissions pane fuses two systems (capability grants vs. runtime permission requests) and cannot edit the one default users are told it can — `App/UI/Settings/PrivacySettingsPages.swift:96`; `App/UI/Settings/PrivacySettingsPages.swift:150`; `App/UI/Settings/PrivacySettingsPages.swift:198`
- **EXT-01** (Extensions window): The Extensions window is a second application: 11 sections, its own sidebar, search, menu, shortcuts, toasts and roster — `App/UI/ExtensionsView.swift:5`; `App/UI/ExtensionsCommands.swift:43`; `App/UI/ExtensionsView.swift:238`
- **EXT-02** (Extensions window): Updates, Sources, tracking modes and revision rollback are unreachable end-to-end: no production code computes an update candidate or materialises a mirror — `App/Extensions/ExtensionUpdateEngine.swift:77`; `App/Extensions/ExtensionRegistry.swift:409`; `App/Extensions/ExtensionMirror.swift:31`
- **EXT-03** (Extensions window): Launcher, manifest, secret server and process health are not wired: four rows and two buttons on every MCP card are permanently inert and secrets have no entry UI — `App/Extensions/ExtensionLauncherService.swift:50`; `App/Extensions/ExtensionRegistry.swift:624`; `App/UI/ExtensionsView.swift:1695`
- **EXT-04** (Extensions window): Four live ExtensionRegistry instances write the same registry.json with last-save-wins; the code comment admits data loss and leaves it — `App/Extensions/ExtensionRegistry.swift:69`; `App/UI/ExtensionsView.swift:121`; `App/UI/ProjectCustomizeSheet.swift:28`
- **AP-01** (Agent/provider abstraction): Two parallel agent identity enums (AgentProvider vs ExtensionAgentID) with a hand-maintained bidirectional map, so 'the agent list' has three different lengths across the UI — `App/Core/Models.swift:20`; `App/Extensions/ExtensionModels.swift:8`; `App/Extensions/ExtensionModels.swift:33`
- **AP-02** (Agent/provider abstraction): No capability registry: per-provider facts are spread over ~21 `switch provider` sites and 45 `provider == .x` checks in ~30 files, with the same fact re-stated in 3-4 places — `App/Core/Models.swift:131`; `App/Extensions/AgentIntegration.swift:63`; `App/Extensions/AgentHookupService.swift:100`
- **ATT-01** (Status, attention, notifications and the): Four unaligned vocabularies say 'the agent needs you': 10 statuses, 18 attention kinds, 7 notification events, 12 task states — `App/Core/Models.swift:610`; `App/Core/AttentionCenter.swift:4`; `App/Core/NotificationPrefs.swift:10`
- **ATT-02** (Status, attention, notifications and the): Notification settings promise events the wiring can never deliver: taskCompleted, mergeReady, and most 'problems' never fire; two of four reminders are inert — `App/UI/MainWindow.swift:908`; `App/Tasks/TaskAttention.swift:128`; `App/Tasks/TaskAttention.swift:138`
- **ATT-03** (Status, attention, notifications and the): 'Done', 'Login required' and permission handling differ per provider: Claude and Codex take different paths through status, rows and banners — `App/Hooks/SessionStore+Hooks.swift:108`; `App/Codex/CodexAppServerSession.swift:429`; `App/Core/AttentionCenter.swift:167`
- **CP-01** (MCP control plane as it surfaces in the ): At least ten distinct 'may the agent do this' concepts, each with its own UI and vocabulary — `App/UI/Settings/PrivacySettingsPages.swift:78`; `App/UI/Onboarding/OnboardingPlatformSteps.swift:364`; `App/UI/Settings/AgentSettingsPages.swift:683`
- **CP-02** (MCP control plane as it surfaces in the ): The two grant keys the directional flow actually uses are not catalog keys, so real requests show raw keys and can never be answered from the banner — `App/ControlPlane/SessionsHandler.swift:193`; `App/ControlPlane/SessionsHandler.swift:153`; `App/ControlPlane/CapabilityCatalog.swift:79`
- **PAL-01** (Command palette, quick actions, keyboard): No action registry: every command is re-implemented per surface (palette, menus, sidebar menus, header, menu-bar), with behaviour and naming drifting between copies — `App/Core/PaletteModel.swift:8`; `App/UI/MainWindow.swift:369`; `App/UI/MainWindow.swift:413`
- **P1** (Product intentions and pending plans): Four generations of 'a saved way to start an agent' coexist: Launch Profile (plan), Session Preset, Blueprint, Quick Launch — plus the dispatch sheet's own model/effort/mode — `docs/roadmap/FOUNDATION_PLAN.md:606`; `docs/current/STATUS.md:46`; `CHANGELOG.md:17`
- **P2** (Product intentions and pending plans): The first-run flow has grown from nine to thirteen steps, duplicates six Settings pages, and the backlog already calls it the worst thing about the product — `CHANGELOG.md:160`; `App/Core/OnboardingState.swift:9`; `App/Core/OnboardingState.swift:56`
- **P3** (Product intentions and pending plans): Two agent rosters (AgentProvider vs Extensions AgentKind) and three public counts (three / seven / eight) — no single registry says which agents exist and what each can do — `README.md:48`; `App/Core/Models.swift:20`; `App/Extensions/ExtensionModels.swift:90`

## Recurring structural themes

- *Application shell, navigation and routin*: **There is no capability or destination registry; every navigable thing is a separate enum with its own transport** — Adding a screen means choosing (or inventing) a bus, adding a string alias, a palette item, a launch flag and a menu item by hand; nothing can list what the user can do or where they can go, which is why the palette, menus, sidebar rail and menu bar all disagree about the command set.
- *Application shell, navigation and routin*: **The shell's composition root is a View's onAppear, so app-lifetime services scale with window count and feature count** — Feature wiring (MCP, hooks, security scans, permissions, usage attention) is expressed as shell code, so the shell file is 1197 lines and had to be split for the type checker; ⌘N re-runs part of startup.
- *Application shell, navigation and routin*: **Multi-window identity/ownership is the shell's dominant abstraction, but it is only partially applied** — Selection, scope, ownership and palette are per window; sidebar layout, onboarding, collapsed projects and all settings are global; popouts follow a third set of rules. The user-facing result is a 'workspace' concept that appears only on ⌘N and then behaves inconsistently.
- *Application shell, navigation and routin*: **Two settings-like surfaces (Settings 24 panes, Extensions 11 sections) live in separate windows with separate chrome and separate menus, while the main window has 3 destinations** — Configuration outnumbers work surfaces roughly 12:1 in navigable destinations; 'Agents' appears as a Settings pane (installedAgents), an Extensions section (agents) and an onboarding step (clis).
- *Sidebar*: **The sidebar is the only navigation model, so every new feature lands in it** — There is no second axis (sections, filters, a history/closed area, a notifications area) to absorb growth, so the tree keeps absorbing it and the row keeps absorbing signals.
- *Sidebar*: **Hover and right-click are the default affordances** — Nothing in the column at rest tells a new user what it can do; the app compensates with explanatory sentences in three other places (SessionDetailView.swift:249, ProjectDashboardView.swift:425, LauncherSettingsPage.swift:31).
- *Sidebar*: **Session identity and status are provider-flavoured end to end** — Adding a provider touches the row, the strip, the menus, the palette, the status palette and the empty state; the user's mental model of "a session" is tied to which vendor it runs.
- *Sidebar*: **Actions have no shared catalogue: menus, palette, rail, dashboard and empty states each declare their own** — Labels drift (finding SB-11), capabilities appear in one surface and not another, and each new action costs edits in three files.
- *Sidebar*: **Two nesting hierarchies and two collapse stores** — Users cannot tell "in a folder" from "spawned by"; state that survives a relaunch depends on which kind of container they collapsed.
- *Sidebar*: **Attention/urgency is computed in three places with three visuals** — The same event (agent waiting) is signalled by a pulsing row, an orb animation, a bell tint and possibly a menu-bar item, each with its own colour rule; the gear badge adds an unrelated fourth signal in the same 60pt of rail.
- *Project screen*: **Feature availability is a per-visit side effect of the dashboard, not a property of the project** — There is no capability registry to hang visibility rules on; each new feature adds another enum case, another flag, another view switch and another ad-hoc detector elsewhere.
- *Project screen*: **Project identity, project configuration and project state are split across projects.json, repo files, UserDefaults, the extension registry and notification prefs** — No surface can show 'everything about this project'; the Customise sheet claims to but covers two of six.
- *Project screen*: **Blueprint and SessionPreset are parallel 'stored prompt + launch' models with no shared type and adjacent settings pages** — Two vocabularies for one idea; any future 'recipe' feature will have to pick one or add a third.
- *Project screen*: **Scratch is modelled as a Project flag, so every project surface must remember to check it, and most do not** — The dashboard, offers, palette per-project commands and future project features leak onto Uncoil's own folder by default.
- *Project screen*: **Detection and setup logic is duplicated in views rather than owned by the capability** — Four labels and three code paths for 'turn this feature on'; changing detection behaviour means editing views.
- *Project screen*: **Three add-project flows with different questions** — What a new project is asked depends on the button that created it; the 'asked once' promise in NewProjectSheet's header does not hold.
- *Project dashboard areas Run, Tests and I*: **Tab-per-feature growth with a five-case enum and four booleans as the only capability model** — Every feature becomes a tab + a fact boolean + an offer string + a detection walk + a `.uncoil/` file + an MCP action family. The header already drops labels at 720pt; a Preview/Simulator/API tab is the next enum case with no place to put shared stack facts.
- *Project dashboard areas Run, Tests and I*: **Run and Tests are parallel, hand-mirrored stacks rather than one model with two kinds** — Six pairs of near-duplicate types diverge in small deliberate ways (repair target, editor presence, retention, status labels, feedback copy) that the user experiences as inconsistency between two adjacent tabs; every fix must be made twice.
- *Project dashboard areas Run, Tests and I*: **Feature visibility is decided in views and page caches, not by a capability registry** — There is no single answer to 'what can this project do and where is it shown'; the Attention Center, session header, tab row and offers each reimplement a slice, and they disagree (a failure is visible in the tab but cannot be routed to or notified).
- *Project dashboard areas Run, Tests and I*: **The agent contract is the product model; the human UI is a form over it** — Concepts like source, ready_pattern, depends_on, framework and issue codes are correct for agents and land unchanged on humans; adding human-facing polish means adding a translation layer that does not exist yet.
- *Project dashboard areas Run, Tests and I*: **'Preview' is a name, not a feature, and the roadmap has no anchor for simulators/devices/API clients** — The tab is called Run, the doc is called Dev Preview, and the only preview is a browser hand-off. Nothing in the repo plans an in-app preview, simulator picker or API client; if they come, the current schema (free-text command) and the tab-per-feature pattern are what they will inherit.
- *Tasks area and task orchestration*: **No capability/feature registry for Tasks — every visibility rule is inline in ProjectTasksView (1789 lines) and the sheets** — Adding one option (say, a second worktree mode) means touching the list row, the card, the context menu, two sheets, the attention engine and the MCP handler separately; nothing declares 'this feature exists and is on for this project'.
- *Tasks area and task orchestration*: **Two prompt builders and two start pipelines** — The agent's ability to report state — and therefore every badge, filter, attention row and merge gate in the UI — depends on which button the user pressed.
- *Tasks area and task orchestration*: **Two board models (heading lanes vs execution-state columns) and five status vocabularies** — There is no single answer to 'what is this task's status' — the row label, the filter chip, the column, the attention row and the MCP field can all disagree, and each new state has to be mapped into five places.
- *Tasks area and task orchestration*: **Orchestration exists as pure logic without an executor, plus a policy file without a UI** — The user-visible consequences (merge blockers, 'Stop the Orchestrator', preset 'Task Orchestrator', grant 'tasks.orchestrate', role 'Orchestrator') outrun what the app does, so the mental model is built on promises.
- *Tasks area and task orchestration*: **Five policy/configuration objects touch one flow, in four scopes, with three of them having no surface** — There is no place a user or a designer can look to see 'what governs a task run'; the answer is spread over Settings, onboarding, a per-project JSON file with no editor, and per-send sheet state.
- *Tasks area and task orchestration*: **The session side is blind to tasks** — The Tasks tab has a Sessions mode to compensate, which duplicates the sidebar; the more natural place (a chip on the session) does not exist, so the concept 'assignment' has to be learned inside Tasks only.
- *Tasks area and task orchestration*: **Agents can do more to task state than the UI can, through 36 MCP actions with aliases and role-specific hard-coded presets** — The UI's badges and gates are effectively an MCP dashboard; a design that reduces user-facing concepts has to decide which of these the agent surface keeps, because the UI cannot show fewer states than agents can set.
- *Session screen and terminal*: **No capability registry: provider facts live as nine computed properties on an enum plus provider branches in the launcher and runtime, and every view asks them directly** — Adding a provider or a feature means touching the enum, the launcher, the runtime sniffing, and every view that gates on a predicate; inconsistencies (MCP badge on non-wired providers, status on terminals) already exist and will multiply.
- *Session screen and terminal*: **Status is a flat 10-state enum plus a free-text detail written by four unrelated sources, rendered four different ways** — Vocabulary drifts per surface and per provider; a redesign of 'what state is my agent in' has no single seam to change.
- *Session screen and terminal*: **Session creation has one constructor but twelve policy sites and one structured request type used by only one of them** — Defaults (account, title, mode, worktree) are re-derived per call site with divergent outcomes; onboarding promises cannot be kept uniformly.
- *Session screen and terminal*: **Session actions are not modelled; each surface hard-codes a subset** — Users learn five maps; developers duplicate the restart ritual; new actions (interrupt in the header, close from the sidebar) have no obvious home.
- *Session screen and terminal*: **Three view variants of one session (detail, split pane, popout) with separate restart state and different chrome** — Any header change is a two-file change plus a popout that quietly lags; ownership rules are explained after the fact.
- *Session screen and terminal*: **Permission is three subsystems (Claude hook notification, Codex structured approval, control-plane PermissionService) with no shared request model** — The session screen can only ever render the Codex one; the others live in the terminal or in Settings; a unified 'agent is asking' surface has to be built across three models.
- *Session screen and terminal*: **Launch configuration is composed from five layers with implicit precedence inside the launcher** — Users see three settings pages, an onboarding step, two sheets and a header aside for what is one object; nothing shows the resolved result.
- *Usage tracking and handoff*: **No capability table for what each provider supports; three independent switches answer three related questions and no view consults them** — Every provider-specific truth is discovered by the user after acting (dashed chip, failed ask, profile reporting the wrong login). Adding an eighth agent or a new route means editing each switch and hoping the UI's generic gates still make sense.
- *Usage tracking and handoff*: **The verdict is computed at the edges, not once** — Per-project or per-account thresholds (TODO.md:410-412) require touching six sites; any miss produces a chip and a row that disagree, the exact failure the design comments say they are arranged against.
- *Usage tracking and handoff*: **Cross-surface glue is a set of singletons rather than a session-level action** — The handoff is reachable from the Attention Center only because the currently mounted header polls a global mailbox. An automatic rule (N.7.5) would have to either mount a header or bypass the sheet entirely, creating a second code path for the same act.
- *Usage tracking and handoff*: **The handoff is delivered through the terminal by typing, and leaves its artifact in the user's repository** — The feature depends on PTY readiness heuristics and on the repository tolerating an extra file; every future consumer of the package (history view, rules preview, re-pointing the task) has to read it back out of a project directory that may have been cleaned or committed.
- *Usage tracking and handoff*: **Usage settings sit in General as "Provider Limits" while their consequences are governed under Notifications and Menu Bar, and their subjects (accounts, CLIs) under Agents** — There is no pane where N.7.5's rules, per-project overrides, destination chains and handoff history could be added without either overloading General or creating a fifth home.
- *First-run onboarding*: **A step is a feature area, so the flow's length is a function of the feature count** — Every feature negotiates for a page and a version bump; existing users replay the tail on each bump (ONB-09); the required path (detect CLI, pick project) is buried at positions 2 and 9 of 13.
- *First-run onboarding*: **Onboarding re-implements Settings instead of composing it, so two copies of every control drift** — Wording, grouping and correctness diverge; there is no single row that both a wizard and a settings pane can render, and no registry of settings from which either could be generated.
- *First-run onboarding*: **The persistence model cannot represent 'skipped', so re-entry is impossible without a reset** — The product promise printed on three pages is unfulfillable; a redesign that wants contextual 'set this up now?' moments has no data to drive them.
- *First-run onboarding*: **Provider matrices are rendered as pages** — Per-agent decisions leak into the global first-run path; adding a provider adds three cards automatically; two agent lists can disagree about what 'installed' means.
- *First-run onboarding*: **Feature-visibility decisions live inside step views, not in a capability/agent registry** — Each surface answers 'is this feature available / configured / optional' with its own code path; the answers already differ (Hermes hooks, capability groupings, default-grant sentence).
- *Global Settings window*: **Provider×setting matrix as the organising principle of the Agents category** — Every new provider adds ~7 rows across the window with zero code change, and per-agent asymmetries (login detection, modes, colours, wiring) show up as inconsistent rows rather than as a single agent page.
- *Global Settings window*: **No settings registry: panes are ad-hoc SwiftUI Forms, search and deep links are hand-maintained strings** — Search finds panes, not settings; adding a control requires manual keyword and test edits; scope (global/project/session/agent) is implicit in where a view happens to write.
- *Global Settings window*: **Category tree governed by a unit-test rule ('no category of one page') instead of a user model** — The 'Uncoil' category exists to satisfy the rule; any coherent regrouping must rewrite tests that encode the previous compromise.
- *Global Settings window*: **Two agent identities (AgentProvider vs ExtensionAgentID) with a partial bridge** — Different panes list different agents with different names; a unified 'my agents' surface is impossible without merging the types.
- *Global Settings window*: **Capability grants exist at three scopes with three different editors and one scope has no editor in Settings** — Users cannot reason about 'what may an agent do' from one place; the most important scope (defaults) is the least reachable.
- *Global Settings window*: **Storage and ownership scattered across nine locations with no scope model** — Backup, uninstall, reset and 'what did I change' are unanswerable; machine caches (resolvedBinaries) live beside user choices.
- *Global Settings window*: **Dead subsystems shipped in Core with no UI (Backup, Uninstall, CrashReporting) and persisted fields with no control (clickAction)** — Product surface and code surface have drifted; the restructuring plan must decide what is real.
- *Global Settings window*: **Settings does side-effectful work (launch sessions, restart terminals, run installers, reopen onboarding)** — Settings depends on ProjectStore, SessionStore, TerminalRegistry, MainRoute and process runners; it cannot be reasoned about as a preferences surface.
- *Extensions window*: **No capability registry: six independent capability tables decide what the UI shows** — PackageCard.actions (ExtensionsView.swift:1856-1958) consults source capabilities, state, kind, revision presence and ownership in nine separate conditionals; the picker consults extensionScoping; Settings consults wiresControlPlane; Installed Agents consults the ceiling table. Adding an agent or a source class means editing five files and re-deriving every view's conditionals; there is no single 'what can this agent/extension do' answer for a designer to reason about.
- *Extensions window*: **Feature-visibility logic is inline in views rather than declared** — Dead surfaces (EXT-02, EXT-03, EXT-05's card) persist because nothing central says 'this capability has no implementation'; views cannot tell built-ahead from live.
- *Extensions window*: **Store is instantiated per surface with whole-document last-save-wins persistence** — Cross-surface data loss; every new surface that needs the registry has to choose an instance and risks the same bug.
- *Extensions window*: **Two agent identities and two integration vocabularies (adapter capabilities vs integration level) describe the same eight CLIs** — Rosters and names differ per screen (7 vs 8 agents; 'Claude' vs 'Claude Code'); the 'not managed yet' distinction collapsed but its UI remained.
- *Extensions window*: **About 40% of App/Extensions by line count is built-ahead engine code with no production caller, yet its nouns are first-class in the UI** — The window's information architecture (Sources, Updates, secret hints, health rows, logs/restart) is shaped by code that users cannot trigger. The acceptance suite passes while the product surface it validates is not reachable.
- *Extensions window*: **Per-project scope is the one coherent model in this area and is the smallest surface** — 'Everything on until you turn it off, applied at launch' is a mental model a user can hold. It is undermined only by its third writer (Assignments), the shared-instance hazard and the Quick Launch coupling — all fixable without touching the model.
- *Agent/provider abstraction*: **Capability facts live in three unconnected layers that reference each other only in comments** — There is no object a designer can query for 'what can Uncoil do with agent X'; every screen assembles its own answer, and the answers already disagree (AP-03).
- *Agent/provider abstraction*: **Two identity enums with different display names and member sets are both user-facing** — Users see 7, 8-with-Amp or 8-with-Terminal agents depending on the screen, and two names for the same product.
- *Agent/provider abstraction*: **Per-provider settings are rendered as matrices on five pages instead of one per-agent surface** — Every provider-level fact becomes N rows across M pages; every new provider multiplies both. The agent — the thing the user reasons about — never has a home.
- *Agent/provider abstraction*: **Feature visibility is decided inside views by comparing enum cases** — No single place to see or change what an agent's UI can show; a registry cannot be introduced without rewriting these sites.
- *Agent/provider abstraction*: **Claude Code is the implicit baseline: its vocabulary is Uncoil's vocabulary** — Other agents are always 'less than Claude' in UI copy ('Codex has no hook system…'), and integrating a second hook-capable agent required a parallel installer and a translation table rather than a second implementation of one interface.
- *Agent/provider abstraction*: **Codex has a shadow runtime behind a launch flag that shapes shared types** — Shared session/notification/terminal code names one vendor; the feature is invisible to users yet constrains the model.
- *Status, attention, notifications and the*: **No single 'signal' model; every surface derives 'needs you' from a different enum** — Adding one condition means touching four enums, seven switches in AttentionKind, the menu-bar counters, the notification bridge filter and the settings pages — the growth pattern visible in CHANGELOG 0.1.0 lines 162-166, 177, 186, 208 and the 0.2.0 fix at line 142.
- *Status, attention, notifications and the*: **Two notification pipelines with different rules** — Settings describe one behaviour; roughly half of the permission-class banners obey it.
- *Status, attention, notifications and the*: **Visibility and routing logic lives in views and singletons rather than a registry** — There is no place to ask 'which signals exist, who raises them, where do they show, and what can the user configure' — which is exactly what the dead clickAction, the unshown suppression labels and the unreachable taskCompleted/mergeReady banners demonstrate.
- *Status, attention, notifications and the*: **Settings model is a three-level inheritance matrix over two axes (event, project) for two attributes (priority, sound), plus event-scoped reminders toggled in two panes** — Predicting one banner's loudness requires reading three panes; the matrix is the main driver of the ~60-control count.
- *Status, attention, notifications and the*: **Provider asymmetry is baked into the state machine rather than adapted at the edge** — Every status/attention/notification surface behaves differently per provider, and each new provider (Gemini, Cursor, etc. listed in AgentsSettings keywords) will add another variant unless the adapters converge.
- *MCP control plane as it surfaces in the *: **There is no capability registry; six artefacts must agree by hand** — Every new tool or grant touches at least five files and two docs; the runtime keys already diverged from the catalog (CP-02) and the docs from the code (CP-14). Feature-visibility rules (which group, which pane, risky or not, banner-decidable or not) live in views instead of data.
- *MCP control plane as it surfaces in the *: **Setup, policy and enforcement for one feature are split across unrelated surfaces** — The user has to know that 'Drivers', 'Permissions', 'Optional tools' and 'Installed Agents › Control plane' are four views of the same feature; the code has to keep four sets of strings and ids in sync and already failed to.
- *MCP control plane as it surfaces in the *: **Three trust layers with three UIs: CLI working mode, Uncoil MCP grants, and the CLI's own approvals reflected back** — The product cannot state a single trust level for a session. Onboarding even attributes the grant-intersection property to working modes (OnboardingToolSteps.swift:30).
- *MCP control plane as it surfaces in the *: **SessionPreset is a launch template, a capability ceiling and a prompt at once, consumed with different semantics in four places** — A 'preset' means enforcement in one flow and advice in another; the same object is called preset, profile and permission bounds. Blueprints (stored prompts) and Run Parameters (per-provider flags) overlap with two of its fields.
- *MCP control plane as it surfaces in the *: **The Permissions pane is coupled to the control-plane service although most of its state is not** — Availability of an everyday policy surface depends on a socket server; UI-test launches without -control-plane cannot show it at all.
- *Command palette, quick actions, keyboard*: **Four independent command-dispatch channels, none aware of the others** — There is no capability/command registry; enablement rules live inline in PaletteEngine.commandItems, in each view's conditionals and in each menu builder. Shortcut metadata cannot be attached to an action, so palette rows show no shortcuts and menus cannot be derived. Every new feature will be added to a subset of surfaces.
- *Command palette, quick actions, keyboard*: **Three overlapping NSEvent local key monitors with implicit precedence** — Keyboard routing is not centralised; which monitor wins for a given chord depends on installation order and first-responder type. Adding any new global shortcut that must work over the terminal means a fourth monitor, since SwiftUI .keyboardShortcut is swallowed by SwiftTerm (CommandPalette.swift:230-233).
- *Command palette, quick actions, keyboard*: **The palette is both the command surface and the search surface for six object kinds, with per-kind visibility rules embedded in one compute() function** — The empty palette is a command list, the typed palette is a global search, and two prefixes turn it into a chat launcher or a task inbox — four products behind one text field, with visibility logic that must be re-read to predict what Enter will do.
- *Command palette, quick actions, keyboard*: **Provider matrices leak into the palette and the keyboard settings** — Every additional agent multiplies palette rows and settings toggles; the same 'which agents count' question is answered differently per surface.
- *Command palette, quick actions, keyboard*: **Keyboard shortcut inventory (complete)** — Everything else — new session, session switching, focus moves, project/tasks/run/tests areas, attention, interrupt, restart, split, popout, Settings pane navigation, Extensions search, New Window overlay choice — has no keyboard path other than ⌘K plus typing.
- *Product intentions and pending plans*: **Feature-accumulation timeline (surfaces and settings per release, from CHANGELOG.md)** — Roughly 25 surfaces or settings pages added across two releases, one removed. Growth is by adjacency (a new page beside the nearest existing page) rather than by model; nothing in the docs records a surface budget.
- *Product intentions and pending plans*: **Pending plans and where each would land if built as written** — Every open item adds or relocates a surface; three of them (N.2, N.5, N.4) are explicitly rewrites, which is the window in which a registry-driven structure could replace per-feature placement.
- *Product intentions and pending plans*: **Vocabulary drift across plan → docs → UI (same thing, different names)** — There is no label source of truth; docs, onboarding copy, Settings titles and the plan each coin their own. A restructuring plan should name each concept once and map every alias to it.
- *Product intentions and pending plans*: **Intentions already recorded that agree with simplification (quote these in the plan)** — The team has repeatedly reached for 'one list', 'one place', 'derive from the enum', 'hide what does not exist' — but each time for one surface. The restructuring plan can present a registry as the generalisation of decisions already taken, not a new philosophy.
- *Product intentions and pending plans*: **No capability registry: 'what can this agent/session/project do' is answered in at least six unrelated places** — Visibility decisions ('show Connect', 'show Hibernate', 'offer this driver', 'list this agent', 'show this pane') are each computed locally from a different source. Adding an agent or a grant touches all of them; the CHANGELOG's own 'three lists of install paths' bug (CHANGELOG.md:67) is the pattern repeating.


---

## Application shell, navigation and routing (App/UncoilApp.swift, App/UI/MainWindow.swift, App/Core/WindowRegistry.swift, App/Core/WindowLayout.swift, App/UI/SessionPopoutWindow.swift, App/UI/TitlebarControls.swift, App/UI/WindowOverlays.swift, App/UI/PopoutDrag.swift, App/Core/LaunchConfig.swift, App/Core/ApplicationLifecycle.swift, App/Core/MenuBarMonitor.swift). All paths below are relative to the repo root /Volumes/SN770 1TB M2 SSD/Developer/Projects/uncoil.

From the user's chair, Uncoil is a titleless main window with a sidebar of projects → groups → sessions on the left and one of three pages on the right (a project dashboard with up to five tabs, a group page, or a session terminal that can be split with a second session). Everything else lives somewhere other than that window: Settings is its own window with 24 panes in 6 categories; Extensions is its own window with 11 sections and the only full top-level menu in the app; a session can be popped out into its own terminal-only window; a menu-bar extra offers its own launcher, interrupt and task controls; first-run setup (13 steps) covers the main window as an overlay; ⌘N covers a fresh window with a "what should this window open on?" question; the command palette (⌘K, installed as a raw NSEvent monitor) is the sole route to about a dozen actions. Under the hood there is no navigation model: MainSelection has three cases (project/group/session) and everything outside those three cases is reached through one of six independent singleton "route" buses (MainRoute, SettingsRoute, ExtensionsCommandBus, ProjectAreaRoute, HandoffRoute, OnboardingPresenter), hard-coded SwiftUI window-id strings ("main", "settings", "extensions", "session-window") at 12 call sites, or the UI-test LaunchConfig route that is read inside production views. MainWindow is also the app's composition root: its onAppear starts the hook server, the MCP control plane, the extension secret server, Bumblebee scans, attention polling, CLI update checks and the palette hotkey monitor, and it owns the multi-window identity/ownership bookkeeping, three alerts, two sheets and a folder picker in one 1197-line view. Multi-window (per-window project scope, exclusive session ownership, clone-or-empty question) is the shell's most prominent abstraction and its vocabulary leaks into everyday UI ("This session is open in another window", "No projects in this window", "Clone Main Window").

### Findings

#### [CRITICAL] SHELL-01 — MainWindow is the app's composition root: a SwiftUI view starts three servers, two background loops and the update check

*Category:* coupling

- `App/UI/MainWindow.swift:315` — startServices()
- `App/UI/MainWindow.swift:823` — sessionStore.startHookServer(
- `App/UI/MainWindow.swift:998` — let server = ControlPlaneServer(
- `App/UI/MainWindow.swift:1021` — let server = ExtensionSecretServer(
- `App/UI/MainWindow.swift:150` — let scans = BumblebeeScanCoordinator(registry: ExtensionRegistry())
- `App/UI/MainWindow.swift:166` — await AttentionRefresher.shared.scanTasks(projectStore: projectStore)
- `App/UI/MainWindow.swift:893` — await settings.checkCLIUpdates()
- `App/UI/MainWindow.swift:861` — RuntimeClient.shared.onAliveSessions = { [weak sessionStore, weak projectStore] alive in

**Why it matters:** Every feature that needs app-lifetime wiring (hooks, MCP, secrets, security scans, attention, permissions notifications, child-session launcher) has been bolted onto the main window's onAppear, so the shell view grows with every feature and cannot be reasoned about as navigation. Because the block runs per MainWindow instance and only three of its effects are guarded, opening a second window (⌘N) re-runs pruneDroppedImages, resolveBinaries, checkCLIUpdates and reassigns RuntimeClient.onAliveSessions (lines 861, 886-894).

**Direction:** Move service start-up into an app-level bootstrapper owned by UncoilApp/AppDelegate; leave MainWindow with selection + layout only.

#### [CRITICAL] SHELL-02 — No navigation model: three MainSelection cases plus six independent singleton route buses, string window ids and a test-only launch route

*Category:* navigation

- `App/UI/MainWindow.swift:3` — enum MainSelection: Hashable {
- `App/UI/MenuBarMonitorView.swift:6` — final class MainRoute: ObservableObject {
- `App/UI/Settings/SettingsView.swift:5` — final class SettingsRoute: ObservableObject {
- `App/UI/ExtensionsCommands.swift:10` — final class ExtensionsCommandBus: ObservableObject {
- `App/Core/ProjectPageStore.swift:165` — final class ProjectAreaRoute: ObservableObject {
- `App/Usage/HandoffService.swift:9` — final class HandoffRoute: ObservableObject {
- `App/Core/OnboardingPresenter.swift:10` — final class OnboardingPresenter: ObservableObject {
- `App/UI/MainWindow.swift:1182` — .onReceive(MainRoute.shared.$requestCounter) { _ in
- `App/UI/ProjectDashboardView.swift:86` — for requested in [
- `App/UI/MainWindow.swift:663` — if config.route == "extensions" {

**Why it matters:** Each destination outside project/group/session got its own wire: a settings pane is a String on SettingsRoute, an Extensions section is an enum on ExtensionsCommandBus, a project tab is a String in a per-project dictionary on ProjectAreaRoute, a handoff sheet is a UUID on HandoffRoute, onboarding is a Bool on OnboardingPresenter, and cross-window session focus is MainSelection + a counter on MainRoute (defined inside the menu-bar view file). None of them compose ('open project X on the Run tab in the Extensions-configured window' needs two buses and a window id). New features will keep adding a seventh and eighth bus; nothing can enumerate 'where can the user go'.

**Direction:** One Route/Destination enum (window × page × sub-page) with one dispatcher; buses become cases.

#### [HIGH] SHELL-03 — Destinations are hard-coded string window ids at 12 call sites, matched by substring and by window title elsewhere

*Category:* navigation

- `App/UncoilApp.swift:205` — openWindow(id: "settings")
- `App/UI/SidebarView.swift:154` — openWindow(id: "settings")
- `App/UI/MainWindow.swift:411` — openWindow(id: "settings")
- `App/UI/MainWindow.swift:670` — openWindow(id: "extensions")
- `App/UI/ExtensionsCommands.swift:62` — openWindow(id: "extensions")
- `App/UI/Settings/AboutSettingsPage.swift:83` — openWindow(id: "main")
- `App/UI/MenuBarMonitorView.swift:197` — openWindow(id: "main")
- `App/UI/CommandPalette.swift:291` — return identifier.contains("settings") || identifier.contains("session-window")
- `App/Core/ApplicationLifecycle.swift:53` — .first { $0.title == "Uncoil" || $0.identifier?.rawValue == "main" }
- `App/Core/ApplicationLifecycle.swift:70` — if item.keyEquivalent.lowercased() == "n",

**Why it matters:** Which windows exist and how to reach them is knowledge duplicated across the app, sidebar, palette, menu bar, settings pages and the app delegate (which reopens the app by walking the main menu for a ⌘N item). Renaming or merging a window (e.g. folding Extensions into the main window) touches every site.

**Direction:** A single WindowKind enum + one `open(_:)` API; the reopen path should call it instead of introspecting NSMenu.

#### [HIGH] SHELL-04 — A user can be in at least 14 distinct places across 5 window kinds, 3 full-window overlays, 1 popover and system notifications

*Category:* concept-overload

- `App/UncoilApp.swift:67` — WindowGroup(id: "main") {
- `App/UncoilApp.swift:91` — WindowGroup("Session", id: "session-window", for: UUID.self) { $sessionID in
- `App/UncoilApp.swift:104` — Window("Uncoil Settings", id: "settings") {
- `App/UncoilApp.swift:122` — Window("Uncoil Extensions", id: "extensions") {
- `App/UncoilApp.swift:139` — MenuBarExtra(isInserted: menuBarInserted) {
- `App/UI/MainWindow.swift:65` — ZStack {
- `App/UI/AttentionCenterView.swift:218` — .popover(isPresented: $showPanel, arrowEdge: .top) {
- `App/UI/Settings/SettingsView.swift:68` — enum Pane: String, CaseIterable, Identifiable {
- `App/UI/ExtensionsView.swift:5` — enum Section: String, CaseIterable, Identifiable {

**Why it matters:** Main window (project page with up to 5 tabs / group / session / split / empty / session-elsewhere), palette overlay (with ask and capture modes), onboarding overlay (13 steps), new-window overlay, popout window, Settings window (24 panes), Extensions window (11 sections), menu-bar menu, Attention popover, and system notification banners with actions. The main window's own navigation covers only 3 of these; the two densest surfaces (24 panes, 11 sections) sit in separate windows with separate chrome (Settings is not ThemedWindow, popout forces .dark, Extensions has its own frame restorer).

**Direction:** Decide which of these are pages of one window and which are truly windows; today the split is historical, not designed.

#### [HIGH] SHELL-05 — Multi-window ownership vocabulary leaks into everyday UI and ⌘N opens a question instead of a window

*Category:* agent-leak

- `App/UI/WindowOverlays.swift:21` — Text("What should this window open on?")
- `App/Core/WindowLayout.swift:192` — ? String(localized: "Clone Main Window")
- `App/UI/WindowOverlays.swift:79` — Text("“\(sessionTitle)” is running in “\(windowTitle)”. A session can only be shown in one window at a time.")
- `App/UI/SidebarView.swift:56` — Text(projectStore.projects.isEmpty ? "No projects yet" : "No projects in this window")
- `App/UI/MainWindow.swift:756` — if case .heldElsewhere = windows.claim(id, by: windowID), id == splitSessionID {
- `App/Core/WindowRegistry.swift:119` — case .asks:

**Why it matters:** Per-window project scope, exclusive session ownership, 'main window' as oldest window, clone vs empty — these are implementation constraints of mounting one NSView (WindowRegistry.swift:137-143 explains it) presented to the user as a workspace concept. The concept only exists on the ⌘N path; sidebar visibility and width remain global (@AppStorage in 4 files), so windows are half-independent and the mental model is neither 'one app' nor 'workspaces'.

**Direction:** Either make windows plain (share everything, ⌘N just opens) or make workspaces a first-class, named, saved concept; remove the modal question.

#### [HIGH] SHELL-06 — Sidebar Attention Center bypasses the window-scope routing that every other entry uses

*Category:* visibility-logic

- `App/UI/SidebarView.swift:165` — AttentionRailButton { item in
- `App/UI/SidebarView.swift:168` — selection = .session(sessionID)
- `App/Core/WindowRegistry.swift:184` — /// Opening a project in a window puts it in that window. Every route into
- `App/UI/MainWindow.swift:1191` — onRoute(requested)
- `App/UI/MainWindow.swift:584` — } else if let record = projectStore.sessions.first(where: { $0.id == id }),

**Why it matters:** The registry's own comment says every route into a project goes through open(project:in:), but the sidebar bell sets selection directly. routedDetail resolves the session from the global store without checking scope, so in a scoped window an attention click opens a session whose project has no row in the sidebar (inferred). Two routes to the same destination with different side effects is the pattern that compounds.

**Direction:** Route the bell through the same dispatcher as MainRoute.

#### [HIGH] SHELL-07 — The command palette is the only route to a dozen actions, and one of them ('Create Worktree…') is a no-op destination

*Category:* discoverability

- `App/Core/PaletteModel.swift:324` — PaletteItem(id: "cmd.testWorkspace", title: String(localized: "Create a Test Workspace"),
- `App/Core/PaletteModel.swift:352` — title: String(localized: "Create Worktree… [\(project.name)]"),
- `App/UI/MainWindow.swift:405` — case .createWorktree(let projectID):
- `App/UI/MainWindow.swift:406` — selection = .project(projectID)
- `App/Core/PaletteModel.swift:365` — items.append(PaletteItem(id: "cmd.restart", title: String(localized: "Restart the Session"),
- `App/Core/PaletteModel.swift:304` — id: "cmd.ask", title: String(localized: "Ask an agent…"),
- `App/UncoilApp.swift:209` — CommandGroup(replacing: .newItem) {
- `App/UI/CommandPalette.swift:261` — NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak settings] event in

**Why it matters:** Ask an agent, Capture a Task, one-off session, Test Workspace, Debug Bundle, Create Worktree, Apply Blueprint, Restart/Close/Popout, and all 24 Settings panes are palette-only or palette-first, while the main menu's File menu contains a single item. The palette hotkey is an NSEvent monitor, not a menu shortcut, so it is invisible in the menu bar. 'Create Worktree…' merely selects the project (the form is a text field on the General tab, ProjectDashboardView.swift:281).

**Direction:** Make the menu bar the authoritative command list (Project/Session menus) and derive palette commands from it.

#### [MEDIUM] SHELL-08 — Developer and support tooling is first-class shell state and sits beside 'Add a New Project'

*Category:* agent-leak

- `App/UI/MainWindow.swift:31` — @State private var testWorkspaceError: String?
- `App/UI/MainWindow.swift:32` — @State private var debugBundleMessage: String?
- `App/UI/MainWindow.swift:34` — @State private var runtimeCompatibilityError: String?
- `App/UI/MainWindow.swift:127` — "Runtime Mismatch",
- `App/Core/PaletteModel.swift:326` — PaletteItem(id: "cmd.debugBundle", title: String(localized: "Create Debug Bundle"),
- `App/UI/Settings/AboutSettingsPage.swift:94` — Button("Create") { createDebugBundle() }

**Why it matters:** Three of the shell's alerts exist for acceptance/support tooling; 'Create a Test Workspace' is listed between 'Add a New Project' and 'Extensions' for every user; Debug Bundle is implemented twice (palette + About page) with two result presentations.

**Direction:** Move to a Help/Support menu or About page only; keep the shell free of tool-specific alerts.

#### [MEDIUM] SHELL-09 — Session lifecycle actions (restart/close) are reimplemented at four sites, one of them in the shell

*Category:* duplicate-concept

- `App/UI/MainWindow.swift:412` — case .restartSession(let id):
- `App/UI/MainWindow.swift:416` — case .closeSession(let id):
- `App/UI/SessionDetailView.swift:172` — TerminalRegistry.shared.closeTerminal(for: record.id)
- `App/UI/SessionGroupView.swift:266` — TerminalRegistry.shared.closeTerminal(for: id)
- `App/UI/SidebarView.swift:245` — TerminalRegistry.shared.closeTerminal(for: record.id)

**Why it matters:** MainWindow.perform contains the business rule for restarting/closing a session (closeTerminal + bump lastActivityAt + bumpRestart / setStatus(.terminated) + markSessionEnded) alongside SessionDetailView, SessionGroupView and SidebarView copies. Feature logic living in the shell's palette switch is how the switch grows to 21 cases.

**Direction:** One SessionActions service; the palette and views call it.

#### [MEDIUM] SHELL-10 — Three different names for two window concepts: 'Open in a Popout Window', 'Open in a New Window', 'New Uncoil Window'

*Category:* terminology

- `App/Core/PaletteModel.swift:371` — items.append(PaletteItem(id: "cmd.popout", title: String(localized: "Open in a Popout Window"),
- `App/UI/AppKit/SidebarOutline.swift:815` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/UncoilApp.swift:210` — Button("New Uncoil Window") {
- `App/Core/WindowRegistry.swift:297` — return String(localized: "\(title) (popped out)")

**Why it matters:** 'New Window' in the context menu creates a terminal-only popout; 'New Uncoil Window' in the File menu creates a full window that then asks a question; the registry names popouts '(popped out)'. Users cannot predict which they will get.

**Direction:** One name per window kind, used everywhere.

#### [MEDIUM] SHELL-11 — The main menu is nearly empty except for Extensions, which is the only feature with a full top-level menu and two global shortcuts

*Category:* navigation

- `App/UncoilApp.swift:81` — CommandGroup(after: .toolbar) {
- `App/UncoilApp.swift:195` — CommandGroup(after: .appInfo) {
- `App/UncoilApp.swift:203` — CommandGroup(replacing: .appSettings) {
- `App/UncoilApp.swift:209` — CommandGroup(replacing: .newItem) {
- `App/UI/ExtensionsCommands.swift:41` — CommandMenu("Extensions") {
- `App/UI/ExtensionsCommands.swift:47` — ForEach(ExtensionsView.Section.allCases) { section in
- `App/UI/ExtensionsCommands.swift:54` — .keyboardShortcut("r", modifiers: [.command, .shift])

**Why it matters:** Menu inventory: App (Check for Updates, Settings), File (New Uncoil Window), View (Hide Sidebar), Extensions (Open + 11 sections + Rescan + Health Check + Bumblebee Scan). There is no Project or Session menu, no menu item for the palette, no Window-menu awareness of popouts. The advanced surface outranks the everyday workflow in the one place Mac users look for commands.

**Direction:** Menus should mirror the primary objects (Project, Session) first; Extensions items belong under a Tools/Extensions submenu.

#### [MEDIUM] SHELL-12 — UI-test launch routing is a parallel navigation system read inside production views

*Category:* coupling

- `App/Core/LaunchConfig.swift:101` — route = Self.value(after: "-route", in: arguments)
- `App/Core/LaunchConfig.swift:106` — projectArea = Self.value(after: "-project-area", in: arguments)
- `App/UI/MainWindow.swift:677` — if config.route == "session",
- `App/UI/ProjectDashboardView.swift:87` — LaunchConfig.shared.projectArea,
- `App/UI/ExtensionsView.swift:153` — if let action = LaunchConfig.shared.extensionsAction
- `App/UI/UsageChip.swift:195` — guard LaunchConfig.shared.usageFixture, UsageCardAutoOpen.claim() else { return }
- `App/UI/MainWindow.swift:141` — if LaunchConfig.shared.runtimeMismatchFixture {

**Why it matters:** 22 launch flags; -route/-project-area/-extensions-*/-onboarding-step are not gated by isUITesting (LaunchConfig.swift:100-106, 111), so they are a de-facto deep-link scheme with string-typed destinations that must be kept in sync by hand with MainSelection, ProjectArea, ExtensionsView.Section and OnboardingStep. Views that should be pure consumers of a route also consult the process arguments.

**Direction:** Parse launch args into the same Destination type as SHELL-02 once, at startup.

#### [MEDIUM] SHELL-13 — Onboarding is a 13-step full-window overlay owned by a global singleton, with a permanent sidebar nag and a re-entry from Settings that must know where the flow lives

*Category:* onboarding

- `App/Core/OnboardingState.swift:10` — case welcome
- `App/Core/OnboardingState.swift:21` — case palette
- `App/UI/MainWindow.swift:73` — OnboardingView()
- `App/UI/Onboarding/OnboardingView.swift:133` — Text("Finish setup")
- `App/UI/Settings/AboutSettingsPage.swift:75` — detail: String(localized: "Runs the first-run flow again: CLIs, accounts, hooks, agent capabilities, tasks and extensions.")
- `App/UI/Settings/AboutSettingsPage.swift:81` — // The flow lives in the main window; Settings is its

**Why it matters:** Steps Working modes, Status tracking, Agent capabilities, Optional tools, Tasks, Extensions and Command palette are configuration steps mirrored by Settings panes — the shell hosts a second settings UI as a modal. CLAUDE.md lists 9 steps; the code has 13 (drift). OnboardingPresenter.isPresenting is global, so every main window shows the overlay.

**Direction:** Keep first-run to the irreducible (CLI + one project); the rest are offers inside the pages they configure.

#### [MEDIUM] SHELL-14 — The menu-bar extra is a second control surface with its own launcher, interrupt and orchestrator controls, each behind its own preference

*Category:* duplicate-concept

- `App/UI/MenuBarMonitorView.swift:110` — Menu("New Session") {
- `App/UI/MenuBarMonitorView.swift:113` — ForEach(AgentProvider.sessionKinds) { provider in
- `App/UI/MenuBarMonitorView.swift:136` — Menu("Task Board") {
- `App/UI/MenuBarMonitorView.swift:153` — Menu("Stop the Orchestrator") {
- `App/Core/MenuBarPrefs.swift:101` — var showTasksSection = true
- `App/UI/SidebarView.swift:708` — ForEach(settings.launcherProviders) { provider in

**Why it matters:** The menu bar's New Session ignores the user's launcher configuration (uses all sessionKinds) while the sidebar strip, palette and context menu honour it; 'Task Board' routes to the project page, not the Tasks tab; 'Stop the Orchestrator' is an advanced action exposed one click from the menu bar. Nine prefs configure this one surface.

**Direction:** Derive the menu bar from the same command registry and launcher list as the main window.

#### [MEDIUM] SHELL-15 — Shell chrome is split across three places (titlebar accessory, sidebar rail, sidebar resume row) plus per-row hover controls

*Category:* settings-sprawl

- `App/UI/TitlebarControls.swift:15` — struct TitlebarControls: NSViewRepresentable {
- `App/UI/SidebarView.swift:147` — HStack(spacing: 2) {
- `App/UI/SidebarView.swift:145` — OnboardingResumeRow()
- `App/UI/SessionDetailView.swift:249` — Text("Hover a project, pick an agent")

**Why it matters:** Sidebar toggle + palette live in an NSTitlebarAccessoryViewController; Settings (with CLI-update badge), Add, Attention bell, multi-select and Collapse All live in a bottom rail; 'Finish setup' floats above it; launching an agent is a hover-only strip the empty state has to explain. The rail mixes navigation (Settings), creation (+), notification (bell) and list mode (multi-select, collapse).

**Direction:** One toolbar with a consistent grouping; hover-only primary actions get a visible equivalent.

#### [LOW] SHELL-16 — MainWindow holds 19 state properties, 3 alerts, 2 sheets, a folder picker and 3 long-running .task loops

*Category:* other

- `App/UI/MainWindow.swift:15` — @StateObject private var palette = PaletteModel()
- `App/UI/MainWindow.swift:43` — @State private var newWindowOptions: [NewWindowOption]?
- `App/UI/MainWindow.swift:48` — // Split in two on purpose: as one chain this stopped type-checking in
- `App/UI/MainWindow.swift:1156` — private struct MainWindowSignals: ViewModifier {

**Why it matters:** palette, onboarding, selection, selectedSessionIDs, splitSessionID, showFolderPicker, configuringNewProject, blueprintProject, extensionRegistry, testWorkspaceError, debugBundleMessage, debugBundleURL, runtimeCompatibilityError, sidebarVisible, sidebarWidth, dragStartWidth, windows, windowID, newWindowOptions. The body had to be split because the type checker gave up — a direct measure of how many unrelated responsibilities the shell view carries.

**Direction:** Extract: WindowSession (identity/ownership), ShellPresentation (overlays/sheets/alerts), and feature-owned sheets.

#### [LOW] SHELL-17 — Dead or duplicated shell configuration: MenuBarPrefs.clickAction is persisted but never read; sessionQuitBehavior is stored twice; WindowRegistry.forget(project:) has no callers

*Category:* settings-sprawl

- `App/Core/MenuBarPrefs.swift:98` — var clickAction: ClickAction = .openMenu
- `App/Core/MenuBarPrefs.swift:163` — clickAction = try container.decodeIfPresent(ClickAction.self, forKey: .clickAction)
- `App/Core/ApplicationLifecycle.swift:8` — var sessionQuitBehavior: SessionQuitBehavior = .keepSessionsRunning
- `App/Core/SettingsStore.swift:309` — ApplicationLifecycle.shared.sessionQuitBehavior = behavior
- `App/Core/WindowRegistry.swift:193` — func forget(project: UUID) {

**Why it matters:** grep for clickAction outside MenuBarPrefs.swift returns nothing, so 'What a left click on the icon does → Open the Uncoil window' is a setting with no effect; the quit behaviour is mirrored by hand into a second singleton; forget(project:) is dead. Small, but each is a config point a designer would otherwise count as real.

**Direction:** Delete or wire; keep one owner per setting.

#### [LOW] SHELL-18 — Window frame persistence is keyed by open-order slot and defends against a status-item window that once wrote a 32x30 frame

*Category:* visibility-logic

- `App/UI/MainWindow.swift:1062` — /// Position in the open order. Frames are saved per slot rather than per
- `App/UI/MainWindow.swift:1111` — Self.forgetImplausibleFrame(key: "NSWindow Frame \(autosaveName)")
- `App/UncoilApp.swift:62` — try? FileManager.default.removeItem(at: savedState)

**Why it matters:** The shell owns three layers of window-position workarounds (slot-keyed autosave, implausible-frame purge, deleting AppKit saved state on every launch). They are symptoms of the app fighting the platform's window model rather than adopting one; any change to window kinds has to revisit all three.

**Direction:** Record as constraints for whichever window model the redesign picks.

#### [LOW] SHELL-19 — docs/current/STATUS.md describes a Settings structure that no longer exists

*Category:* terminology

- `docs/current/STATUS.md:75` — **General** (default agent, editor, quit behaviour, interface and agent language, command-palette shortcut) · **Agents** (Accounts / CLI Tools / Parameters / Mode and Keyboard / Session Presets) · **Notifications** (Gene
- `App/UI/Settings/SettingsView.swift:42` — enum Category: String, CaseIterable, Identifiable {

**Why it matters:** The code has 6 categories / 24 panes; the status doc lists 8 categories with different pane names. Anyone planning from the docs will plan against the wrong map.

**Direction:** Regenerate the map from the Pane enum when the restructure lands.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Main window (WindowGroup "main") | window | `App/UncoilApp.swift` | app launch; ⌘N "New Uncoil Window" (UncoilApp.swift:210); Dock click with no windows → ApplicationLifecycle walks the main menu for the ⌘N item (ApplicationLifecycle.swift:56-63); menu bar "Open Uncoi |
| MainWindow detail column (routedDetail) | screen | `App/UI/MainWindow.swift` | sidebar row click; palette openProject/focusSession; MainRoute request; launch route -route session/project |
| EmptyDetailView | empty-state | `App/UI/SessionDetailView.swift` | selection == nil; selection points at a removed project/group/session |
| Sidebar (SidebarView + SidebarOutline) | panel | `App/UI/SidebarView.swift` | always visible unless sidebarVisible=false (⌘B, titlebar toggle, drag below 120pt) |
| Titlebar controls (TitlebarControls → WindowControlsCluster) | toolbar | `App/UI/TitlebarControls.swift` | always, main windows only |
| Command palette overlay | panel | `App/UI/CommandPalette.swift` | ⌘K via NSEvent local monitor (CommandPalette.swift:258-283), configurable in Settings > General; titlebar search button |
| Onboarding overlay | screen | `App/UI/Onboarding/OnboardingView.swift` | first launch / version bump: settings.shouldPresentOnboarding (MainWindow.swift:656); sidebar "Finish setup" row (OnboardingView.swift:126); Settings > About > "Run again" (AboutSettingsPage.swift:78- |
| New Window overlay | screen | `App/UI/WindowOverlays.swift` | ⌘N while ≥1 window is open |
| SessionElsewhereView | screen | `App/UI/WindowOverlays.swift` | selecting a session another window holds |
| Session popout window (WindowGroup "session-window") | window | `App/UI/SessionPopoutWindow.swift` | sidebar context menu "Open in a New Window" (SidebarOutline.swift:815); drag a session row outside the window (SidebarOutline.swift:649-667); palette "Open in a Popout Window" (MainWindow.swift:420-42 |
| Settings window (Window "settings") | window | `App/UI/Settings/SettingsView.swift` | ⌘, / app menu "Settings…" (UncoilApp.swift:203-208); sidebar gear (SidebarView.swift:154); palette "Settings" and "Settings: <pane>" via SettingsRoute (MainWindow.swift:409-411); MCP pane "Capabilitie |
| Extensions window (Window "extensions") | window | `App/UI/ExtensionsView.swift` | Extensions menu ⇧⌘E and one item per section (ExtensionsCommands.swift:41-57); palette "Extensions" (MainWindow.swift:393-394); -route extensions (MainWindow.swift:663-671) |
| Menu bar extra (MenuBarExtra + MenuBarMonitorMenu) | menu | `App/UI/MenuBarMonitorView.swift` | always in the menu bar when settings.menuBar.isVisible(for: summary) (UncoilApp.swift:159-164) |
| Attention Center popover | popover | `App/UI/AttentionCenterView.swift` | sidebar bell (AttentionRailButton); the same items are also listed in the menu bar (MenuBarMonitorView.swift:81-88) |
| Main menu bar | menu | `App/UncoilApp.swift` | menu bar |
| Shell alerts | sheet | `App/UI/MainWindow.swift` | palette createTestWorkspace / createDebugBundle; RuntimeClient posting .runtimeCompatibilityError |
| Shell sheets | sheet | `App/UI/MainWindow.swift` | folder picker completion (deferred one turn, 293); palette applyBlueprint (407-408) |

### Concepts

- `U` **Project / Group / Session (MainSelection)** — The only three destinations the main window's own navigation knows: `enum MainSelection { project(UUID), group(UUID), session(UUID) }` (MainWindow.swift:3-7). Persisted per window as two strings kind/id (WindowLayout.swift:85-103). *Overlaps:* Project areas (a 4th level not represented in MainSelection), Scratch workspace (a project that is not one)
- `U` **Project area (General/Tasks/Run/Tests/Issues)** — Tabs inside ProjectDashboardView, shown only when the project has the backing facts (ProjectAreaAvailability.swift:87-96). Not part of MainSelection; addressed by a separate ProjectAreaRoute bus and the -project-area launch arg (ProjectDashboardView.swift:86-93). *Overlaps:* MainSelection
- `U` **Window identity / WindowProjects scope** — Each main window gets a UUID, its own selection, and a project scope `.all` or `.some(Set<UUID>)` (WindowLayout.swift:41-77, WindowRegistry.swift:100-124). Internal concept that surfaces as 'No projects in this window', 'Open one you already have', 'Clone Main Window', 'New Empty Window'. *Overlaps:* Popout window (kept out of `order`, different rules)
- `U` **Session ownership (holder / claim / take / release)** — Exclusive rule that a terminal NSView can be mounted in exactly one window; every navigation syncs an ownership map (MainWindow.swift:743-771, WindowRegistry.swift:210-237). Surfaces as SessionElsewhereView and silently cancels a split (MainWindow.swift:756-761). *Overlaps:* Popout
- `U!` **Popout window** — A terminal-only window for one session, sharing the PTY (SessionPopoutWindow.swift:4-7). Called 'Open in a Popout Window' in the palette (PaletteModel.swift:371) and 'Open in a New Window' in the sidebar context menu (SidebarOutline.swift:815); also created by dragging a row out of the window. *Overlaps:* 'New Uncoil Window' (⌘N) which is a different thing, Split pane
- `U` **Split pane** — A second session shown beside the selected one, created only by dropping a session row onto the terminal (SessionDetailView.swift:105-115); stored as `splitSessionID` in MainWindow (line 20) and not persisted. *Overlaps:* Popout
- `U` **Command palette (PaletteAction)** — 21-case action enum (PaletteModel.swift:8-33) resolved in MainWindow.perform. It is the only route to: Create a Test Workspace, Create Debug Bundle, Create Worktree…, Restart/Close the Session, Open in a Popout Window (also context menu), Ask an agent…, Capture a Task, Settings: <pane>. *Overlaps:* main menu (which has almost none of these), sidebar context menus
- `i` **Route buses (MainRoute, SettingsRoute, ExtensionsCommandBus, ProjectAreaRoute, HandoffRoute, OnboardingPresenter)** — Six @MainActor singletons each carrying one 'requested X' published value: MainRoute.request(MainSelection) (MenuBarMonitorView.swift:6-20), SettingsRoute.requestedPane: String? (SettingsView.swift:5-8), ExtensionsCommandBus.route/request (ExtensionsCommands.swift:10-32), ProjectAreaRoute.pending[projectID] = areaString (ProjectPageStore.swift:165-177), HandoffRoute.requestedSessionID (HandoffService.swift:9-18), OnboardingPresenter.isPresenting (OnboardingPresenter.swift:10-19). *Overlaps:* LaunchConfig.route (a seventh, test-only routing path), openWindow(id:) string ids
- `i` **Window ids "main" / "settings" / "extensions" / "session-window"** — SwiftUI scene ids used as string literals at 12 call sites (UncoilApp.swift:205,211; MenuBarMonitorView.swift:197; SidebarView.swift:108,154; ExtensionsCommands.swift:62; MainWindow.swift:394,411,421,670,780; AboutSettingsPage.swift:83), matched by substring in PaletteHotkeyMonitor (CommandPalette.swift:290-292) and by title "Uncoil" in ApplicationLifecycle (line 53). *Overlaps:* Route buses
- `i` **Launch route (LaunchConfig.route / -project-area / -extensions-* / -onboarding-step / -usage-fixture)** — UI-test navigation arguments (LaunchConfig.swift:28-49) read inside production views: MainWindow.applyLaunchRoute (661-690), ProjectDashboardView.swift:86-93, ExtensionsView.swift:147-156, UsageChip.swift:195. *Overlaps:* Route buses (ExtensionsCommandBus is used to carry the launch route)
- `U!` **Scratch workspace / One-off session** — A synthetic project for sessions that belong to no project; 'One-off <Provider> session' in the palette (PaletteModel.swift:315), 'One-off <Provider> Session' in the sidebar empty-area menu (SidebarOutline.swift:909), 'Close Scratch' context item. *Overlaps:* Project, Test Workspace
- `U!` **Test Workspace** — A generated acceptance project (TestWorkspaceService) offered as a palette command 'Create a Test Workspace' beside 'Add a New Project' (PaletteModel.swift:324-325; MainWindow.swift:373-383). *Overlaps:* Scratch workspace, Add Project
- `U!` **Debug Bundle** — Support export, available as palette 'Create Debug Bundle' (PaletteModel.swift:326-327, MainWindow.swift:384-392) and again in Settings > About > Support (AboutSettingsPage.swift:88-96); result shown via a shell alert.
- `U!` **Runtime (daemon) mismatch** — Internal daemon protocol version conflict surfaced as an alert titled 'Runtime Mismatch' with the raw message (MainWindow.swift:126-145).
- `U!` **Blueprint** — A stored setup prompt; exposed under its internal name as 'Apply Blueprint…' in the palette (PaletteModel.swift:358), sidebar project context menu (SidebarOutline.swift:768), Settings > Agents > Blueprints pane, and BlueprintCards; the sheet is owned by MainWindow (blueprintProject state, line 26) and also by SidebarView (line 33). *Overlaps:* Session Preset (Settings pane 'presets')
- `U` **Launcher providers / quick-launch strip** — The ordered list of providers shown on hover in a project row (SidebarView.swift:708), in the palette's one-off and New Session commands (PaletteModel.swift:312), the sidebar empty-area menu (SidebarOutline.swift:906), and the menu-bar 'New Session' submenu (MenuBarMonitorView.swift:113, which uses AgentProvider.sessionKinds instead — a different list). Configured in Settings > Appearance > Launcher. *Overlaps:* Installed Agents pane, AgentProvider.sessionKinds
- `U` **Attention Center** — AttentionStore items shown in a sidebar popover and duplicated as rows in the menu-bar extra; MainWindow polls tasks/conflicts every 20s and re-derives usage on every status/usage change (MainWindow.swift:162-191, 1175-1181). *Overlaps:* Menu bar monitor, Notifications
- `U` **Menu bar monitor** — A MenuBarExtra whose visibility is derived from prefs + live summary, with 9 configurable prefs (MenuBarPrefs.swift:87-103) and its own launcher/interrupt/orchestrator controls. *Overlaps:* Attention Center, sidebar launcher strip
- `i!` **Hook server / control plane / extension secret server** — Three local servers started from MainWindow.startServices/startControlPlane/startExtensionSecretServer (MainWindow.swift:819-1044). Internal, but the control plane's presence gates the Settings Permissions pane ('Control plane not running', SettingsView.swift:343-352) and the McpStatusStore badge.

### Flows

- **Cold launch to first screen** (4 steps) — friction: Every MainWindow instance runs the whole startup block; only hookServer/controlServer/secretServer are guarded, while RuntimeClient.onAliveSessions reassignment, pruneDroppedImages, resolveBinaries and checkCLIUpdates run once per window (861, 886-894). Onboarding state is a global singleton, so with two restored windows both show the overlay (inferred).
- **Add a project** (3 steps) — friction: Five entry points funnel into one @State on MainWindow; the follow-up sheet is an extensions-configuration step imposed on every add (feature leaking into the shell flow); the one-turn deferral is a workaround for sheet-after-panel.
- **Reach a session from outside the main window (notification, menu bar, blueprint, repair)** (4 steps) — friction: A global bus + counter + per-window filter replaces a router; callers inside the main window (HandoffSheet, BlueprintCards) go out through the singleton and back in. The sidebar's AttentionRailButton bypasses this path and sets selection directly without openInThisWindow (SidebarView.swift:165-172), so a scoped window can show a session whose project has no sidebar row (inferred from routedDetail not checking scope at MainWindow.swift:584-585).
- **Open a second window (⌘N)** (4 steps) — friction: ⌘N — the Mac's most universal shortcut — opens a modal question rather than a window. The 'workspace' model (per-window project list) is introduced by this question and nowhere else; sidebar visibility/width are still global @AppStorage, so windows are half-independent.
- **Pop a session out** (3 steps) — friction: Two names for one action; popouts are not restored across launches while main windows are (WindowRegistry.swift:137-143); the popout forces .dark regardless of theme (SessionPopoutWindow.swift:71).
- **Reach a Settings pane** (5 steps) — friction: Settings is a separate 24-pane window; the palette enumerates all 24 panes as top-level results, so 'Settings: Session Presets', 'Settings: Blueprints', 'Settings: Drivers' compete with projects and sessions in the same list.
- **Reach Extensions** (4 steps) — friction: Extensions — a power-user surface — is the only feature with a dedicated top-level menu and two global shortcuts, while sessions/projects have none in the menu bar.
- **Palette 'Create Worktree… [project]'** (3 steps) — friction: A command titled 'Create Worktree…' lands the user on the project page with no focus, no sheet and no indication where to type.
- **Onboarding re-entry** (3 steps) — friction: Setup is a 13-step modal over the whole app, with a persistent sidebar nag; the About page has to know that the flow 'lives in the main window' (comment at AboutSettingsPage.swift:81-82).

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| sidebarVisible | global | UserDefaults @AppStorage("sidebarVisible") read in UncoilApp.swift:22, MainWindow.swift:35, SidebarView.swift:16, SidebarView.swift:494 | ⌘B (View menu), titlebar toggle, drag divider below 120pt (MainWindow.swift:246-249) |  |
| sidebarWidth | global | UserDefaults @AppStorage("sidebarWidth") (MainWindow.swift:36) | divider drag only |  |
| windows.json (PersistedWindow[]) | global | <data dir>/windows.json via WindowRegistry.save (WindowRegistry.swift:316-326); skipped under UI testing and during termination | implicitly, on every selection/scope change and window close | yes |
| NSWindow frame autosave 'UncoilMainWindow[-slot]' | window | UserDefaults "NSWindow Frame UncoilMainWindow-N" (MainWindow.swift:1055-1073, 1127-1128) | implicitly on move/resize | yes |
| AppKit state restoration (NSQuitAlwaysKeepsWindows=false, ApplePersistenceIgnoreState=true, saved-state dir deleted) | global | UserDefaults + filesystem, forced in UncoilApp.init (UncoilApp.swift:47-63) | never by the user | yes |
| commandPaletteHotkey | global | SettingsStore (SettingsStore.swift:98, 251, 803, 854) | Settings > General (GeneralSettingsPage.swift:161) and onboarding 'Command palette' step (OnboardingExtensionsSteps.swift:227) |  |
| menuBar prefs (enabled, iconStyle, monochrome, counters×4, hideWhenIdle, clickAction, showTasksSection, showSessionsSection, showQuickLaunch) | global | SettingsStore.menuBar (MenuBarPrefs.swift:87-103) | Settings > Appearance > Menu Bar |  |
| sessionQuitBehavior | global | SettingsStore.sessionQuitBehavior mirrored into ApplicationLifecycle.shared (SettingsStore.swift:158, 308-309; ApplicationLifecycle.swift:8, 31-45) | Settings > General (GeneralSettingsPage.swift:136-148) |  |
| launcherProviders / launcher.order | global | SettingsStore.launcher (LauncherSettingsPage.swift:15) | Settings > Appearance > Launcher | yes |
| onboardingVersion / onboardingCompletedSteps | global | SettingsStore (SettingsStore.swift:723-744) | onboarding flow; Settings > About 'Run again' resets | yes |
| CollapsedProjects | global | CollapsedProjects.shared (SidebarView.swift:531, SidebarOutline.swift:771-774) | row chevron, context menu Hide/Show Sessions, Collapse All rail button |  |
| LaunchConfig arguments (-route, -project-area, -extensions-section/-query/-expand/-action, -onboarding-step, -window-width/height, -usage-fixture, -attention-fixture, -runtime-mismatch-fixture, -tests-run, -tests-step, -run-start, -issues-expand, -codex-app-server, -handoff-agent-stub, -notification-selftest, -runtime, -control-plane) | session | ProcessInfo arguments parsed in LaunchConfig.swift:74-114 (plus raw `arguments.contains` checks in UncoilApp.swift:32 and MainWindow.swift:944) | command line only |  |

### Visibility gates

- `App/UI/MainWindow.swift:67` — palette.isOpen → CommandPaletteOverlay mounted over mainContent
- `App/UI/MainWindow.swift:72-75, 650-659` — onboarding.isPresenting (OnboardingPresenter.shared) — set when settings.shouldPresentOnboarding, or UI test -route onboarding → OnboardingView covers the window; also removes TitlebarControls (271-275) and suppresses NewWindowOverlay (78)
- `App/UI/MainWindow.swift:78-83, 788-794; App/Core/WindowLayout.swift:123-126` — newWindowOptions != nil && !onboarding.isPresenting — set only when WindowRegistry.register() returns .asks (restoreQueue empty and another window already open) → NewWindowOverlay question; window scope stays .some([]) until answered
- `App/UI/MainWindow.swift:195, 246-249` — sidebarVisible (global @AppStorage); auto-set false when divider dragged below hideThreshold 120 → SidebarView + divider
- `App/UI/MainWindow.swift:570-583, 765-771` — sessionHolder(of: id) != nil (ownership.outcome == .heldElsewhere) → SessionElsewhereView instead of SessionDetailView
- `App/UI/MainWindow.swift:596-606, 756-761` — splitSessionID != nil && splitID != id && record/project resolvable; cleared when claim returns .heldElsewhere → SplitSessionPane in the HSplitView
- `App/UI/MainWindow.swift:553, 567, 614, 617` — selection nil, or id not found in projectStore → EmptyDetailView
- `App/UncoilApp.swift:139, 159-164` — settings.menuBar.isVisible(for: summary) (enabled && !(hideWhenIdle && idle)) — setter intentionally no-op → MenuBarExtra inserted
- `App/UI/MenuBarMonitorView.swift:77, 81, 93, 109` — settings.menuBar.showTasksSection / showSessionsSection && !attention.items.isEmpty / interruptible non-empty / showQuickLaunch && !projects.isEmpty → Task Board/Task Session/Stop the Orchestrator; attention rows; Interrupt submenu; New Session submenu
- `App/UncoilApp.swift:196-200` — UpdaterService.shared.isAvailable / canCheckForUpdates → 'Check for Updates…' menu item
- `App/UI/SidebarView.swift:136, 62` — scope.filter(projectStore.projects).isEmpty; !elsewhere.isEmpty → sidebar empty state; 'Open one you already have' list
- `App/UI/Onboarding/OnboardingView.swift:125` — !settings.remainingOnboardingSteps.isEmpty && !settings.shouldPresentOnboarding → sidebar 'Finish setup' row
- `App/UI/SidebarView.swift:24, 150-159` — settings.pendingCLIUpdates.count > 0 → count badge on the sidebar Settings gear (populated by MainWindow.startServices → checkCLIUpdates at 893)
- `App/UI/SidebarView.swift:141` — !selectedSessionIDs.isEmpty → batch actions bar
- `App/UI/Settings/SettingsView.swift:343-352; App/UI/MainWindow.swift:960-962` — sessionStore.permissionService != nil (set by MainWindow.startControlPlane) → Permissions pane vs 'Control plane not running' placeholder
- `App/Core/ProjectAreaAvailability.swift:89-96; App/UI/ProjectDashboardView.swift:35, 108` — ProjectAreaFacts (hasTaskSources/hasRunConfigurations/hasTestSuites/hasGitHubRepository) → which of Tasks/Run/Tests/Issues tabs exist; the rest become 'offers' on General
- `App/UI/MainWindow.swift:943-945; App/UncoilApp.swift:31-33, 37` — !LaunchConfig.isUITesting || arguments.contains("-control-plane") ; !isUITesting || "-runtime" ; !isUITesting → control plane server; runtime daemon client; hook path repair
- `App/UI/CommandPalette.swift:285-294` — window.identifier contains "settings" or "session-window" → palette hotkey suppressed in those windows
- `App/UI/MainWindow.swift:1103-1128` — LaunchConfig.windowWidth && windowHeight set → fixed frame, no autosave; else setFrameUsingName or center + 28pt·slot cascade → window placement
- `App/UI/MainWindow.swift:661-690` — config.route == "extensions" / "session" ; selection == nil → first project in scope → launch destination
- `App/UI/UsageChip.swift:195` — LaunchConfig.usageFixture && UsageCardAutoOpen.claim() → usage card popover auto-opens
- `App/UI/AttentionCenterView.swift:132-140` — item.kind == .usageLow || .usageExhausted && sessionID != nil → 'Hand off' button on an attention row → HandoffRoute

### Open questions

- Is per-window project scope (WindowProjects) a product feature users asked for, or a by-product of the exclusive-terminal constraint? The registry comment (WindowRegistry.swift:137-148) suggests the latter; the NewWindowOverlay copy suggests the former.
- Should Extensions remain a separate window with its own top-level menu, or is it a section of Settings / a page of the main window? Its 11 sections and quick actions are the largest single navigation tree in the app.
- Which of the 21 PaletteAction cases are meant to be discoverable elsewhere? Today Ask, Capture, One-off session, Test Workspace, Debug Bundle, Create Worktree, Restart/Close are palette-only or palette-first.
- Is the -route/-project-area/-extensions-* argument family meant to become a public deep-link scheme (there is no CFBundleURLTypes / onOpenURL today)? If so it should share the Destination type.
- Does the onboarding step list (13 in code, 9 in CLAUDE.md) reflect the intended first-run scope, or has it grown by accretion?
- Is the popout window intended to stay terminal-only and non-restorable, or should it be a full window on a session (which would remove SessionElsewhereView's second host)?
- MenuBarPrefs.clickAction ('Open the Uncoil window' on left click) is stored but never implemented — was it dropped intentionally?

---

## Sidebar (project/group/session tree, hover controls, context menus, rail, badges, multi-select, drag/drop, empty state, onboarding resume row, Quick Launch prefs, Scratch workspace)

The sidebar is Uncoil's only navigation: a 252pt-max column (MainWindow.swift:46) holding an NSOutlineView tree of projects → groups/sessions → child sessions, with Uncoil's own "Scratch" pseudo-project pinned to the bottom. It is also the app's primary launch surface (the hover-only agent strip on a project row is the main way to start a session), its status board (every session row shows a provider mark, a 10-state status orb, a relative clock, an attention pulse and optionally a pin, checkbox and child mark), its batch-operations surface (multi-select bar), its onboarding debt tracker ("Finish setup" row), and its maintenance dashboard (a CLI-update count badge on the Settings rail button and an attention bell badge). Below the list sits a rail of five buttons (Settings, Add project, Attention bell, Multi-select toggle, Collapse-all), while Hide-sidebar and Command-palette live in the window title bar. Sessions never leave the sidebar on their own: closed sessions stay inline, dimmed, forever, while the dashboard shows the same sessions again split into "Sessions" and "Closed Sessions". Almost every action is reachable only by hover or right-click, and the same action (add a project, start a session, group sessions, pop out a session) has three to five differently-worded entry points across the sidebar, the palette, the dashboard and the empty states.

### Findings

#### [CRITICAL] SB-01 — The primary action (start a session) is a hover-only strip with a hidden right-click inside it

*Category:* discoverability

- `App/UI/SidebarView.swift:604` — if hovering {                         // The launcher floats above the row instead of sitting                         // in it: laid out inline it grew the row on hover
- `App/UI/SidebarView.swift:680` — // never choosable; right-click is where the choice lives, so                 // the common case does not pay for the rare one.                 .contextMenu {
- `App/UI/SessionDetailView.swift:249` — Text("Hover a project, pick an agent")
- `App/UI/ProjectDashboardView.swift:425` — Text("No sessions yet — start an agent from the top right.")
- `App/UI/Settings/LauncherSettingsPage.swift:31` — Text("Drag to reorder. At least one shortcut stays — without one there is no way to start a session from the project screen.")

**Why it matters:** Nothing at rest says a project row can launch anything. Three different screens have to explain the gesture in prose, and they disagree about where it is. Choosing a non-default account is a right-click on a 22×18 button that itself only exists on hover. Every new provider adds another button to a strip that already competes for the same ~90pt as the chevron and the name (SidebarView.swift:556-573 comments describe the chevron chasing problem this caused).

**Direction:** Give session creation one visible, resting affordance (row-level or window-level) and make account selection a first-class part of it.

#### [CRITICAL] SB-02 — A session row carries up to nine signals plus four invisible gestures

*Category:* concept-overload

- `App/UI/SidebarView.swift:861` — if showsSelectionControl {
- `App/UI/SidebarView.swift:874` — if isChild {                         // Marks the row as work another agent handed out. Faint                         // on purpose
- `App/UI/SidebarView.swift:889` — if record.isPinned == true || hovering {                         PinButton(record: record)                     }                     StatusOrb(status: status, size: 11)                     Text(RelativeClock.short(since:
- `App/UI/SidebarView.swift:908` — .background(                 RoundedRectangle(cornerRadius: Theme.Radius.chip)                     .fill(attentionColor.opacity(                         wantsAttention && pulsing ? emphasis.fillOpacity : 0.0
- `App/UI/SidebarView.swift:883` — .help("Drag onto a group to move it; drop outside the window to open it in a new one")
- `App/UI/MainWindow.swift:46` — static let maxSidebarWidth: Double = 252

**Why it matters:** Checkbox, child mark, provider mark, title, pin, 10-state orb, clock, attention wash, pulsing border and selection border all fit in a 252pt-max column with up to 28pt indent — the title is what gets truncated. On top of that the same row is a drag source with three outcomes (reorder/regroup, split view, pop-out) and a click target for one of three selection modes. Each added session feature (children, sleep, attention) has landed on this one row.

**Direction:** Decide what a row is for (navigate + status) and move everything else (pin, child marker, checkbox, attention) into either a secondary line, a hover reveal with a resting hint, or the detail view.

#### [HIGH] SB-03 — Sessions are listed twice (sidebar and dashboard) with two different definitions of "closed", and closed sessions never leave the sidebar

*Category:* duplicate-concept

- `App/UI/AppKit/SidebarOutline.swift:246` — sessions: {                     store.sessions(for: $0).map { ($0.id, $0.groupID, $0.parentSessionID) }
- `App/Core/ProjectStore.swift:306` — func activeSessions(for projectID: UUID) -> [SessionRecord] {         sessions(for: projectID).filter { $0.endedAt == nil }     }      func sessionHistory(for projectID: UUID) -> [SessionRecord] {         sessions(for: p
- `App/UI/ProjectDashboardView.swift:446` — PanelHeading(title: String(localized: "Closed Sessions"), count: records.count)
- `App/UI/SidebarView.swift:881` — .opacity(status == .terminated ? 0.45 : 1)
- `App/CLAUDE.md:0` — (inferred) no prune/archive path for ended sessions exists in ProjectStore — the only removals are removeSession(s), removeProject and closeScratchWorkspace

**Why it matters:** The sidebar shows every session ever created, ended or not, dimmed by `status == .terminated`, while the dashboard partitions by `endedAt`. The user sees the same items in two places under two rules. The sidebar's row count grows without bound until the user deletes by hand, and there is no closed/history row type or section to collapse them into.

**Direction:** One definition of closed; one place for history (a collapsible section or the dashboard only), so the sidebar is the live tree.

#### [HIGH] SB-04 — Provider identity leaks into global status semantics: the permission colour is Claude's brand colour and Organise hard-codes Claude

*Category:* agent-leak

- `App/Core/Models.swift:652` — case .waitingForPermission: Theme.claude
- `App/Core/AttentionCenter.swift:81` — case .permission: Theme.claude
- `App/UI/SidebarView.swift:843` — private var attentionColor: Color {         status.needsAttention ? status.color : Theme.highlight     }
- `App/UI/MainWindow.swift:622` — let record = projectStore.createSession(             projectID: projectID,             provider: .claude,
- `App/UI/SessionDetailView.swift:246` — ProviderMark(provider: .claude, size: 20)                 ProviderMark(provider: .codex, size: 20)
- `App/Core/Models.swift:822` — /// Sidebar/dashboard title: the provider prefix ("claude: ") is redundant     /// next to the provider mark, so it is stripped for display

**Why it matters:** A Codex or Gemini session waiting for permission pulses in Claude orange in the sidebar and in the attention bell. The dashboard's "Organise" button, reached from the sidebar's project selection, always spawns a Claude session regardless of what is installed or set as default. The empty state shows Claude+Codex marks whatever the machine has. Session titles bake the provider into the data ("claude: new session") and strip it at display time.

**Direction:** Status colours from a status palette, never a brand palette; provider choice for automated sessions from one resolved default.

#### [HIGH] SB-05 — Three overlapping "which agent" settings feed different sidebar actions

*Category:* duplicate-concept

- `App/UI/Settings/GeneralSettingsPage.swift:21` — title: String(localized: "Default agent"),                         detail: String(localized: "New sessions open with this provider.")
- `App/Core/SettingsStore.swift:282` — var launcherProviders: [AgentProvider] {         LauncherPrefs.resolved(launcher, installed: installedProviders)     }
- `App/UI/SidebarView.swift:693` — let account = chosen ?? settings.defaultAccount(for: provider)
- `App/UI/BlueprintCards.swift:149` — subtitle: String(localized: "Opens a session in \(project.name) with \(settings.defaultProvider.displayName) and gives it the prompt.")
- `App/UI/Settings/SettingsView.swift:35` — /// written rather than where they are looked for: Quick Launch is a strip     /// in the interface and was filed under Agents

**Why it matters:** "New sessions open with this provider" is false for the sidebar: the strip ignores defaultProvider and offers launcher.order; Apply Blueprint (a sidebar menu item) uses defaultProvider; Organise uses .claude. The default account is a fourth knob only reachable via a hidden right-click. The user cannot form one rule for "what happens when I start something".

**Direction:** One resolved launch default (provider + account) consulted by every entry point; the strip is a view of installed providers, not a separate setting.

#### [HIGH] SB-06 — Session context menu mixes everyday, layout, window, lifecycle and MCP-developer actions in one 11-item menu

*Category:* concept-overload

- `App/UI/AppKit/SidebarOutline.swift:794` — title: record.isPinned == true ? String(localized: "Unpin") : String(localized: "Pin")
- `App/UI/AppKit/SidebarOutline.swift:800` — add(to: menu, title: String(localized: "Move Up")) {
- `App/UI/AppKit/SidebarOutline.swift:813` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/UI/AppKit/SidebarOutline.swift:823` — add(to: menu, title: String(localized: "Copy the Session ID")) {
- `App/UI/AppKit/SidebarOutline.swift:827` — add(to: menu, title: String(localized: "Copy the Provider Session ID")) {
- `App/UI/AppKit/SidebarOutline.swift:832` — add(to: menu, title: String(localized: "Delete the Session")) {
- `App/UI/AppKit/SidebarOutline.swift:836` — /// Hibernation is absent rather than disabled for a provider that cannot         /// resume

**Why it matters:** Pin / Move Up / Move Down / Remove from Group / Open in a New Window / Wake / Pause / Hibernate / Copy the Session ID / Copy the Provider Session ID / Delete the Session — the shape of the menu changes per provider and per state, so users cannot learn it. "Session ID" and "Provider Session ID" are control-plane internals surfaced under their internal names. Meanwhile Restart and Close (the two most common lifecycle actions) are not here at all but in the palette (PaletteModel.swift:365-371) and the header bar.

**Direction:** Split into everyday (open/rename/pin/close) vs advanced (ids, sleep modes) with stable ordering; disabled-with-reason instead of absent.

#### [HIGH] SB-07 — Grouping has four entry points with different semantics, and a group is both a container and a page

*Category:* navigation

- `App/UI/SidebarView.swift:315` — .disabled(selectedProjectIDs.count != 1)             .help("Group the selected")
- `App/UI/SidebarView.swift:226` — Text("An empty group is created; drag sessions into it.")
- `App/UI/ProjectDashboardView.swift:414` — title: String(localized: "Organise"),                     help: String(localized: "Group this project's sessions by what they are working on."),
- `App/UI/MainWindow.swift:3` — enum MainSelection: Hashable {     case project(UUID)     case group(UUID)     case session(UUID) }
- `App/UI/SessionGroupView.swift:82` — Button("Delete Group") {                 projectStore.removeGroup(group.id)
- `App/UI/AppKit/SidebarOutline.swift:4` — /// Projects persist theirs in `CollapsedProjects`; groups did not before the /// move to an outline view and still do not, so a group reopens expanded.

**Why it matters:** Multi-select → folder-plus (silently disabled across projects), project menu → empty group + drag, ⌘-click → batch bar, dashboard Organise → an agent does it via MCP. Selecting a group navigates to a whole page with its own delete, prompt box and management panel, so a folding container is also a destination. Group collapse is not persisted while project collapse is. Child sessions add a second, orthogonal nesting that overrides the group (SidebarStructure.swift:60-63).

**Direction:** One grouping gesture (drag or select-then-group) and groups as pure containers; decide whether nesting means "group" or "spawned by" and show only one hierarchy at a time.

#### [HIGH] SB-08 — The Settings rail button doubles as an agent-CLI update badge, beside a second badge system on the bell

*Category:* agent-leak

- `App/UI/SidebarView.swift:153` — help: pendingUpdates.isEmpty                         ? String(localized: "Settings")                         : String(localized: "Settings — \(pendingUpdates.count) agent updates waiting")
- `App/UI/SidebarView.swift:161` — .countBadge(                     pendingUpdates.count,                     label: String(localized: "\(pendingUpdates.count) updates waiting")
- `App/Core/SettingsStore.swift:563` — var pendingCLIUpdates: [AgentProvider] {         AgentProvider.agents.filter { updateAvailability(for: $0).isPending }
- `App/UI/AttentionCenterView.swift:204` — if store.unreadCount > 0 {                     Circle()                         .fill(badgeColor ?? Theme.highlight)                         .frame(width: 6, height: 6)

**Why it matters:** A red numeric capsule on the gear says "something is wrong with settings" when it means "npm has a newer claude". Next to it the bell uses a 6pt coloured dot for a different notion of pending. Two badge languages, one 20pt apart from the other, both in the navigation column. Every future "there is news" feature will want a third.

**Direction:** One notification channel (the bell / attention centre) carries CLI updates as an item; the gear stays a plain button.

#### [MEDIUM] SB-09 — Onboarding debt is parked in the navigation column as a permanent "Finish setup N" row

*Category:* onboarding

- `App/UI/Onboarding/OnboardingView.swift:124` — let remaining = settings.remainingOnboardingSteps         if !remaining.isEmpty && !settings.shouldPresentOnboarding {
- `App/Core/OnboardingState.swift:47` — var isActionable: Bool {         switch self {         case .welcome, .finish: false         default: true
- `App/Core/OnboardingState.swift:62` — /// 3: the working-mode and optional-tools steps.     static let currentVersion = 3
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:288` — Text("Anything you skipped stays listed at the bottom of the sidebar under “Finish setup”.")

**Why it matters:** Eleven actionable steps (CLIs, accounts, working modes, hooks, notifications, capabilities, tools, project, tasks, extensions, palette) are configuration, and their remainder is counted in the sidebar. A version bump re-lists new steps. The sidebar becomes the place where the app nags about setup, which is exactly the growth pattern the plan is about.

**Direction:** Keep setup remainder in Settings/About (or the attention centre) and out of the tree.

#### [MEDIUM] SB-10 — Provider/feature gating is spread across stores, pure rules and views with no registry

*Category:* visibility-logic

- `App/Core/SettingsStore.swift:282` — var launcherProviders: [AgentProvider] {         LauncherPrefs.resolved(launcher, installed: installedProviders)
- `App/Core/PaletteModel.swift:523` — var launcherProviders: [AgentProvider] { resolveLauncherProviders() }     private var resolveLauncherProviders: () -> [AgentProvider] = { AgentProvider.sessionKinds }
- `App/UI/AppKit/SidebarOutline.swift:882` — for provider in environment.settings.launcherProviders {
- `App/UI/AppKit/SidebarOutline.swift:847` — if case .success = SessionSleep.canHibernate(                 status: status,                 provider: record.provider,                 providerSessionID: record.providerSessionID
- `App/UI/SidebarView.swift:681` — if provider.isAgent, choices.count > 1 {
- `App/Core/Models.swift:33` — /// This list was written out by hand in twenty-two places — some with the     /// terminal, some without

**Why it matters:** What a provider can do (launch, hibernate, choose account, report status) is decided by AgentProvider.isAgent, resumesConversation, LauncherPrefs.resolved, SessionSleep and per-view ifs. The sidebar re-derives them in three places (strip, empty menu, palette via a closure). Adding a provider or a capability means touching each; the code comment in Models.swift records that this already went wrong 22 times.

**Direction:** A single provider-capability registry the sidebar, palette and menus read from.

#### [MEDIUM] SB-11 — The same action has three to five labels across the sidebar, palette and empty states

*Category:* terminology

- `App/UI/SidebarView.swift:58` — Button("Add a Project") { showFolderPicker = true }
- `App/UI/SidebarView.swift:172` — RailButton(iconName: "plus", help: String(localized: "Add a project"))
- `App/UI/AppKit/SidebarOutline.swift:873` — add(to: menu, title: String(localized: "New Project…")) {
- `App/UI/SessionDetailView.swift:255` — Button("Add Project") { showFolderPicker = true }
- `App/Core/PaletteModel.swift:322` — PaletteItem(id: "cmd.addProject", title: String(localized: "Add a New Project"),
- `App/UI/AppKit/SidebarOutline.swift:813` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/Core/PaletteModel.swift:371` — items.append(PaletteItem(id: "cmd.popout", title: String(localized: "Open in a Popout Window"),
- `App/UI/SidebarView.swift:186` — help: isMultiSelecting ? String(localized: "Turn off multiple selection") : String(localized: "Select several"),
- `App/UI/AppKit/SidebarOutline.swift:771` — add(to: menu, title: collapsed ? String(localized: "Show Sessions") : String(localized: "Hide Sessions")) {
- `App/UI/SidebarView.swift:1061` — .help(allCollapsed ? "Show all sessions" : "Hide all sessions")
- `App/UI/AppKit/SidebarOutline.swift:779` — add(to: menu, title: String(localized: "Remove from List")) {                     environment.projectStore.removeProject(project)

**Why it matters:** Add a Project / Add a project / New Project… / Add Project / Add a New Project; Open in a New Window vs Open in a Popout Window; Delete the Session vs Delete Sessions vs Remove from List (which actually deletes every session) vs Close Scratch; Pause (menu) vs Paused (status) vs Hibernate vs Asleep; Hide Sessions vs collapse chevron. Each is a small tax; together they prevent a vocabulary from forming.

**Direction:** A shared action catalogue with one label per verb used by menus, palette, rail tooltips and empty states.

#### [MEDIUM] SB-12 — Scratch is a project that is not a project, with its own menu shape, sort rule, visibility rule and lifecycle

*Category:* concept-overload

- `App/Core/ProjectStore.swift:112` — /// The sidebar deliberately does *not* use this: a one-off session has to     /// be reachable, it just belongs at the bottom and marked as what it is.     var visibleProjects: [Project] {         projects.filter { !$0.
- `App/Core/ProjectStore.swift:552` — func closeScratchWorkspaceIfEmpty() {         guard let scratch = scratchProject,               sessions(for: scratch.id).isEmpty else { return }         projects.removeAll { $0.id == scratch.id }
- `App/UI/AppKit/SidebarOutline.swift:730` — if project.isScratchWorkspace {                     let collapsed = CollapsedProjects.shared.contains(id)
- `App/UI/SidebarView.swift:275` — Text("The folder itself is left alone — anything worth keeping is still in it. Scratch comes back the next time you open a one-off session.")
- `App/Core/ScratchWorkspace.swift:71` — enum ProjectSortRank {     static func rank(isScratch: Bool, isPinned: Bool) -> Int {         if isScratch { return 2 }

**Why it matters:** The user sees a project row that appears when they start a "one-off" session, disappears when they delete the last one, cannot be pinned or moved, has a different context menu, and is called "Scratch" in the tree but "One-off … Session" in menus and "scratch folder" in the palette. The code has to special-case it in the store, the sort, the row, the menu and the window scope (SidebarView.swift:126-130).

**Direction:** Either make one-off sessions a first-class top-level row kind (not a project) or make Scratch an ordinary, permanent project.

#### [MEDIUM] SB-13 — Three selection modes with a stateful rail toggle, and multi-selection silently detaches the detail view

*Category:* navigation

- `App/UI/AppKit/SidebarOutline.swift:525` — /// In multi-select mode a plain click adds to the selection instead of         /// replacing it — the accumulate-by-clicking that the checkbox mode has         /// always had, now from anywhere on the row.
- `App/UI/AppKit/SidebarOutline.swift:572` — if selected.count > 1 || (environment.isMultiSelecting && !sessionIDs.isEmpty) {                 environment.selectedSessionIDs.wrappedValue = Set(sessionIDs)                 return             }
- `App/UI/SidebarView.swift:190` — isMultiSelecting.toggle()                         if !isMultiSelecting {                             selectedSessionIDs.removeAll()
- `App/UI/AppKit/SidebarOutline.swift:49` — if old.isMultiSelecting != new.isMultiSelecting { return .all }

**Why it matters:** Rail toggle (checkboxes, click accumulates), ⌘/⇧-click (no mode), and dragging a selection all lead to the same batch bar; turning the mode off wipes the selection; while several are selected `selection` is left pointing at whatever was open before. The rail button is the only stateful control on the rail and looks like the others.

**Direction:** Native ⌘/⇧ selection only, batch bar on demand, no mode toggle.

#### [MEDIUM] SB-14 — Two simultaneous empty states plus a hidden right-click menu on first run

*Category:* empty-state

- `App/UI/SidebarView.swift:56` — Text(projectStore.projects.isEmpty ? "No projects yet" : "No projects in this window")
- `App/UI/SessionDetailView.swift:240` — struct EmptyDetailView: View {
- `App/UI/AppKit/SidebarOutline.swift:918` — // Below the last row there is no project to act on, and right-clicking         // there did nothing at all — including on a first run, where the empty         // sidebar *is* the whole window and adding a project is the
- `App/UI/MainWindow.swift:687` — if selection == nil,            let first = projectScope.filter(projectStore.visibleProjects).first {             selection = .project(first.id)

**Why it matters:** On a blank window the user sees "No projects yet / Add a Project" on the left and "Hover a project, pick an agent / Add Project" on the right, both describing the same first step differently; the third way (one-off session) is only in a right-click on empty space. The multi-window scope concept ("No projects in this window", "Open one you already have") is exposed here too.

**Direction:** One empty state, one call to action, with one-off sessions visible as a real option.

#### [MEDIUM] SB-15 — Drag semantics (reorder, regroup, split, pop-out) are invisible and refusals are silent

*Category:* discoverability

- `App/UI/AppKit/SidebarDrop.swift:85` — // Sessions belong to their project; a cross-project drop would have             // to re-parent worktrees and accounts, so it is refused rather than             // half-applied.
- `App/UI/AppKit/SidebarDrop.swift:92` — case .root:                 return .refuse
- `App/UI/AppKit/SidebarOutline.swift:645` — case .group:                 // Groups are containers, not payloads: dragging one would have                 // to mean "move its sessions"
- `App/UI/AppKit/SidebarOutline.swift:711` — // One window for one session. A dragged-out batch would open a                   // window per row, which is never what the gesture meant.                   ids.count == 1
- `App/UI/AppKit/SidebarOutline.swift:68` — static let external: NSDragOperation = []

**Why it matters:** A session dragged across projects, a group dragged anywhere, or a multi-selection dragged out of the window just snaps back. The only written hint is a tooltip on an 11pt glyph. Users learn the rules by failing.

**Direction:** Fewer drag outcomes, each with visible feedback; pop-out and split as explicit commands.

#### [MEDIUM] SB-16 — Internal names shown to the user: Blueprint, Provider Session ID, Hibernate, Scratch, worktree in titles, Customise with "MCP & Skills"

*Category:* terminology

- `App/UI/AppKit/SidebarOutline.swift:768` — add(to: menu, title: String(localized: "Apply Blueprint…")) {
- `App/UI/BlueprintCards.swift:158` — Text("No blueprints yet. Settings › Agents › Blueprints is where they are written.")
- `App/UI/SidebarView.swift:699` — ? (worktreeName.map { "terminal @ \($0)" } ?? "terminal")
- `App/UI/ProjectCustomizeSheet.swift:19` — case .extensions: String(localized: "MCP & Skills")
- `App/UI/AppKit/SidebarOutline.swift:856` — items.append((String(localized: "Hibernate"), {

**Why it matters:** A project's right-click menu asks the user to "Apply Blueprint…" and "Customise…" a project's "MCP & Skills"; a session menu offers "Hibernate" and "Copy the Provider Session ID". These are implementation vocabulary surfaced in the most-used menus.

**Direction:** Rename to user verbs ("Start with a saved prompt", "Project settings", "Put to sleep") or move to advanced surfaces.

#### [MEDIUM] SB-17 — Depth model overloads indent: group depth and sub-agent depth share the same visual language and cap at two rails

*Category:* coupling

- `App/UI/SidebarView.swift:804` — /// 1 directly under a project, 2 inside one of its groups, and one deeper     /// per level of sub-agent.
- `App/UI/SidebarView.swift:806` — /// Spawned by another session through the control plane. Indent alone does     /// not say so — a sub-agent sits at the same inset as a grouped session.
- `App/UI/SidebarView.swift:347` — static func leading(depth: Int) -> CGFloat {         switch depth {         case 0: return 4         case 1: return 16         default: return 28
- `App/UI/SidebarView.swift:358` — static func rails(depth: Int) -> [CGFloat] {         switch depth {         case 0: return []         case 1: return [11]         default: return [11, 23]
- `App/UI/AppKit/SidebarStructure.swift:60` — // A child is placed by its parent, never by its own group: it is             // drawn inside the parent's row, and honouring its group as well             // would draw it twice.

**Why it matters:** A grouped session and a sub-agent look identical except for a 9pt faint glyph; a grandchild inside a group (depth 4) draws exactly like depth 2. Two hierarchies (organisational groups and runtime parentage) compete for one indent axis, and a child's own group membership is silently ignored.

**Direction:** Pick one hierarchy for the tree; show the other as metadata.

#### [LOW] SB-18 — Sidebar owns sheets for actions it does not initiate, routed through a closure bag; stale comment about where the window controls live

*Category:* coupling

- `App/UI/SidebarView.swift:30` — // Sheets and dialogs the row context menus ask for. They live here rather     // than in the rows because a recycled row is the wrong owner for a window.
- `App/UI/AppKit/SidebarOutline.swift:975` — struct SidebarRowActions {     var openSessionWindow: (UUID) -> Void     var customizeProject: (Project) -> Void
- `App/UI/SidebarView.swift:488` — /// Lives in the sidebar when there is one and beside the traffic lights when /// there is not
- `App/UI/TitlebarControls.swift:13` — /// They stay there whether the sidebar is open or not: a control that moved /// house when the sidebar closed is a control you have to look for.

**Why it matters:** Adding one row action means a menu item in SidebarOutline, a closure in SidebarRowActions, a @State and a sheet/alert modifier in SidebarView (already 9 modifiers, lines 199-278). The WindowControlsCluster comment contradicts its actual home, a sign the sidebar's boundary has drifted.

**Direction:** Route row actions through the same command bus the palette uses so menus, palette and rail share one action list.

#### [LOW] SB-19 — "Remove from List" destroys every session in the project without confirmation while every other delete asks

*Category:* visibility-logic

- `App/UI/AppKit/SidebarOutline.swift:779` — add(to: menu, title: String(localized: "Remove from List")) {                     environment.projectStore.removeProject(project)
- `App/Core/ProjectStore.swift:223` — func removeProject(_ project: Project) {         projects.removeAll { $0.id == project.id }         sessions.removeAll { $0.projectID == project.id }         sessionGroups.removeAll { $0.projectID == project.id }
- `App/UI/SidebarView.swift:250` — Text("The running process is closed; the recording cannot be recovered.")

**Why it matters:** The label promises a list edit; the store deletes recordings. Deleting one session prompts, deleting all of them via the project does not.

**Direction:** Same confirmation policy as sessions, and a label that says what happens.

#### [LOW] SB-20 — Sidebar behaviour is configured in three settings categories and two UserDefaults keys

*Category:* settings-sprawl

- `App/UI/Settings/SettingsView.swift:115` — case .theme, .menuBar, .launcher: .appearance
- `App/UI/Settings/AppearanceSettingsPage.swift:36` — get: { settings.attentionEmphasis },
- `App/UI/Settings/GeneralSettingsPage.swift:12` — Picker(selection: Binding(                     get: { settings.defaultProvider },
- `App/UI/SidebarView.swift:636` — private static let key = "collapsedProjects"

**Why it matters:** Quick Launch (Appearance), attention pulse (Appearance > Theme), default agent (General), accounts (Agents), plus sidebarVisible/sidebarWidth/collapsedProjects in UserDefaults. There is no place that describes "the sidebar".

**Direction:** Fold strip membership into installed-agent detection and keep only the pulse level as a real preference.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Sidebar column | panel | `App/UI/SidebarView.swift` | MainWindow.swift:195-201 when sidebarVisible; ⌘B / title bar toggle / divider drag under 120pt hides it (MainWindow.swift:246-249, UncoilApp.swift:82-85) |
| Sidebar outline tree | panel | `App/UI/AppKit/SidebarOutline.swift` | SidebarView.swift:100 |
| Project row | row | `App/UI/SidebarView.swift` | SidebarOutline.swift:433-444 |
| Session group row | row | `App/UI/SidebarView.swift` | SidebarOutline.swift:445-452 |
| Session row (incl. child / sleeping / closed variants) | row | `App/UI/SidebarView.swift` | SidebarOutline.swift:453-469 |
| Agent launcher strip (hover) | hover-control | `App/UI/SidebarView.swift` | ProjectRowView hover (604-611); WorktreeRow hover (ProjectDashboardView.swift:841-848) |
| Batch actions bar | toolbar | `App/UI/SidebarView.swift` | multi-select toggle + click; ⌘/⇧-click without mode (SidebarOutline.swift:533-556) |
| Onboarding resume row ("Finish setup") | row | `App/UI/Onboarding/OnboardingView.swift` | visible when settings.remainingOnboardingSteps non-empty && !shouldPresentOnboarding (124-125) |
| Bottom rail | toolbar | `App/UI/SidebarView.swift` | always rendered (150-197) |
| Attention rail button + popover | popover | `App/UI/AttentionCenterView.swift` | SidebarView.swift:176 |
| Window controls cluster (title bar) | toolbar | `App/UI/SidebarView.swift` | MainWindow.swift:273-280 (hidden during onboarding) |
| Empty sidebar | empty-state | `App/UI/SidebarView.swift` | first run / new window |
| Empty-area context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | SidebarOutlineView.menu(for:) row<0 (924) |
| Project row context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click project row |
| Group row context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click group row |
| Session row context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click session row |
| Quick Launch settings page | screen | `App/UI/Settings/LauncherSettingsPage.swift` | Settings window, Appearance category |
| Project Customise sheet (from sidebar menu) | sheet | `App/UI/ProjectCustomizeSheet.swift` | SidebarOutline.swift:765 Customise… |
| Apply Blueprint sheet (from sidebar menu) | sheet | `App/UI/BlueprintCards.swift` | SidebarOutline.swift:768 Apply Blueprint…; palette |

### Concepts

- `U` **Project** — A folder the user added; top-level sidebar row. Has name, icon, colour, pin, manual sortIndex (Models.swift:548-580). *Overlaps:* Scratch workspace, Window scope
- `U!` **Scratch workspace ("Scratch")** — A project Uncoil owns (isScratch) that hosts "one-off" sessions in Uncoil's data directory; created lazily, sorted last, excluded from visibleProjects, auto-removed when its last session is deleted, returns on the next one-off (ScratchWorkspace.swift; ProjectStore.swift:56-125, 552-577). *Overlaps:* Project, Session
- `U` **Session** — A terminal running an agent CLI or a shell inside a project (SessionRecord, Models.swift:734). Sidebar shows all of them, ended or not. *Overlaps:* Child session, Closed session, Sleeping session
- `U` **Child session (sub-agent)** — A session spawned by another through the control plane (parentSessionID); drawn nested under its parent with a corner-down-right glyph, ignores its own groupID (SidebarStructure.swift:31-40, 60-63; SidebarView.swift:874-880). *Overlaps:* Group, Session
- `U` **Session group** — A named container inside one project; sessions carry groupID (Models.swift:586-600). Also a navigation destination with its own page (MainSelection.group → SessionGroupView). *Overlaps:* Child session nesting, Multi-select
- `U` **Closed session** — Session with endedAt set (dashboard partition, ProjectStore.swift:306-314) or status == .terminated (sidebar dimming, SidebarView.swift:881). Two different predicates for the same idea. *Overlaps:* Session, Sleeping session
- `U!` **Sleeping session (Pause / Hibernate / Wake)** — suspended = SIGSTOP; hibernated = process killed, resumable via provider id (SessionSleep.swift:9-14). Hollow-ring orb; status labels "Paused"/"Asleep". *Overlaps:* Closed session
- `U` **Pinned (project / session)** — Sorts first among siblings; Scratch cannot be pinned (ProjectSortRank). *Overlaps:* Manual order (Move Up/Down, drag)
- `U` **Hidden / collapsed sessions** — Per-project collapse persisted in UserDefaults (CollapsedProjects, SidebarView.swift:634-668); per-group and per-parent-session collapse in memory only (CollapsedGroups, SidebarOutline.swift:4-22).
- `U` **Multi-select mode** — Rail toggle that adds checkboxes and makes plain click accumulate (SidebarView.swift:185-194; SidebarOutline.swift:533-556); ⌘/⇧-click works without it; either feeds the batch bar. *Overlaps:* Group
- `U` **Attention (wantsAttention)** — status.needsAttention (waitingForPermission/waitingForInput) OR unseenAttention (a notification not yet looked at) (ProjectStore.swift:779-781). Row pulses in status colour or Theme.highlight (SidebarView.swift:843-845). *Overlaps:* Attention Center items, Status
- `U` **Attention emphasis** — off/subtle/full motion level for pulsing rows and orbs (AttentionEmphasis.swift).
- `U` **Provider (AgentProvider)** — claude/codex/gemini/opencode/grok/hermes/cursor/terminal (Models.swift:20-28); each has a brand mark and colour. *Overlaps:* Default agent, Quick Launch strip, Account
- `U!` **Quick Launch strip (LauncherPrefs)** — Ordered provider list shown on hover; empty = terminal + installed agents (LauncherPrefs.swift:26-45). Also feeds the palette's one-off commands and the empty-area menu. *Overlaps:* Default agent (defaultProvider), Installed Agents settings
- `U` **Default agent (defaultProvider)** — SettingsStore.defaultProvider, set in onboarding CLI step and Settings > General ("New sessions open with this provider." GeneralSettingsPage.swift:21-22). The sidebar strip never reads it; Apply Blueprint from the sidebar does (BlueprintCards.swift:149). *Overlaps:* Quick Launch strip, Default account
- `U` **Default account (per provider)** — defaultAccountByProvider, falls back to first account (SettingsStore.swift:339-345). Launcher click uses it; right-click on a launcher button lets you pick another. *Overlaps:* Default agent
- `U!` **Blueprint** — A stored setup prompt applied to a new session (BlueprintStore). Internal name shown as-is. *Overlaps:* Session preset (not exposed in sidebar)
- `U` **Customise (project identity + MCP & Skills)** — Project name/icon/colour and per-agent extension bindings in one sheet. *Overlaps:* Extensions window
- `U!` **Session ID / Provider Session ID** — Uncoil UUID used by MCP tools; provider's own resume id.
- `U` **Window scope (WindowProjects)** — Which projects a window lists: .all or .some(Set) (WindowLayout.swift:41). Drives the "No projects in this window" / "Open one you already have" empty state. *Overlaps:* Project
- `U` **Pop-out window / Split pane** — Drag a session outside the window → own window (PopoutDrag.swift); drag a session onto a session view → split (SessionDetailView.swift:92-117). Also "Open in a New Window" menu and palette "Open in a Popout Window".
- `U` **Finish setup (onboarding remainder)** — Count of actionable onboarding steps (11 of 13) not completed/skipped; parked in the sidebar (OnboardingState.swift:47-52, 87-89). *Overlaps:* Settings
- `U` **Pending CLI updates badge** — Count of agent CLIs with a newer version (SettingsStore.swift:563-565) shown as a red capsule on the Settings rail button. *Overlaps:* Attention bell badge
- `U!` **Worktree** — Session may run in a git worktree (worktreePath); launcher strip on dashboard worktree rows creates such sessions with title "terminal @ <name>" (SidebarView.swift:692-702).
- `i` **SidebarRowActions / RowEnvironment / OutlineNode / SidebarStructure** — Internal plumbing: closures the rows cannot perform themselves, environment snapshot per update, reference-identity wrapper, pure id-tree.

### Flows

- **Start a session in a project** (5 steps) — friction: No resting affordance: the strip only exists on hover, and the account chooser is a right-click on a hover-only 22×18 button. The detail empty state has to explain it in words ("Hover a project, pick an agent", SessionDetailView.swift:249) and the dashboard's empty sessions panel points somewhere else ("start an agent from the top right", ProjectDashboardView.swift:425). settings.defaultProvider ("New sessions open with this provider") plays no role here.
- **Start a one-off session (Scratch)** (4 steps) — friction: A project row that appears and disappears by itself, named differently in every entry point ("Scratch" row, "One-off" menu, "scratch folder" palette subtitle), with a third context menu shape. Discoverable only via right-click on empty space or the palette.
- **Group sessions** (5 steps) — friction: Four ways in with different semantics and no shared vocabulary; the disabled folder-plus gives no reason; groups are both a container and a page; group collapse does not persist while project collapse does.
- **Delete sessions / remove project** (4 steps) — friction: "Remove from List" sounds harmless but is the most destructive item in the sidebar (kills every session recording in the project) and is the only destructive one without a dialog.
- **Pause / Hibernate / Wake** (2 steps) — friction: Items are absent rather than disabled (comment at 836-839), so a Gemini/terminal user never learns Hibernate exists; provider capability leaks into which menu items a row has. Menu says "Pause" while status label says "Paused" and orb tooltip says nothing.
- **Pop out / split a session** (3 steps) — friction: Two invisible drag semantics hinted only by a tooltip on the 11pt provider mark (SidebarView.swift:883); cross-project drop and root drop refuse silently (SidebarDrop.swift:88-96).
- **Resume onboarding from the sidebar** (4 steps) — friction: Onboarding debt for 11 configuration steps (CLIs, accounts, working modes, hooks, notifications, capabilities, tools, project, tasks, extensions, palette) is parked in the navigation column.
- **Configure the launcher strip** (3 steps) — friction: The strip's membership is one setting, the default agent another (General), default account per provider a third (Accounts); Installed Agents is a fourth page listing the same providers.
- **First run, no projects** (5 steps) — friction: Five entry points, five labels, two simultaneous empty states; the detail one describes a hover interaction the user cannot see yet.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| sidebarVisible | global | @AppStorage("sidebarVisible") UserDefaults | title bar toggle (SidebarView.swift:499-506), ⌘B (UncoilApp.swift:82-85), divider drag < 120pt (MainWindow.swift:246-249) |  |
| sidebarWidth | global | @AppStorage("sidebarWidth") | divider drag (MainWindow.swift:236-250), max 252 |  |
| collapsedProjects | global | UserDefaults stringArray "collapsedProjects" (SidebarView.swift:634-668) | chevron, context menu Hide/Show Sessions, rail Collapse-all, outline double-click/arrow keys (SidebarOutline.swift:594-609) |  |
| CollapsedGroups (groups and parent sessions) | session | in-memory Set<UUID> (SidebarOutline.swift:4-22) | group chevron, outline expansion |  |
| launcher.order (LauncherPrefs) | global | SettingsStore JSON document, `launcher` (SettingsStore.swift:65,107,807,869) | Settings > Appearance > Quick Launch | yes |
| defaultProvider | global | SettingsStore JSON (SettingsStore.swift:32,83) | Onboarding CLI step (OnboardingIntroSteps.swift:148-162), Settings > General (GeneralSettingsPage.swift:12-25) | yes |
| defaultAccountByProvider | global | SettingsStore JSON | Accounts settings; consumed by launcher click (SidebarView.swift:693) | yes |
| attentionEmphasis | global | SettingsStore JSON, mirrored to AttentionMotion.shared | Settings > Appearance > Theme and Colours (AppearanceSettingsPage.swift:36-53) |  |
| Project.isPinned / sortIndex / iconName / colorHex | project | projects.json (Models.swift:553-560) | context menu Pin/Move Up/Down, drag, Customise sheet |  |
| SessionRecord.isPinned / sortIndex / groupID | session | sessions.json (Models.swift:746-748,772) | hover pin, context menu, drag, batch bar, group page, MCP assign_group |  |
| onboardingCompletedSteps / onboardingVersion | global | SettingsStore JSON (SettingsStore.swift:71,130) | onboarding flow; Settings > About reset |  |
| WindowRegistry scopes (WindowProjects) | window | WindowRegistry.scopes (WindowRegistry.swift:21) | openProject from empty sidebar, New window options |  |

### Visibility gates

- `App/UI/SidebarView.swift:139` — scope.filter(projectStore.projects).isEmpty → emptySidebar overlay (and its "Open one you already have" list when elsewhere non-empty, line 61)
- `App/UI/SidebarView.swift:144` — !selectedSessionIDs.isEmpty → batchActions bar
- `App/UI/Onboarding/OnboardingView.swift:125` — !settings.remainingOnboardingSteps.isEmpty && !settings.shouldPresentOnboarding → "Finish setup" row
- `App/UI/SidebarView.swift:161 / CountBadge.swift:62` — pendingUpdates.count > 0 (settings.pendingCLIUpdates) → red count badge on the Settings rail button and its tooltip wording
- `App/UI/AttentionCenterView.swift:195-207` — store.unreadCount > 0 / store.items.isEmpty → bell vs bell-ringing icon, tint, 6pt dot badge
- `App/UI/SidebarView.swift:603-611` — hovering (project row) → AgentLauncherStrip
- `App/UI/SidebarView.swift:590-592` — hovering || sessionsCollapsed → project collapse chevron opacity and hit-testing
- `App/UI/SidebarView.swift:612-618` — sessionsCollapsed && childCount > 0 && !hovering → collapsed session count on project row
- `App/UI/SidebarView.swift:539` — project.isPinned == true && !project.isScratchWorkspace → PinMark on project row
- `App/UI/SidebarView.swift:537; SidebarOutline.swift:730; ScratchWorkspace.swift:71-75; ProjectStore.swift:116-118` — project.isScratchWorkspace → dim name, special 3-item menu, always-last sort, exclusion from visibleProjects
- `App/Core/SettingsStore.swift:282-284; LauncherPrefs.swift:26-45` — settings.launcherProviders (LauncherPrefs.resolved(prefs, installed:)) → which buttons the strip shows; which One-off items the empty-area menu (SidebarOutline.swift:882) and palette (PaletteModel.swift:523) show
- `App/UI/SidebarView.swift:681-682` — provider.isAgent && accounts(for: provider).count > 1 → account context menu on a launcher button
- `App/UI/SidebarView.swift:862; SidebarOutline.swift:461` — showsSelectionControl (= environment.isMultiSelecting) → checkbox column on every session row (full reload, SidebarOutline.swift:49)
- `App/UI/SidebarView.swift:874; SidebarOutline.swift:457` — isChild (structure.isChild(sessionID:)) → corner-down-right glyph
- `App/UI/SidebarView.swift:889` — record.isPinned == true || hovering → PinButton on session row
- `App/UI/SidebarView.swift:881,885` — status == .terminated → provider mark opacity .45, title textDim
- `App/UI/SidebarView.swift:908-937, 848-854` — wantsAttention && pulsing / attentionMotion.animates → colour wash, pulsing border, animation
- `App/UI/AppKit/SidebarOutline.swift:806` — record.groupID != nil → "Remove from Group" menu item
- `App/UI/AppKit/SidebarOutline.swift:841-863; SessionSleep.swift:59-82` — SessionSleep.canWake / canSuspend / canHibernate(status, provider.resumesConversation, providerSessionID) → Wake / Pause / Hibernate menu items (absent, not disabled)
- `App/UI/AppKit/SidebarOutline.swift:826` — record.providerSessionID non-empty → "Copy the Provider Session ID"
- `App/UI/SidebarView.swift:315` — selectedProjectIDs.count != 1 → batch "Group the selected" disabled
- `App/UI/SidebarView.swift:575` — hasChildren (sessions or groups exist) → chevron slot content
- `App/UI/MainWindow.swift:275-279` — !onboarding.isPresenting → TitlebarControls (sidebar toggle + palette button)
- `App/UI/AppKit/SidebarOutline.swift:707-716; PopoutDrag.swift:12-19` — ids.count == 1 && operation == [] && ended outside window frame → pop-out on drag
- `App/UI/AppKit/SidebarDrop.swift:82-102` — owners.count == 1 && parent matches owner → session drop accepted vs silently refused

### Open questions

- Is the Group page (SessionGroupView) actually used, or is a group meant to be a folding container only? The page carries a prompt box and delete, which duplicates the batch bar.
- Is there any intended lifecycle for closed sessions in the sidebar (auto-archive, retention), or is manual delete the only exit? No prune path was found in ProjectStore.
- Should child sessions (sub-agents) really override group membership, or should the tree show groups and mark parentage differently? SidebarStructure.swift:60-63 chose the former without a product statement.
- Which of the three defaults (defaultProvider, launcher.order, defaultAccountByProvider) is meant to win for a plain "new session" — GeneralSettingsPage says defaultProvider, the sidebar says launcher.order.
- Are the multi-window scope concepts ("No projects in this window", "Open one you already have") meant to be visible to every user, or only when a second window exists?
- Is the intent for the sidebar to be the notification surface (pulse + bell + gear badge), or should the menu bar monitor / attention centre own that entirely?

---

## Project screen ("dashboard") and project lifecycle: header, area tabs, General page, add-project flow, customise sheet, blueprints, scratch workspace

A "project" in Uncoil is a folder the user pointed the app at (App/Core/Models.swift:548-584: id, name, rootPath, icon, colour, pin, sort index, and an isScratch flag). Clicking it opens ProjectDashboardView, whose header shows icon, name, a clickable branch switcher, the path, a row of area tabs (General, Tasks, Run, Tests, Issues) and an open-in-editor control. The General page stacks up to eight panels: a TODO.md offer card, a "Set up" panel offering the areas the project lacks, Sessions (with an "Organise" AI action), Closed Sessions, Worktrees (with an inline create field and hover launchers), Git (status + commits), Pull Requests (GitHub), and a Files tree. Which tabs exist is decided per visit by ProjectPageStore, which runs a TODO scan, three git subprocesses, two config-file reads and a GitHub request and folds the result into a four-flag ProjectAreaFacts. Adding a project goes NSOpenPanel -> the project is persisted immediately -> a three-page NewProjectSheet (identity, blueprint chooser, per-agent MCP/skills matrix) whose every field has a default; onboarding and the "Create a Test Workspace" command add projects without that sheet. Later configuration is split between a Customise sheet (Identity | MCP & Skills), Settings > Notifications > Per Project, Settings > Agents > Blueprints, repo-owned .uncoil/run.json and tests.json, and UserDefaults. "Scratch" is a hidden-then-appearing project Uncoil owns for one-off sessions; it is special-cased in the sidebar but gets the full project dashboard, including offers to set up runs, tests and issues for Uncoil's own data folder.

### Findings

#### [CRITICAL] PRJ-01 — The project 'General' page is a git dashboard, a setup wizard, a session list and a file browser at once

*Category:* concept-overload

- `App/UI/ProjectDashboardView.swift:179` — private var overviewContent: some View { … TodoHintCard … ProjectAreaOffers … sessionsPanel … historyPanel … worktreesPanel … gitPanel … pullRequestsPanel … filesPanel
- `App/UI/ProjectDashboardView.swift:269` — TextField("New worktree name (isolated task branch)", text: $newWorktreeName)
- `App/UI/ProjectDashboardView.swift:519` — Text(file.status) // raw porcelain codes "M", "MM", "A", "D", "??" (statusColor at 566-574)
- `App/UI/ProjectDashboardView.swift:338` — BranchBadge(… onSwitched: { branch in pages.invalidate(project.id) … announceSwitch(to: branch) }
- `App/UI/ProjectDashboardView.swift:413` — PanelAction(iconName: "sparkles", title: String(localized: "Organise"), … action: onOrganizeSessions)
- `App/UI/AppKit/FileTreeOutline.swift:232` — guard node.payload.isDirectory else { NSWorkspace.shared.activateFileViewerSelecting([node.payload.url]); return }

**Why it matters:** The everyday question on a project's home ('what are my agents doing here, and how do I start one') competes with git plumbing (worktree creation, branch checkout with an agent-busy confirmation, porcelain codes), setup offers, an AI 'Organise' action, and a file tree whose only action is Finder reveal. Every new capability (Issues, Tests, Run) so far has added either a tab or another panel/offer to this page, so the page compounds with each feature. Sessions — the one panel about agents — has no launcher; the only launchers on the screen are hidden behind hovering a worktree row.

**Direction:** Separate 'home' (sessions, one launcher, one next-step) from 'repository' (branch, worktrees, changes, PRs, files) and from 'setup'.

#### [CRITICAL] PRJ-02 — ProjectAreaFacts is the seed of a capability registry but lives as a per-screen snapshot, and each new area must be threaded through five places

*Category:* coupling

- `App/Core/ProjectAreaAvailability.swift:80` — struct ProjectAreaFacts: Equatable { var hasTaskSources = false; var hasRunConfigurations = false; var hasTestSuites = false; var hasGitHubRepository = false }
- `App/Core/ProjectAreaAvailability.swift:15` — enum ProjectArea … var title … var iconName … var offerTitle … var offerDetail … var offerIsActionable
- `App/Core/ProjectPageStore.swift:108` — let (git, worktrees, remote, hasGitHub, runs, tests) = await Task.detached … GitHubRepoDiscovery.hasRepository … !RunConfigFile.load(…).configurations.isEmpty, !TestConfigFile.load(…).suites.isEmpty
- `App/UI/ProjectAreaOffers.swift:81` — switch offer { case .run: … RunDetection.detect … case .tests: … TestDetection.detect … case .overview, .tasks, .issues: added = 0 }
- `App/UI/ProjectDashboardView.swift:56` — if area == .tasks, hasTaskSources { ProjectTasksView } else if area == .run { ProjectRunView } else if area == .tests { ProjectTestsView } else if area == .issues { ProjectIssuesView } else { overviewContent }
- `App/UI/ProjectRunView.swift:191` — let configurations = RunConfigFile.load(projectRoot: project.rootURL).configurations // session header re-reads the file instead of asking the facts
- `App/Core/PaletteModel.swift:350` — items.append(PaletteItem(id: "cmd.worktree.\(project.id)", title: … "Create Worktree… [\(project.name)]" … )) // offered for every project, git or not

**Why it matters:** Availability is computed only when the dashboard refreshes and is consumed only by the dashboard; the session header, the palette and onboarding each re-derive their own answer (file read, .git exists, nothing). Adding an area means editing the enum (5 computed properties), the facts struct, the refresh, the offers switch and the body switch; adding a place that needs to know 'does this project have X' means another ad-hoc read. There is no single registry of project capabilities, so visibility rules are scattered across views.

**Direction:** Promote facts into a project-level capability model (detected + cached + observable) that tabs, offers, palette and session header all consult.

#### [HIGH] PRJ-03 — Four surfaces offer to 'set up' the same features with four different labels and three copies of the detection code

*Category:* duplicate-concept

- `App/UI/ProjectAreaOffers.swift:64` — Button { setUp(offer) } label: { Text("Look") }
- `App/UI/ProjectRunView.swift:83` — Text(detecting ? "Scanning…" : "Detect")
- `App/UI/ProjectTestsView.swift:100` — Button(action: detect) { Text("Look for tests") }
- `App/UI/ProjectDashboardView.swift:633` — Button(String(localized: "Create a TODO.md")) { create() }
- `App/UI/Onboarding/OnboardingProjectSteps.swift:205` — Button(String(localized: "Create a TODO.md")) { createTodo() }
- `App/UI/ProjectRunView.swift:113` — private func detect() { … RunDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root)) … RunDetection.merge(existing: existing, suggestions: suggestions, replacingDetected: false)
- `App/UI/ProjectAreaOffers.swift:84` — let found = await Task.detached(priority: .userInitiated) { RunDetection.detect(fileSystem: DiskRunDetectionFileSystem(root: root)) }.value; let merged = RunDetection.merge(existing: existing, suggestions: found, replaci
- `App/UI/ProjectTasksView.swift:480` — Text("No TODO.md found in this project") … Text("Add a TODO.md to the root or a subfolder and it shows up here.") // no create button, unlike the dashboard card

**Why it matters:** The in-tab empty states are reachable only while a tab is stale (config deleted, area still selected until the 90 s refresh), so users meet two different 'nothing here' designs for the same feature depending on timing. TODO.md has its own card with a permanent dismissal; Run/Tests offers cannot be dismissed; Issues is an undismissable non-actionable row. Same action, different words, different affordances.

**Direction:** One offer component and one detection entry point per capability, used by General, the tab's empty state and onboarding alike.

#### [HIGH] PRJ-04 — The new-project sheet gates project creation on three questions that all have defaults, and is skipped by two of the three add paths

*Category:* onboarding

- `App/UI/NewProjectSheet.swift:249` — /// The folder was added the moment it was chosen, so a button that says "Create" has to be able to un-create
- `App/UI/NewProjectSheet.swift:254` — private func cancel() { if projectStore.sessions(for: project.id).isEmpty { projectStore.removeProject(project) } dismiss() }
- `App/UI/BlueprintCards.swift:78` — SheetOptionRow(title: String(localized: "Default"), detail: String(localized: "Add the folder and nothing else."), isSelected: selected == nil)
- `App/UI/NewProjectSheet.swift:213` — Text(excludedCount == 0 ? String(localized: "Everything this project's agents already have") : …)
- `App/UI/Onboarding/OnboardingProjectSteps.swift:147` — projectStore.addProject(at: url) // no NewProjectSheet
- `App/UI/MainWindow.swift:373` — case .createTestWorkspace: … projectStore.addProject(at: url) … selection = .project(project.id) // no NewProjectSheet
- `App/UI/Onboarding/OnboardingProjectSteps.swift:97` — OnboardingCard(symbol: "chevron.left.forwardslash.chevron.right", title: String(localized: "Editor") … settings.preferredEditor

**Why it matters:** Name (folder name), blueprint (none) and extension bindings (all on) are all fine untouched, so the sheet is a modal that most people will dismiss with Create — yet the page is titled 'How should this project start?' and demands a decision. Because onboarding and the test-workspace command skip it, 'asked once, right after a folder becomes a project' (file header, line 3) is not actually true; the questions depend on which button added the folder. Onboarding meanwhile asks a global editor preference inside 'Add your first project'.

**Direction:** Add the folder with no sheet; surface 'start from a blueprint' and 'customise' as first actions on the empty project home.

#### [HIGH] PRJ-05 — Blueprint, Session Preset, template and workspace are four overlapping words for 'a stored prompt/scaffold plus how to launch it'

*Category:* terminology

- `App/Core/SessionPreset.swift:3` — /// A reusable template describing how a child (or standalone) agent session should be launched: which provider, extra CLI arguments, an optional initial-prompt template, and the control-plane capabilities
- `App/Core/Blueprint.swift:3` — /// A named prompt that sets a project up the way you always set projects up.
- `App/UI/Settings/SettingsView.swift:80` — case presets         case blueprints // adjacent panes under Agents: 'Session Presets' (136) and 'Blueprints' (137)
- `App/UI/TaskDispatchSheet.swift:291` — pickerRow(String(localized: "Preset")) { … Text("No preset").tag(String?.none)
- `App/Tasks/TodoStarter.swift:16` — static let template = """ # TODO …
- `App/Core/PaletteModel.swift:324` — PaletteItem(id: "cmd.testWorkspace", title: String(localized: "Create a Test Workspace"), iconName: "flask" …)
- `App/Core/ScratchWorkspace.swift:15` — static let name = String(localized: "Scratch") // Test Workspace and Scratch workspace both use the flask icon (ProjectStore.swift:69)
- `docs/current/extensions/BLUEPRINTS.md:8` — ## Uncoil creates nothing … The app does not create the directories itself. // while TestWorkspaceService does scaffold a tree on disk

**Why it matters:** A user meets 'Session Presets' and 'Blueprints' as sibling settings pages with no statement of the difference; presets carry an initialPromptTemplate and blueprints carry a prompt; presets are picked when dispatching a task, blueprints when adding a project. 'Workspace' names both a scratch folder and a test scaffold, both with a flask icon. Internal names (preset, blueprint, draft, Mark) are the user-facing names.

**Direction:** Decide on one user-facing noun for 'stored instructions for an agent' with a scope attribute (project start vs child session), and stop using 'workspace' for two things.

#### [HIGH] PRJ-06 — Per-project MCP/skill scoping is a per-agent matrix whose tabs come from an Appearance setting, with provider quirks explained inline and a third editor that lacks the agent axis

*Category:* agent-leak

- `App/UI/ProjectExtensionPicker.swift:323` — static func tabAgents(for settings: SettingsStore) -> [ExtensionAgentID] { settings.launcherProviders.filter { $0 != .terminal }.compactMap(\.extensionAgent) }
- `App/UI/Settings/SettingsView.swift:138` — case .launcher: String(localized: "Quick Launch") // category .appearance (line 112)
- `App/UI/ProjectExtensionPicker.swift:158` — note(String(localized: "Skills are not scoped for \(names) — the CLI has no per-session skill selection, so it loads all of them. MCP servers are scoped."))
- `App/UI/ProjectExtensionPicker.swift:287` — Text(isOn ? "off for \(names)" : "on for \(names)")
- `App/UI/ExtensionsView.swift:2207` — SectionCard(title: String(localized: "Extension → project"), detail: String(localized: "With no record an extension is global; the project record, being the most specific, wins."))
- `App/UI/ExtensionsView.swift:2228` — registry.setProjectBinding(ProjectBinding(extensionID: package.id, projectID: project.id, isEnabled: !(binding?.isEnabled ?? true))) // no agent
- `App/UI/ProjectCustomizeSheet.swift:19` — case .extensions: String(localized: "MCP & Skills") // NewProjectSheet calls the same page "MCP Servers & Skills" (NewProjectSheet.swift:135)

**Why it matters:** A project-level decision ('this project should not load the figma server') is presented as an N+1 tab matrix keyed by which agents happen to be in Quick Launch, with per-CLI caveats in the body. The same records are editable from three places under two names, and the Extensions window path writes agent-less bindings that the per-agent tabs then show as inherited — the user cannot tell from either surface which one is authoritative.

**Direction:** One project-level list with an optional 'except for <agent>' affordance; provider limitations belong in the agent's own pane, not in every project sheet.

#### [HIGH] PRJ-07 — Scratch is a Project in the model, so it gets the full project dashboard — offers, TODO card, git panel and file tree for Uncoil's own data folder

*Category:* agent-leak

- `App/Core/ScratchWorkspace.swift:8` — /// Rather than inventing a second kind of session that every part of the app would have to know about, one-off sessions belong to a project like any other. It is just a project Uncoil owns.
- `App/UI/MainWindow.swift:545` — case .project(let id): if let project = projectStore.projects.first(where: { $0.id == id }) { ProjectDashboardView(project: project, …) }
- `App/UI/ProjectDashboardView.swift:183` — if !hasTaskSources, !todoHintDismissed { TodoHintCard(project: project, …) } // no isScratchWorkspace check anywhere in this file
- `App/Core/ProjectAreaAvailability.swift:49` — case .run: String(localized: "Start this project from Uncoil") … case .issues: String(localized: "Show this repository's GitHub issues")
- `App/UI/ProjectDashboardView.swift:501` — Text("This folder is not a git repository.")
- `App/Core/PaletteModel.swift:340` — for project in ctx.projects { … "New Session: … [\(project.name)]" … "Create Worktree… [\(project.name)]" … "Apply Blueprint… [\(project.name)]" } // ctx.projects, not visibleProjects (inferred: Scratch gets these too)
- `App/Core/PaletteModel.swift:316` — subtitle: String(localized: "In Uncoil's scratch folder, outside every project") // 'One-off session' in palette/menus vs 'Scratch' / 'Close Scratch' in the sidebar

**Why it matters:** The model shortcut that keeps plumbing simple leaks into every project surface that does not check the flag: the sidebar special-cases Scratch (dim, no pin, reduced menu, sorted last) but the dashboard invites the user to hand out work from a TODO.md in it, look for a dev server in it, and browse Uncoil's README.md. The concept also has two names ('One-off session' vs 'Scratch') and a row that appears and disappears on its own.

**Direction:** Give one-off sessions a dedicated, minimal home (or gate every project surface on a project kind), and pick one name.

#### [MEDIUM] PRJ-08 — 'Project type' is not modelled; git-ness is decided three different ways and a 'container of checkouts' is half-supported

*Category:* duplicate-concept

- `App/Core/GitService.swift:27` — guard run(["-C", repoPath, "rev-parse", "--git-dir"]) != nil else { return Snapshot() }
- `App/UI/Onboarding/OnboardingProjectSteps.swift:40` — private var isGitRepository: Bool { … FileManager.default.fileExists(atPath: path + "/.git") }
- `App/Core/ProjectPageStore.swift:113` — // Not the root's own remote: a project folder is often a container holding several checkouts, and its own directory is not a repository at all. Their issues are the project's issues, so the tab has to exist for them.
- `App/Core/GitHubIssues.swift:225` — /// Slugs of every GitHub repo at the project root or one level under it
- `App/UI/ProjectDashboardView.swift:207` — if git.isRepo { worktreesPanel } // Git, Worktrees, PRs and the branch badge speak only for the root
- `App/Core/Models.swift:548` — struct Project: Identifiable, Codable, Equatable { let id; var name; var rootPath; var createdAt; var iconName; var colorHex; var isPinned; var sortIndex; var isScratch }

**Why it matters:** A folder holding several repos gets an Issues tab (one level down) but a Git panel saying 'not a git repository', no PR panel and no branch; onboarding may call the same folder 'Not a git repository' while the dashboard finds issues in it. Because Project has no kind (single repo / container / scratch / plain folder), every surface improvises its own test.

**Direction:** Model project kind once (detected, cached on the project) and let panels read it.

#### [MEDIUM] PRJ-09 — Configuration about one project is spread across six stores and five UI locations, none of which is the project screen

*Category:* settings-sprawl

- `App/UI/ProjectCustomizeSheet.swift:3` — /// Everything a project is configured with: its identity — name, icon and accent colour — and the MCP servers and skills its sessions are handed.
- `App/UI/Settings/NotificationSettingsPages.swift:425` — title: String(localized: "Per Project"), subtitle: String(localized: "You can silence a project completely, or change only its priority and sound.")
- `App/Tasks/TodoStarter.swift:55` — private static let key = "tasks.todoHintDismissedProjects" // UserDefaults
- `App/Core/ProjectPageStore.swift:118` — !RunConfigFile.load(projectRoot: rootURL).configurations.isEmpty, !TestConfigFile.load(projectRoot: rootURL).suites.isEmpty // repo-owned .uncoil/*.json
- `App/UI/EditorOpenControl.swift:46` — settings.preferredEditor = candidate; settings.save(); open(with: candidate) // a global preference changed from a project header menu
- `App/UI/AppKit/SidebarOutline.swift:765` — add(to: menu, title: String(localized: "Customise…")) // the only route to the customise sheet is a right-click

**Why it matters:** 'Everything a project is configured with' (the sheet's own claim) omits notifications, run/test config, the TODO offer state and collapsed state. The project screen, which is where a user looks for 'this project', has no settings affordance at all; the header's only configuration-like control silently rewrites a global.

**Direction:** A single 'project settings' surface reachable from the project screen, listing every per-project knob wherever it is stored.

#### [MEDIUM] PRJ-10 — Worktree has four entry points with inconsistent behaviour and git vocabulary in the UI

*Category:* navigation

- `App/UI/MainWindow.swift:405` — case .createWorktree(let projectID): selection = .project(projectID) // palette 'Create Worktree…' only navigates
- `App/UI/ProjectDashboardView.swift:257` — PanelHeading(title: String(localized: "Worktrees"), count: max(0, worktrees.count - 1))
- `App/UI/BranchBadge.swift:13` — return tree == root ? String(localized: "main copy") : URL(fileURLWithPath: path).lastPathComponent
- `App/UI/ProjectDashboardView.swift:836` — Text(worktree.branch ?? "detached")
- `App/UI/TaskDispatchSheet.swift:64` — return "\(project.rootPath)/.uncoil-worktrees/\(name)" // a second worktree creator with its own naming
- `App/ControlPlane/HelpRegistry.swift:84` — ActionDoc(action: "create_worktree", summary: "Create a `.uncoil-worktrees/<name>` worktree."

**Why it matters:** A git concept is offered on the project home as a text field with a parenthetical explanation, in the palette as a command that does not do what it says, in the task dispatcher as a checkbox, and to agents as a grant. 'main copy', 'detached', 'Worktree clean' are git-speak on a page meant for agent work.

**Direction:** One worktree action with one name, reachable from the palette and the screen the same way; hide git vocabulary unless the user opens the repository view.

#### [MEDIUM] PRJ-11 — Blueprints are authored in Settings but consumed at project creation, and which agent runs them is an invisible global that other project actions ignore

*Category:* discoverability

- `App/UI/BlueprintCards.swift:154` — Text("No blueprints yet. Settings › Agents › Blueprints is where they are written.")
- `App/UI/BlueprintCards.swift:107` — if store.blueprints.isEmpty, let onWriteFirst { Button(action: onWriteFirst) { … Text("Write a blueprint") } } // offered inline only when there are none
- `App/UI/BlueprintCards.swift:23` — let provider = settings.defaultProvider // A blueprint says what to do, not who should do it
- `App/UI/MainWindow.swift:627` — provider: .claude, accountID: settings.defaultAccount(for: .claude)?.id, title: String(localized: "claude: organise sessions")
- `App/UI/Settings/BlueprintsSettingsPage.swift:141` — let record = projectStore.createScratchSession(provider: provider, …) // writing a blueprint spawns a Scratch project

**Why it matters:** The user learns about blueprints from a modal at add-project time, is sent to Settings to write one, and comes back; running one uses the default provider while 'Organise' on the same project hard-codes Claude, so 'which agent does project-level work' has no consistent answer.

**Direction:** Author and apply blueprints from the same project-facing place; make the acting agent visible and consistent across project actions.

#### [MEDIUM] PRJ-12 — The Sessions panel's empty state points to a launcher that is not on the screen

*Category:* empty-state

- `App/UI/ProjectDashboardView.swift:425` — Text("No sessions yet — start an agent from the top right.")
- `App/UI/SidebarView.swift:621` — AgentLauncherStrip(project: project, selection: $selection) // shown only while hovering the sidebar project row
- `App/UI/ProjectDashboardView.swift:841` — if hovering { AgentLauncherStrip(project: project, worktreePath: …) } // only on worktree rows, only for git repos

**Why it matters:** A brand-new project (the moment the empty state shows) has no visible way to start an agent from its own page; the instruction refers to a hover control in another column. For a non-git folder there is no launcher on the page at all.

**Direction:** Put one explicit launcher on the project home.

#### [MEDIUM] PRJ-13 — Header responsiveness and area routing are hand-rolled in the view with magic widths and string-typed areas

*Category:* visibility-logic

- `App/UI/ProjectDashboardView.swift:46` — private var tabsAreIconOnly: Bool { headerWidth < 720 }
- `App/UI/ProjectDashboardView.swift:324` — HStack(alignment: .center, spacing: headerWidth < 620 ? 8 : 12)
- `App/UI/ProjectDashboardView.swift:358` — if headerWidth >= 560 { Text(displayPath)
- `App/Core/ProjectPageStore.swift:170` — func request(_ area: String, for projectID: UUID) { pending[projectID] = area }
- `App/UI/ProjectRunView.swift:220` — ProjectAreaRoute.shared.request("run", for: project.id)
- `App/Core/ProjectAreaAvailability.swift:3` — /// Every area used to be offered on every project, so a folder with no TODO.md, no run configuration and no GitHub remote still showed five tabs … the header's minimum width grew past the window's

**Why it matters:** Tab visibility was introduced partly to fix a layout overflow (the file header says so), which ties feature discovery to header width; three thresholds and a string route make it hard to reason about what a project screen shows in a given window.

**Direction:** Keep availability and layout separate; route with the enum.

#### [LOW] PRJ-14 — Internal names shown to users: 'draft', 'Mark', 'main copy', porcelain codes, 'Identity'

*Category:* terminology

- `App/UI/BlueprintCards.swift:95` — badge: blueprint.needsReview ? String(localized: "draft") : nil
- `App/UI/NewProjectSheet.swift:113` — title: String(localized: "Name and Mark")
- `App/UI/Settings/BlueprintsSettingsPage.swift:307` — Text("Mark")
- `App/UI/ProjectCustomizeSheet.swift:18` — case .identity: String(localized: "Identity")
- `App/UI/ProjectDashboardView.swift:509` — Text("Worktree clean")

**Why it matters:** The same thing (icon + colour) is 'Mark' in one sheet and 'Identity' in another; git status abbreviations and 'main copy' assume git literacy on the agent home page.

**Direction:** Pick plain words and use them in both sheets.

#### [LOW] PRJ-15 — 'Remove from List' deletes every session record without confirmation while deleting one session asks

*Category:* coupling

- `App/UI/AppKit/SidebarOutline.swift:779` — add(to: menu, title: String(localized: "Remove from List")) { environment.projectStore.removeProject(project) }
- `App/Core/ProjectStore.swift:223` — func removeProject(_ project: Project) { projects.removeAll … sessions.removeAll { $0.projectID == project.id } sessionGroups.removeAll …
- `App/UI/SidebarView.swift:239` — confirmationDialog(deletingSession.map { "Delete the \"\($0.displayTitle)\" session?" } … Text("The running process is closed; the recording cannot be recovered.")

**Why it matters:** The label promises a list edit; the store performs a cascade delete. Inconsistent with the per-session and Scratch-close confirmations.

**Direction:** Confirm when sessions exist, or really only remove from the list.

#### [LOW] PRJ-16 — The Issues offer is a permanent, non-actionable row on every non-GitHub folder

*Category:* empty-state

- `App/Core/ProjectAreaAvailability.swift:65` — String(localized: "This folder has no GitHub remote. Add one, and the open issues of every repository in it show up here.")
- `App/Core/ProjectAreaAvailability.swift:71` — var offerIsActionable: Bool { switch self { case .tasks, .run, .tests: true; case .overview, .issues: false } }
- `App/UI/ProjectAreaOffers.swift:63` — } else if offer.offerIsActionable { Button { setUp(offer) } label: { Text("Look") } } // Issues row has no button and no dismissal

**Why it matters:** Unlike the TODO card (dismissable), this row cannot be closed and cannot be acted on, so a plain folder or Scratch carries it forever under 'Set up'.

**Direction:** Do not offer what the app cannot do; explain it once where Issues is introduced.

#### [LOW] PRJ-17 — Every visible project screen polls git every 3 seconds for the branch menu and re-reads run.json on each session-header render

*Category:* efficiency

- `App/UI/BranchBadge.swift:65` — .task(id: repoPath) { while !Task.isCancelled { await load(); try? await Task.sleep(nanoseconds: 3 * NSEC_PER_SEC) } }
- `App/Core/GitService.swift:210` — for worktree in worktrees(repoPath: repoPath) { // branches() also runs git worktree list each poll
- `App/UI/ProjectRunView.swift:186` — // Read the file on render rather than caching in @State … The file is tiny and header renders are rare

**Why it matters:** Symptom of PRJ-02: with no shared project state, each control fetches for itself.

**Direction:** Feed both from the same project snapshot.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Project header bar | panel | `App/UI/ProjectDashboardView.swift` | Sidebar project row click; MainWindow.routedDetail .project (App/UI/MainWindow.swift:545-552); palette openProject |
| Area tab row | tab | `App/UI/ProjectDashboardView.swift` | header |
| General page (overview) | screen | `App/UI/ProjectDashboardView.swift` | default tab |
| TODO.md offer card | banner | `App/UI/ProjectDashboardView.swift` | General page when !hasTaskSources && !todoHintDismissed (line 183) |
| Set up panel (area offers) | panel | `App/UI/ProjectAreaOffers.swift` | General page (ProjectDashboardView.swift:199-202) |
| Sessions panel | panel | `App/UI/ProjectDashboardView.swift` | General page |
| Closed Sessions panel | panel | `App/UI/ProjectDashboardView.swift` | General page when sessionHistory non-empty (line 204) |
| Worktrees panel | panel | `App/UI/ProjectDashboardView.swift` | General page when git.isRepo (line 207) |
| Git panel | panel | `App/UI/ProjectDashboardView.swift` | General page |
| Pull Requests panel | panel | `App/UI/ProjectDashboardView.swift` | General page when git.isRepo (line 213) |
| Files panel | panel | `App/UI/AppKit/FileTreeOutline.swift` | General page (ProjectDashboardView.swift:578-585) |
| Branch menu | menu | `App/UI/BranchBadge.swift` | project header branch text |
| New project sheet — setup page | sheet | `App/UI/NewProjectSheet.swift` | MainWindow folderPicker completion (App/UI/MainWindow.swift:279-297) |
| New project sheet — identity page | sheet | `App/UI/NewProjectSheet.swift` | setup page identity row |
| New project sheet — extensions page | sheet | `App/UI/NewProjectSheet.swift` | setup page extensions row |
| Apply Blueprint sheet | sheet | `App/UI/BlueprintCards.swift` | sidebar project context menu 'Apply Blueprint…' (App/UI/AppKit/SidebarOutline.swift:768); palette 'Apply Blueprint… [project]' (App/Core/PaletteModel.swift:356-361) |
| Customise sheet | sheet | `App/UI/ProjectCustomizeSheet.swift` | sidebar project context menu 'Customise…' (SidebarOutline.swift:765) |
| Folder picker | sheet | `App/UI/FolderPicker.swift` | sidebar + rail button (App/UI/SidebarView.swift:59,161); empty detail 'Add Project' (App/UI/SessionDetailView.swift:255); palette 'Add a New Project' (PaletteModel.swift:322); sidebar empty-area menu  |
| Sidebar project context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click project row |
| Sidebar scratch context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click Scratch row |
| Sidebar empty-area menu | menu | `App/UI/AppKit/SidebarOutline.swift` | right-click below rows |
| Settings > Agents > Blueprints | screen | `App/UI/Settings/BlueprintsSettingsPage.swift` | Settings > Agents > Blueprints (App/UI/Settings/SettingsView.swift:81,137,334) |
| Blueprint editor sheet | sheet | `App/UI/Settings/BlueprintsSettingsPage.swift` | Blueprints page Edit/New; NewProjectSheet 'Write a blueprint' (NewProjectSheet.swift:67-69,84); ApplyBlueprintSheet Edit… |
| Onboarding — Add your first project | screen | `App/UI/Onboarding/OnboardingProjectSteps.swift` | first run / -route onboarding |
| Onboarding — Tasks step | screen | `App/UI/Onboarding/OnboardingProjectSteps.swift` | onboarding after project step |
| Command palette project commands | menu | `App/Core/PaletteModel.swift` | ⌘K |
| Scratch project row | row | `App/UI/SidebarView.swift` | opening any one-off session |
| In-tab empty states (Run / Tests / Tasks) | empty-state | `App/UI/ProjectRunView.swift` | area tab while stale |

### Concepts

- `U!` **Project** — A folder the user added; persisted record with name, path, icon, colour, pin, sort index, isScratch (App/Core/Models.swift:548-584). Has no 'type' or 'capabilities' field; everything about what it can do is re-detected per screen visit. *Overlaps:* Scratch workspace, Test Workspace, Worktree
- `U` **Area (ProjectArea)** — One of General/Tasks/Run/Tests/Issues; an enum that also carries tab title, icon, offer title, offer detail and whether the offer is actionable (App/Core/ProjectAreaAvailability.swift:15-77). *Overlaps:* ProjectAreaFacts
- `i` **ProjectAreaFacts** — Four booleans (hasTaskSources, hasRunConfigurations, hasTestSuites, hasGitHubRepository) computed in ProjectPageStore.refresh and stored in the page snapshot (App/Core/ProjectAreaAvailability.swift:80-85; App/Core/ProjectPageStore.swift:124-133). Only consumer: the dashboard's tab row and offers. *Overlaps:* GitService.Snapshot.isRepo, RunDefaultControl's own file read (ProjectRunView.swift:191-193)
- `U` **Offer** — A row on General for an area the project lacks, with a 'Look' button that runs the same detection as the area's own screen (App/UI/ProjectAreaOffers.swift:71-111). *Overlaps:* TodoHintCard, in-tab empty states, onboarding Tasks step
- `U!` **Worktree** — A git worktree; Uncoil creates them under <repo>/.uncoil-worktrees/<slug> on branch uncoil/<slug> (App/Core/GitService.swift:259-295). The root checkout is named 'main copy' in the UI (App/UI/BranchBadge.swift:9-17). Sessions carry an optional worktreePath (Models.swift:751, 803-805). *Overlaps:* Branch, Project
- `U!` **Branch** — Current git branch shown under the project name; switching is a real checkout with a busy-agent confirmation and a note typed into running sessions (ProjectDashboardView.swift:338-357, 479-488). *Overlaps:* Worktree
- `U!` **Blueprint** — A named markdown prompt (YAML front matter) in ~/.uncoil/blueprints, applied by opening a session in the default provider and delivering the prompt; flags startsImmediately and needsReview ('draft') (App/Core/Blueprint.swift:15-50; App/UI/BlueprintCards.swift:11-42). *Overlaps:* Session Preset, TodoStarter.template, Test Workspace
- `U!` **Session Preset** — 'A reusable template describing how a child (or standalone) agent session should be launched: provider, extra CLI arguments, an optional initial-prompt template, and the control-plane capabilities' (App/Core/SessionPreset.swift:3-9). Listed in Settings > Agents > Session Presets directly above Blueprints (SettingsView.swift:80-81) and picked in the task dispatch sheet ('Preset', TaskDispatchSheet.swift:291-299). *Overlaps:* Blueprint (both are a stored prompt plus launch instructions for an agent)
- `U!` **Draft (needsReview)** — A blueprint an agent wrote or the user imported; shown as a 'draft' badge and never starts on its own until saved from the editor (Blueprint.swift:27-32; BlueprintCards.swift:95; BlueprintsSettingsPage.swift:89-90,98-102).
- `U!` **Mark (icon + colour)** — The UI's word for a project's or blueprint's icon and accent colour: 'Name and Mark' page (NewProjectSheet.swift:113), 'Mark' button/page in the blueprint editor (BlueprintsSettingsPage.swift:246,307). *Overlaps:* Identity tab of the Customise sheet (same fields, different label)
- `U!` **Identity** — Customise sheet tab holding name, read-only location, icon/colour (ProjectCustomizeSheet.swift:16-22, 92-118). *Overlaps:* Mark
- `U` **MCP servers & skills (project bindings)** — Per-project, per-agent allow/deny records (ProjectBinding) edited through ProjectExtensionSelection: an 'All agents' axis plus one axis per Quick Launch agent; silence inherits (App/UI/ProjectExtensionPicker.swift:1-104). *Overlaps:* capabilities / grants
- `U!` **Scratch (workspace) / One-off session** — A project Uncoil owns under its data directory for sessions that belong to no project; created lazily, sorted last, auto-removed when empty (App/Core/ScratchWorkspace.swift:13-25; App/Core/ProjectStore.swift:54-89, 552-577). Called 'Scratch' in the sidebar and 'One-off <Provider> session … In Uncoil's scratch folder' in the palette/menus. *Overlaps:* Project, Test Workspace
- `U!` **Test Workspace** — Palette command 'Create a Test Workspace' that scaffolds a temp git repo with sample projects and adds it as a project without the new-project sheet (App/Core/TestWorkspaceService.swift:24-40; App/UI/MainWindow.swift:373-381). *Overlaps:* Scratch workspace (both named 'workspace', both flask icon), Blueprint (a scaffold Uncoil does create on disk, contradicting 'Uncoil creates nothing')
- `U!` **Session group** — Named grouping of sessions inside a project; created from the project context menu ('New Group…') or by the 'Organise' AI session (Models.swift:586-606; MainWindow.swift:625-647).
- `i` **Capability grant (blueprints.write, worktrees.create)** — Control-plane grant strings stamped on SessionRecord.capabilities (Models.swift:765); the blueprint-authoring session is created with PolicyEngine.defaultGrants + 'blueprints.write' (BlueprintsSettingsPage.swift:145-148). *Overlaps:* Session Preset grantedCapabilities
- `U` **Task source / TODO.md** — A markdown checklist that turns on the Tasks tab; offered by the dashboard card and by onboarding through TodoStarter.template (App/Tasks/TodoStarter.swift:10-47). *Overlaps:* Offer
- `U!` **Run configuration / Test suite** — Entries in repo-owned .uncoil/run.json and .uncoil/tests.json, detected by RunDetection/TestDetection; their existence flips the Run/Tests tabs (ProjectPageStore.swift:118-119). *Overlaps:* Offer
- `U!` **Pinned / Closed Sessions / Move Up-Down** — Sidebar ordering primitives on projects and sessions (ProjectStore.swift:124-206).

### Flows

- **Add a project from the main window** (8 steps) — friction: The project exists before the sheet opens, so 'Create' creates nothing and 'Cancel' deletes. Every field has a default (name = folder, blueprint = none, extensions = all on), so the sheet is three optional questions asked as a gate. The 'MCP servers & skills' row and the identity page are settings, not setup.
- **Add a project during onboarding** (6 steps) — friction: A second add-project flow with different questions than the main-window one; git detection uses a different rule than the dashboard (file exists vs git rev-parse); an app-level editor preference is asked under 'Add your first project'.
- **Open the project screen** (6 steps) — friction: Feature availability is a side effect of a page refresh; nothing else in the app can ask 'does this project have runs?' without re-reading files (RunDefaultControl does exactly that, ProjectRunView.swift:191-193). A tab can vanish mid-use when its config is deleted, and reappear only after the 90 s window.
- **Turn on an area from General ('Set up')** (5 steps) — friction: Same detection code lives in three views (ProjectAreaOffers.setUp, ProjectRunView.detect :113-128, ProjectTestsView.detect) with three different button labels: 'Look', 'Detect', 'Look for tests'. TODO.md is offered by a fourth, differently shaped card.
- **Create a worktree and launch an agent into it** (5 steps) — friction: The only launcher on the project screen is hidden behind a hover on a worktree row that exists only for git repos; the Sessions panel's empty text points 'to the top right' where nothing is (ProjectDashboardView.swift:425). The palette command promises a create and delivers a navigation.
- **Switch branch from the header** (4 steps) — friction: A destructive git operation sits in the title area of the project's home, styled as a line of dim text. Every open project screen polls git for-each-ref + worktree list every 3 s (BranchBadge.swift:65-70).
- **Customise a project later** (4 steps) — friction: Reachable only by right-click; not from the project screen itself. Per-project notifications live in Settings > Notifications > Per Project (NotificationSettingsPages.swift:420-437), and the same bindings can be edited in the Extensions window without the agent axis (ExtensionsView.swift:2207-2250).
- **Apply a blueprint to an existing project** (3 steps) — friction: The agent that runs it is an invisible global default; the sheet subtitle names it but there is no choice. 'Organise' on the same project screen hard-codes .claude instead (MainWindow.swift:625-629).
- **Write a blueprint** (5 steps) — friction: Blueprints are authored in Settings but consumed at add-project time; the new-project sheet only offers 'Write a blueprint' when the list is empty (BlueprintCards.swift:107-128). Writing one with an agent creates a Scratch project as a side effect.
- **Scratch lifecycle** (5 steps) — friction: Two names for one thing ('One-off session' vs 'Scratch'); a project row that appears and vanishes by itself; and a dashboard that offers to 'Start this project from Uncoil' and 'Hand out work from a TODO.md' for Uncoil's own errands folder.
- **Remove a project** (2 steps) — friction: Deleting one session asks ('The running process is closed; the recording cannot be recovered.' SidebarView.swift:239-250); removing a project with ten sessions does not.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| Project name / icon / colour | project | Application Support/Uncoil/projects.json (Project.name, iconName, colorHex) | NewProjectSheet identity page (NewProjectSheet.swift:111-131); Customise sheet Identity tab (ProjectCustomizeSheet.swift:92-118) | yes |
| Project pin / manual order | project | projects.json (isPinned, sortIndex) | sidebar context menu Pin/Move Up/Move Down, drag (SidebarOutline.swift:751-760; ProjectStore.swift:147-206) |  |
| isScratch | project | projects.json (Project.isScratch) | set only by ProjectStore.ensureScratchProject (ProjectStore.swift:67-69) | yes |
| Per-project MCP server / skill bindings (per agent axis) | project | ExtensionRegistry document projectBindings (App/Extensions/ExtensionRegistry.swift:36,107) | NewProjectSheet extensions page; Customise sheet MCP & Skills tab; Extensions window 'Extension → project' (ExtensionsView.swift:2207-2250, agent = nil only) | yes |
| Blueprints | global | ~/.uncoil/blueprints/<slug>.md (BlueprintStore.swift:45-49) | Settings > Agents > Blueprints; BlueprintEditorSheet reachable from NewProjectSheet and ApplyBlueprintSheet |  |
| Blueprint startsImmediately / needsReview | global | front matter of the blueprint file (Blueprint.swift:91-102) | BlueprintEditorSheet toggle (BlueprintsSettingsPage.swift:350-361); needsReview set by save(writtenByAgent:) and import, cleared by editor save |  |
| Run configurations | project | <repo>/.uncoil/run.json (RunConfigFile) | Run tab Detect/New/editor (ProjectRunView.swift:80-128); General 'Set up' Look (ProjectAreaOffers.swift:82-91) | yes |
| Test suites | project | <repo>/.uncoil/tests.json (TestConfigFile) | Tests tab detect (ProjectTestsView.swift:82-89, 92-108); General 'Set up' Look (ProjectAreaOffers.swift:92-101) | yes |
| TODO.md (task source) | project | <repo>/TODO.md or subfolder | TodoHintCard 'Create a TODO.md' (ProjectDashboardView.swift:633,646-658); onboarding Tasks step (OnboardingProjectSteps.swift:205,266-278) | yes |
| TODO hint dismissal | project | UserDefaults 'tasks.todoHintDismissedProjects' (TodoStarter.swift:54-76) | TodoHintCard X / 'Not for this project' |  |
| Collapsed projects (sessions hidden) | project | UserDefaults via CollapsedProjects (SidebarView.swift:657+) | context menu Show/Hide Sessions; row chevron |  |
| Per-project notifications (enabled, priority, sound) | project | settings.json notifications.perProject[projectID] (NotificationSettingsPages.swift:446-450) | Settings > Notifications > Per Project |  |
| GitHub token | account | Keychain 'github-token' (GitHubService.swift:57, 276-330) | Settings > Uncoil > GitHub (IntegrationsSettingsPages.swift:6-15) |  |
| Preferred editor | global | settings.json preferredEditor | Project header EditorOpenControl menu (EditorOpenControl.swift:44-49 mutates the global on pick); onboarding project step (OnboardingProjectSteps.swift:102-105); Settings | yes |
| Quick Launch providers | global | settings.json launcher.order (SettingsStore.swift:282-297) | Settings > Appearance > Quick Launch (LauncherSettingsPage.swift:23) | yes |
| Default provider / default account | global | settings.json | Settings > Agents | yes |
| Worktree location and branch prefix | global | hard-coded '.uncoil-worktrees' and 'uncoil/<slug>' (GitService.swift:268-275) | not editable | yes |
| Page freshness window | global | hard-coded 90 s (ProjectPageStore.swift:11) | not editable | yes |

### Visibility gates

- `App/Core/ProjectAreaAvailability.swift:89-96` — facts.hasTaskSources / hasRunConfigurations / hasTestSuites / hasGitHubRepository → Which tabs exist after General
- `App/Core/ProjectAreaAvailability.swift:99-101; App/UI/ProjectAreaOffers.swift:19-23` — ProjectArea.allCases minus available minus .tasks → Rows in the General 'Set up' panel
- `App/Core/ProjectAreaAvailability.swift:71-76; App/UI/ProjectAreaOffers.swift:61-67` — offerIsActionable (tasks/run/tests true; issues false) → Whether an offer row gets a 'Look' button
- `App/UI/ProjectDashboardView.swift:183` — !hasTaskSources && !todoHintDismissed → TodoHintCard
- `App/UI/ProjectDashboardView.swift:56-66` — area == .tasks && hasTaskSources; else area == .run / .tests / .issues without a fact check → Which area view renders; Run/Tests/Issues views can render with empty facts until resolve() runs
- `App/UI/ProjectDashboardView.swift:85` — ProjectAreaAvailability.resolve(area, facts) in .task(id: project.id) → Fallback to General when the selected area disappears (only re-evaluated on project change / refresh)
- `App/UI/ProjectDashboardView.swift:86-93` — LaunchConfig.projectArea or ProjectAreaRoute.take() and availableAreas.contains(target) → Deep-link into an area (string-typed)
- `App/UI/ProjectDashboardView.swift:207, 213` — git.isRepo → Worktrees panel and Pull Requests panel
- `App/UI/ProjectDashboardView.swift:204` — !sessionHistory.isEmpty → Closed Sessions panel
- `App/UI/ProjectDashboardView.swift:28, 231, 494` — isFirstLoad (page.loadedAt == nil) → Skeleton rows in Git and PR panels
- `App/UI/ProjectDashboardView.swift:231` — prMessage == nil && pullRequests.isEmpty → PR skeleton after first load (network still pending)
- `App/UI/ProjectDashboardView.swift:46, 324, 358` — headerWidth < 720 / < 620 / >= 560 → Tab labels icon-only; header spacing; path visibility
- `App/UI/ProjectDashboardView.swift:139` — candidate == .tasks && openTaskCount > 0 → Open-task badge on the Tasks tab
- `App/UI/ProjectDashboardView.swift:160` — candidate == .run && runs.runningCount(projectID:) > 0 → Green dot on the Run tab
- `App/UI/ProjectDashboardView.swift:339` — git.branch != nil → BranchBadge in the header
- `App/UI/ProjectDashboardView.swift:470-477; App/UI/BranchBadge.swift:132-135` — rootBusyWarning != nil (a root-tree session isWorking) → Confirmation before checkout
- `App/UI/ProjectDashboardView.swift:841-848` — hovering on a WorktreeRow → AgentLauncherStrip on a worktree
- `App/UI/ProjectDashboardView.swift:828-830, 844; App/UI/BranchBadge.swift:13-15` — worktree.isMain → 'house' icon, 'main copy' name, launcher with worktreePath nil
- `App/UI/NewProjectSheet.swift:87-92` — blueprintID != nil → Note naming settings.defaultProvider and whether the prompt auto-sends
- `App/UI/BlueprintCards.swift:107-128` — store.blueprints.isEmpty && onWriteFirst != nil → 'Write a blueprint' dashed button in the chooser
- `App/UI/NewProjectSheet.swift:44-47, 213-215` — excludedCount == 0 → Extensions row subtitle 'Everything…' vs 'N turned off'
- `App/UI/ProjectExtensionPicker.swift:139, 323-327` — !agents.isEmpty (agents = launcherProviders minus terminal mapped to ExtensionAgentID) → Agent tab bar in the extension picker
- `App/UI/ProjectExtensionPicker.swift:154-159` — skillBlindAgents non-empty && !skills.isEmpty → Provider-specific 'Skills are not scoped for X' caveat
- `App/UI/ProjectExtensionPicker.swift:270-272` — tab == nil (All agents) → 'off for <agents>' exception line under a row
- `App/UI/AppKit/SidebarOutline.swift:732; App/UI/SidebarView.swift:566-568; App/Core/ProjectStore.swift:116-118, 127-143` — project.isScratchWorkspace → Reduced context menu, dim name, no pin mark, sort last, excluded from visibleProjects. Not consulted by ProjectDashboardView, NewProjectSheet, or the palette's per-project commands (PaletteModel.swift:340-361 iterates ctx.projects)
- `App/UI/BlueprintCards.swift:95, 163-164; App/UI/Settings/BlueprintsSettingsPage.swift:89-90, 98-102` — blueprint.needsReview → 'draft' badge and warning copy
- `App/UI/Onboarding/OnboardingProjectSteps.swift:40-43` — FileManager.fileExists(path + '/.git') → Onboarding 'Git repository' badge — a different rule from GitService.snapshot (rev-parse) and GitHubRepoDiscovery (root or one level down)
- `App/UI/ProjectRunView.swift:186-193` — RunConfigFile.load(...).configurations non-empty read on every render → Session header run button — bypasses ProjectAreaFacts entirely
- `App/UI/NewProjectSheet.swift:254-259` — projectStore.sessions(for: project.id).isEmpty → Whether Cancel removes the just-added project

### Open questions

- Is the project home meant to be the agent workbench (sessions + launcher + next step) or a repository dashboard? Today it is both, and the sessions half is the weaker one.
- Should adding a folder ever open a modal, given every field in NewProjectSheet has a default? If a first question is worth asking, is it the blueprint alone?
- Are Blueprints and Session Presets meant to converge (one 'recipe' with a scope) or to stay separate? Their adjacency under Settings > Agents suggests nobody has decided.
- Is a 'container folder of several checkouts' a supported project kind? ProjectPageStore says yes for Issues; Git/Worktrees/PRs/branch say no.
- Should Scratch have its own screen instead of the project dashboard, or should Project gain a kind that every surface must switch on?
- Who is the acting agent for project-level actions (blueprint, organise)? defaultProvider vs hard-coded Claude today.
- Which surface is authoritative for project extension bindings when the Extensions window (agent-less) and the project sheets (per-agent) disagree?

---

## Project dashboard areas Run, Tests and Issues (ProjectRunView / ProjectTestsView / ProjectIssuesView), their detection + config files (.uncoil/run.json, .uncoil/tests.json), the run default control in every session header, the run/test rows in the Attention Center, the General-page "Set up" offers that gate the tabs, and the uncoil_run MCP half that mirrors them.

From the user's chair a project screen has up to five tabs (General, Tasks, Run, Tests, Issues) and three of them exist only when a file on disk says so: Run appears once `.uncoil/run.json` has a configuration, Tests once `.uncoil/tests.json` has a suite, Issues once the folder or a sub-folder has a GitHub remote. Run is a process manager: cards for shell commands with start/stop/restart, a log tail, a preview-URL link that opens the browser, a Docker container strip, an issue banner with "Fix with agent", a history popover, a star that makes one configuration the "default", and a nine-field editor sheet (id, name, command, cwd, env, ports, preview URL, ready-pattern regex, depends_on ids). The default run also gets a play/stop button in every session header. Tests is a results viewer: suites are only ever created by "Look for tests" (detection), hand-editing tests.json or an agent calling `test_update`; a suite card runs and shows per-test steps (XCTest, go, cargo, pytest, jest/vitest, Maestro) with filters, artifacts, a step detail sheet and "Fix with agent" that opens a new session. Issues lists open GitHub issues across the project's repos with label chips, comment/close, and "Hand this issue to an agent". Failures from Run and Tests land in the Attention Center as "Runtime problem"/"Test failed" rows. Agents see the same features as the `uncoil_run` MCP tool (run actions + `test_*` actions) behind the `runs.read/write/control` grants, and the human UI is essentially a form over the agent-shaped JSON contract.

### Findings

#### [CRITICAL] RT-01 — The project's stack is detected once per feature, never once per project

*Category:* duplicate-concept

- `App/Core/RunDetection.swift:39` — private static let ignoredDirectories: Set<String> = [ "node_modules", ".git", ".build", ".build-cache", "backups", "dist", …
- `App/Core/TestDetection.swift:25` — private static let ignoredDirectories: Set<String> = [ "node_modules", ".git", ".build", ".build-cache", "backups", "dist", …
- `App/Core/GitHubIssues.swift:219` — static let ignored: Set<String> = [ "node_modules", ".build", ".build-cache", "build", "DerivedData", "Pods", …
- `App/Core/RunDetection.swift:115` — let packageManager = entries.contains("pnpm-lock.yaml") ? "pnpm" : entries.contains("yarn.lock") ? "yarn" …
- `App/Core/TestDetection.swift:149` — let packageManager = entries.contains("pnpm-lock.yaml") ? "pnpm" : entries.contains("yarn.lock") ? "yarn" …
- `App/Core/RunDetection.swift:146` — let workspace = entries.first { $0.hasSuffix(".xcworkspace") }; let project = entries.first { $0.hasSuffix(".xcodeproj") }
- `App/Core/TestDetection.swift:63` — let workspace = entries.first { $0.hasSuffix(".xcworkspace") }; let project = entries.first { $0.hasSuffix(".xcodeproj") }
- `App/Core/ProjectPageStore.swift:108` — let (git, worktrees, remote, hasGitHub, runs, tests) = await Task.detached … GitHubRepoDiscovery.hasRepository(projectRoot: root), !RunConfigFile.load(projectRoot: rootURL).configurations.isEmpty, !TestConfigFile.load(pr

**Why it matters:** RunDetection, TestDetection, GitHubRepoDiscovery and TodoDiscovery each walk the tree with their own ignore list, slug(), package-manager and Xcode-container heuristics; ProjectAreaFacts is four unrelated booleans. There is no 'this is a Next.js app with pytest and an Xcode target' model, so every future feature (preview, simulators, API client) will re-detect the same facts and the user will see the same stack 'discovered' in N places with N wordings.

**Direction:** One project-stack detection producing a single facts model that Run, Tests, Issues, offers and future features read from.

#### [CRITICAL] RT-02 — No framework/run-kind registry: adding a test framework touches ~9 places, a run kind ~7

*Category:* other

- `App/Core/TestSuiteConfig.swift:10` — enum TestFramework: String, Codable, CaseIterable { case swift, xcodebuild, go, cargo, pytest, jest, maestro, unknown
- `App/Core/TestDetection.swift:36` — suites += xcodeSuites(…); suites += swiftSuites(…); suites += goSuites(…); suites += cargoSuites(…); suites += nodeSuites(…); suites += pythonSuites(…); suites += maestroSuites(…)
- `App/Core/TestOutputParser.swift:95` — let messages: [String: String] = switch framework { case .swift, .xcodebuild: xctestFailures(output) case .go: goFailures(output) … case .jest, .unknown: [:] }
- `App/Core/TestOutputParser.swift:138` — static func cases(in output: String, framework: TestFramework) -> [TestCaseResult] { switch framework { case .swift, .xcodebuild: parseXCTest(output) …
- `App/Core/TestOutputParser.swift:158` — static func declaredTotal(in output: String, framework: TestFramework) -> Int? { switch framework { case .pytest: … case .cargo: … case .go, .jest, .maestro, .unknown: return nil
- `App/ControlPlane/HelpRegistry.swift:448` — Per-test results are only available for frameworks whose output is parsed (swift/xcodebuild, go, cargo, pytest, jest/vitest, maestro)
- `App/ControlPlane/HelpRegistry.swift:494` — `framework` (swift|xcodebuild|go|cargo|pytest|jest|maestro|unknown — governs how the output is read
- `App/UI/ProjectTestsView.swift:98` — Uncoil can look for the project's own test setup — a scheme, a Package.swift, go.mod, Cargo.toml, a package.json test script, or a pytest configuration.
- `App/Core/RunDetection.swift:82` — configs += nodeConfigs(…); configs += xcodeConfigs(…); configs += goConfigs(…); configs += composeConfigs(…); configs += dockerfileConfigs(…); configs += procfileConfigs(…); configs += makefileConfigs(…); configs += pyth
- `App/Core/RunDiagnostics.swift:42` — if log.contains("does not contain a scheme named") || log.contains("cannot find a scheme") { return RunIssue(code: "invalid_scheme" …
- `App/Core/DockerStatus.swift:60` — static func isDockerCommand(_ command: String) -> Bool { … normalized.contains("docker compose") || normalized.contains("docker-compose") || normalized.contains("docker run")

**Why it matters:** Frameworks and run kinds are spread across enums, detector lists, three parser switches, diagnostics keyword rules, command-string sniffing for Docker, help-registry prose, CAPABILITIES.md, the Tests empty-state prose (already stale — omits Maestro) and RUN_PREVIEW.md's coverage list. Each addition is a hand-maintained scatter, and the human-facing copy drifts from the code.

**Direction:** A single registry entry per framework/run kind (detect, parse, diagnose, display name, doc line) that every surface and doc string is generated from.

#### [HIGH] RT-03 — Agent-shaped config is exposed to humans under wire names: regex, ids, slugs, raw issue codes, raw source enum

*Category:* agent-leak

- `App/UI/ProjectRunView.swift:795` — field(String(localized: "id (slug)"), text: $id, disabled: !isNew)
- `App/UI/ProjectRunView.swift:802` — field(String(localized: "Ready pattern (regex)"), text: $readyPattern)
- `App/UI/ProjectRunView.swift:803` — field(String(localized: "Dependencies (ids, comma-separated)"), text: $dependsOnText)
- `App/UI/ProjectRunView.swift:799` — field(String(localized: "Env (KEY=value, one per line)"), text: $envText, axis: .vertical)
- `App/UI/ProjectRunView.swift:632` — Text(issue.code)  // e.g. port_in_use, not_ready, dependency_cycle as the banner title
- `App/UI/ProjectRunView.swift:510` — Text(config.source.rawValue)  // 'detected' | 'user' | 'agent' badge
- `App/Core/RunDiagnostics.swift:80` — hint: "The process is alive but never matched ready_pattern or opened its declared port. Fix 'ready_pattern'/'ports' in .uncoil/run.json if the server is actually fine."
- `App/UI/TestStepList.swift:626` — detail(String(localized: "Framework"), suite.framework.displayName)

**Why it matters:** The editor is a form over the JSON contract designed for agents (RUN_PREVIEW_PLAN.md §1). A human has to know regex, id slugs, dependency ids and the file name to recover from 'not_ready'; the 'Framework' row is a parser selector shown as a fact the user cannot change. The internal provenance flag 'source' is a UI badge.

**Direction:** Split the human editor from the agent contract: pick 'wait for' (port / text / none) and dependencies from a list; hide source and issue codes behind plain sentences.

#### [HIGH] RT-04 — Three 'hand to an agent' behaviours with two labels: existing-session-or-clipboard vs new session vs new session

*Category:* duplicate-concept

- `App/Core/RunRepair.swift:35` — static func candidateSession(project: Project, projectStore: ProjectStore) -> SessionRecord? { projectStore.sessions.filter { $0.projectID == project.id && $0.provider != .terminal && $0.endedAt == nil }.max { $0.lastAct
- `App/Core/RunRepair.swift:53` — guard let session = candidateSession(…) else { let pasteboard = NSPasteboard.general … return false }
- `App/UI/ProjectRunView.swift:648` — ? "Sent to the agent" : "No live agent — the prompt was copied to the clipboard"
- `App/Core/TestRepair.swift:5` — Peer of `RunRepair`, and deliberately *not* the same in one respect: this opens a new session rather than talking into whichever agent happened to be active.
- `App/Core/TestRepair.swift:119` — let session = projectStore.createSession(projectID: project.id, provider: provider, accountID: nil, title: title(suite: suite, focus: focus))
- `App/UI/ProjectIssuesView.swift:340` — let record = projectStore.createSession(projectID: project.id, provider: settings.defaultProvider, accountID: nil, title: "#\(issue.number) \(issue.title)")
- `App/UI/ProjectIssuesView.swift:277` — help: String(localized: "Hand this issue to an agent")
- `App/UI/TestStepList.swift:213` — Text("Fix with agent")

**Why it matters:** The same button text 'Fix with agent' interrupts a live session on the Run tab but spawns a fresh one on the Tests tab; Issues uses a different verb and a different title scheme. The user cannot predict where the work will land, and every new area (Tasks already has dispatch sheets) invents a fourth variant.

**Direction:** One 'send to agent' primitive with an explicit target choice (this session / new session), shared by Run, Tests, Issues and Tasks.

#### [HIGH] RT-05 — Tests has no authoring UI at all while its peer Run has a full editor, star and delete

*Category:* settings-sprawl

- `App/UI/ProjectTestsView.swift:83` — ControlButton(iconName: "refresh", help: String(localized: "Look for test suites in this project"), identifier: "tests.detect")
- `App/UI/ProjectTestsView.swift:286` — message = String(localized: "Nothing found. Add a suite to .uncoil/tests.json by hand, or ask an agent to.")
- `App/Core/TestSuiteConfig.swift:51` — /// The suite `{"action":"test_run"}` resolves to with no id. var isDefault: Bool
- `App/ControlPlane/HelpRegistry.swift:494` — # test_update … This is how you register tests you have written.
- `App/UI/ProjectRunView.swift:102` — Text("New")
- `App/Core/TestDetection.swift:76` — notes: "Scheme guessed from the container name — run `xcodebuild -list` to verify, and change the destination for iOS/simulator targets."

**Why it matters:** A detector that admits it guesses the scheme and hardcodes a macOS destination hands the correction to JSON or an agent. Default suite, framework and artifacts exist in the model and MCP but cannot be set by a person. The two sibling tabs teach opposite mental models: Run says 'you own this file', Tests says 'agents own this file'.

**Direction:** Either give suites the same editor/star/delete as runs or make both read-only-with-agent-repair; not one of each.

#### [HIGH] RT-06 — Run/test failures in the Attention Center land on the General tab, never notify, and a failed run is filed as 'Runtime problem'

*Category:* navigation

- `App/Core/RunRegistry.swift:234` — AttentionStore.shared.report(kind: .runtime, title: "Run '\(config.name)' failed", detail: issue.hint, projectID: project.id, sessionID: nil, id: "run:…")
- `App/Core/AttentionCenter.swift:39` — case .runtime: String(localized: "Runtime problem")
- `App/Core/AttentionCenter.swift:281` — id: runtimeID, kind: .runtime, title: String(localized: "Runtime daemon"), detail: "uncoil-runtimed is unreachable; sessions run on the in-app PTY."
- `App/UI/MainWindow.swift:475` — AttentionStore.shared.report(kind: .runtime, title: String(localized: "Could not file that task"), …
- `App/UI/SidebarView.swift:166` — if let sessionID = item.sessionID { … selection = .session(sessionID) } else if let projectID = item.projectID { selection = .project(projectID) }
- `App/UI/MainWindow.swift:908` — guard let event = item.kind.notificationEvent, let projectID = item.projectID, let sessionID = item.sessionID else { continue }
- `App/Core/NotificationPrefs.swift:38` — case .problem: String(localized: "A runtime error, a failing test or a dropped connection.")
- `App/Core/TestRegistry.swift:145` — AttentionStore.shared.resolve("test:\(project.id):\(suite.id)")  // runs have no equivalent
- `App/Core/ProjectPageStore.swift:170` — func request(_ area: String, for projectID: UUID) { pending[projectID] = area }  // only caller: RunDefaultControl

**Why it matters:** The one cross-cutting surface for 'something broke' cannot take the user to the tab that shows it (ProjectAreaRoute exists but only the session header uses it), the Notifications pane promises alerts it never sends for these rows, a dev-server crash wears the same label as daemon trouble and a TODO write error, and a repaired run's row lingers until clicked away.

**Direction:** Give Attention items a destination (project + area) and let run/test rows resolve on recovery; use a distinct kind for run failures.

#### [HIGH] RT-07 — Tab existence is a cached file-presence check that agent writes never invalidate, and it can eject the user mid-tab

*Category:* visibility-logic

- `App/Core/ProjectPageStore.swift:11` — static let window: TimeInterval = 90
- `App/Core/ProjectPageStore.swift:74` — guard force || ProjectPageFreshness.needsRefresh(loadedAt: existing?.loadedAt, now: now) else { return }
- `App/Core/ProjectAreaAvailability.swift:89` — if facts.hasRunConfigurations { areas.append(.run) }; if facts.hasTestSuites { areas.append(.tests) }
- `App/Core/ProjectAreaAvailability.swift:106` — static func resolve(_ requested: ProjectArea, facts: ProjectAreaFacts) -> ProjectArea { areas(facts).contains(requested) ? requested : .overview }
- `App/UI/ProjectRunView.swift:394` — Text("Removed from .uncoil/run.json; run history and logs stop.")  // says nothing about the tab vanishing
- `App/ControlPlane/RunsHandler.swift:1` — (no reference to ProjectPageStore/invalidate anywhere in App/ControlPlane — verified by grep)

**Why it matters:** An agent asked to 'set up the tests' writes tests.json over MCP and the Tests tab may not appear for up to 90s; deleting the last configuration in the Run tab silently removes the tab on the next refresh. The rule is right in spirit (no empty tabs) but it is computed from raw file reads in a page cache, not from an event the writers can raise.

**Direction:** Make configuration writers (UI, MCP, file watcher) publish an area-facts change instead of polling file emptiness on a timer.

#### [MEDIUM] RT-08 — A project-level run control lives in every session header and half-works in split panes

*Category:* navigation

- `App/UI/SessionHeaderBar.swift:254` — RunDefaultControl(project: project, onOpenLogs: onOpenProject)
- `App/UI/ProjectRunView.swift:175` — // Read the file on render rather than caching in @State … let configurations = RunConfigFile.load(projectRoot: project.rootURL).configurations
- `App/UI/ProjectRunView.swift:220` — ProjectAreaRoute.shared.request("run", for: project.id); onOpenLogs?()
- `App/UI/SessionDetailView.swift:278` — SessionHeaderBar(record: record, project: project, leadingIcon: "xmark", leadingHelp: "Close the pane", onLeading: onClose, onRestart: { restart() })  // no onOpenProject

**Why it matters:** The header cluster mixes session actions (restart, handoff, editor) with a project action (run default). In a pane, 'Open the log' records a pending route and nothing navigates. The control also reads a repo file on each header render, tying header redraw cost to a feature the session may not use.

**Direction:** Treat 'run the project' as a project-level affordance surfaced consistently (project header / palette) rather than a per-session button, or wire it fully everywhere.

#### [MEDIUM] RT-09 — One action, three names and three feedback styles; one Turkish status string in the English UI

*Category:* terminology

- `App/UI/ProjectRunView.swift:83` — Text(detecting ? "Scanning…" : "Detect")  // saves silently, no result message
- `App/UI/ProjectTestsView.swift:102` — Button(action: detect) { Text("Look for tests") }
- `App/UI/ProjectTestsView.swift:288` — message = String(localized: "Nothing new.")
- `App/UI/ProjectAreaOffers.swift:64` — Button { setUp(offer) } label: { Text("Look") }
- `App/UI/ProjectAreaOffers.swift:106` — ? String(localized: "Found \(added). The tab is on the right.")
- `App/UI/ProjectRunView.swift:537` — case .exited(let code): "bitti (\(code))"
- `App/UI/ProjectRunView.swift:534` — case .idle: "ready"  // MCP reports the same state as "idle" (RunRegistry.swift:107)
- `docs/current/RUN_PREVIEW.md:42` — it only appends new ids ("Tespit et" in the UI, `{"action":"detect"}` over MCP

**Why it matters:** Detection is the entry point to two of the three areas and is named differently in each place it appears; the Run tab gives no feedback at all. Status vocabulary differs between UI and MCP for the same state. The public-repo English rule is broken by 'bitti'.

**Direction:** One verb and one result message for detection everywhere; align UI status labels with RunStatus.label.

#### [MEDIUM] RT-10 — run.json and tests.json are two schemas, two parsers and two merge functions for one kind of thing

*Category:* duplicate-concept

- `App/Core/TestSuiteConfig.swift:40` — Deliberately the same shape and the same ownership model as `RunConfiguration` — a project-owned JSON file both the user and an agent can read and repair
- `App/Core/RunConfig.swift:158` — static func parse(_ data: Data) -> Contents { … contents.problems.append("\(relativePath) is not a JSON object; ignoring it") … "duplicate configuration id '\(config.id)'; kept the first"
- `App/Core/TestSuiteConfig.swift:166` — static func parse(_ data: Data) -> Contents { … contents.problems.append("\(relativePath) is not a JSON object; ignoring it") … "duplicate suite id '\(suite.id)'; kept the first"
- `App/Core/RunDetection.swift:64` — static func merge(existing:suggestions:replacingDetected:) … kept += suggestions.filter { !taken.contains($0.id) }
- `App/Core/TestSuiteConfig.swift:214` — static func merge(existing:suggestions:replacingDetected:) … kept += suggestions.filter { !taken.contains($0.id) }
- `App/ControlPlane/RunsHandler+Tests.swift:16` — Test suites are actions on this tool rather than a ninth one: the MCP surface is eight tools by design, and a suite is the same kind of thing a run is.
- `App/Core/SessionImageDrop.swift:19` — static let directoryName = ".uncoil/dropped"  // plus .uncoil/blueprints, .uncoil/extensions, .uncoil/tools, .uncoil/handoff, run.json, tests.json

**Why it matters:** The code itself argues a suite 'is the same kind of thing a run is', yet the user meets two files, two tabs, two 'problems' banners and two ownership stories. `.uncoil/` has seven owners and no index, so a person opening the folder cannot tell what is configuration and what is cache.

**Direction:** Decide whether a test suite is a run with kind=test (one file, one tab with two lists) or a distinct concept; document `.uncoil/` as one namespace.

#### [MEDIUM] RT-11 — Both tabs carry empty states that the tab-gating makes unreachable, plus dead UI code from the last redesign

*Category:* empty-state

- `App/UI/ProjectRunView.swift:146` — Text("No run configuration yet.") … "“Detect” derives suggestions from the project's files; or write .uncoil/run.json by hand (or have an agent write it)."
- `App/UI/ProjectTestsView.swift:95` — Text("No test suites yet") … Button(action: detect) { Text("Look for tests") }
- `App/Core/ProjectAreaAvailability.swift:92` — if facts.hasRunConfigurations { areas.append(.run) }
- `App/UI/ProjectRunView.swift:542` — private var controls: some View {  // never referenced; duplicates primaryControl/secondaryControls including a second delete confirmation

**Why it matters:** The prose that tells a person they may write the file by hand or ask an agent lives in a state they never see; the General-page offer says something else. The unreferenced `controls` view keeps a second copy of the delete dialog and button set that will drift.

**Direction:** Move the 'hand-write or ask an agent' guidance to the offer row and delete the dead view.

#### [MEDIUM] RT-12 — Suite-level 'Fix with agent' hides behind an all-or-nothing rule; three entry points for the same repair

*Category:* discoverability

- `App/UI/TestStepList.swift:193` — static func showsSuiteRepair(for record: TestRunRecord) -> Bool { guard !record.summary.didPass else { return false }; let failed = record.cases.count { $0.outcome == .failed }; return failed == 0 || failed == record.cas
- `App/UI/TestStepList.swift:371` — help: String(localized: "Open a new agent session on this test")  // per-row wand
- `App/UI/TestStepList.swift:550` — help: String(localized: "Open a new agent session on this test")  // detail-sheet wand

**Why it matters:** With 3 of 10 tests red there is no 'fix these' button — only ten wands that each open a separate session. The rule is a view-level heuristic, not a product decision the user can see.

**Direction:** One repair action on the suite that carries the current filter's failures; keep the per-test wand as the narrow variant.

#### [MEDIUM] RT-13 — Run 'kind' is inferred by sniffing command text and log substrings instead of being a declared property

*Category:* coupling

- `App/Core/DockerStatus.swift:172` — static func runContainerName(in command: String) -> String? { let fields = command.split(separator: " ") … fields.firstIndex(of: "--name")
- `App/Core/RunDiagnostics.swift:21` — if log.contains("eaddrinuse") || log.contains("address already in use") || log.contains("port is already allocated")
- `App/Core/RunRegistry.swift:395` — guard let arguments = DockerStatus.statusArguments(for: config.command) else { return }
- `App/Core/RunDetection.swift:162` — notes: "Scheme guessed from the container name — run `xcodebuild -list` to verify, and add a -destination for iOS/simulator targets."

**Why it matters:** A user who renames a container or wraps docker in a script loses the container strip with no explanation; an Xcode run is 'an xcodebuild string' rather than 'an app on a destination', which is exactly what a simulator/device feature would need to know. The schema has no slot for kind, so the roadmap's simulator/device work has nowhere to attach.

**Direction:** Add a declared kind (shell / compose / docker / xcode / node…) to the configuration and hang diagnostics, health and future preview on it.

#### [MEDIUM] RT-14 — GitHub is split across two tabs: pull requests on General, issues on Issues

*Category:* navigation

- `App/UI/ProjectDashboardView.swift:214` — if git.isRepo { pullRequestsPanel }
- `App/Core/GitHubIssues.swift:42` — Separate from `GitHubService` because issues are not pull requests, and on this API that distinction is a trap
- `App/Core/ProjectPageStore.swift:138` — if let remote, let slug = GitHubService.repoSlug(fromRemoteURL: remote) { switch await GitHubService.openPullRequests(slug: slug)
- `App/Core/GitHubIssues.swift:229` — static func slugs(projectRoot:…) // root + one level: Issues covers sub-repos, PRs only the root remote

**Why it matters:** Same remote, same token, two discovery rules (PRs: root only; issues: root + one level) and two homes. A user looking for 'what is open on GitHub' has to know the split.

**Direction:** One GitHub area (or one panel) with consistent repository discovery.

#### [LOW] RT-15 — 'Create a Test Workspace' in the palette is unrelated to the Tests tab but shares the word and the flask icon

*Category:* terminology

- `App/Core/PaletteModel.swift:324` — PaletteItem(id: "cmd.testWorkspace", title: String(localized: "Create a Test Workspace"), iconName: "flask", kind: .command, action: .createTestWorkspace)
- `App/Core/TestWorkspaceService.swift:27` — .appendingPathComponent("UncoilAcceptance-\(UUID().uuidString)", isDirectory: true)
- `App/Core/ProjectAreaAvailability.swift:39` — case .tests: "flask"

**Why it matters:** A developer-facing acceptance fixture is exposed as a first-class command next to 'Add a New Project', with the vocabulary of the user's own test feature.

**Direction:** Rename to 'acceptance workspace' and move it under a debug/developer group.

#### [LOW] RT-16 — runs.* grants surface in three places with three labels, and tests ride them unannounced

*Category:* settings-sprawl

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:264` — id: "runs", … title: "Running the project", detail: "uncoil_run — detects how the project starts, edits that configuration and launches it…", keys: ["runs.read", "runs.write", "runs.control"]
- `App/ControlPlane/CapabilityCatalog.swift:137` — .init(key: "runs.control", domain: .runs, label: "Start / stop", detail: "Starts and stops the project's dev servers and build processes.", risky: true)
- `App/UI/Settings/AgentSettingsPages.swift:694` — SettingsLabel(title: capability.label, detail: capability.key)  // raw key shown
- `App/ControlPlane/RunsHandler+Tests.swift:6` — It reuses the `runs.*` grants for the same reason: an agent allowed to start a dev server is allowed to run the tests

**Why it matters:** 'Start / stop … dev servers' is also the switch that lets an agent run a four-minute test suite; the user is not told. The internal key string is displayed as help text in the preset editor.

**Direction:** Label the grant for what it covers (run and test the project) and keep keys out of labels.

#### [LOW] RT-17 — Docs lag the product: Tests has no current doc, RUN_PREVIEW.md keeps Turkish UI text, and a planned 'replace suggestions' UI never shipped

*Category:* other

- `docs/current/RUN_PREVIEW.md:42` — ("Tespit et" in the UI, `{"action":"detect"}` over MCP; `{"replace":true}` resets only *detected* entries)
- `docs/roadmap/RUN_PREVIEW_PLAN.md:69` — `{"action":"detect", "replace": true}` (or the UI's explicit "Re-detect, replace suggestions") drops *detected* entries only
- `App/UI/ProjectRunView.swift:123` — existing: existing, suggestions: suggestions, replacingDetected: false  // UI never offers replace
- `App/ControlPlane/HelpRegistry.swift:448` — The same tool runs the project's TESTS, under the `test_*` actions … (only place tests.json is documented besides CHANGELOG)

**Why it matters:** docs/current lists RUN_PREVIEW.md only; the tests contract exists solely as MCP help text. A user who mis-detects has no 'start over' in the UI that agents have.

**Direction:** One current doc per project-config file, generated from the same registry as the help text.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Project tab row (area picker) | toolbar | `App/UI/ProjectDashboardView.swift` | sidebar project selection; MainRoute .project; ProjectAreaRoute.request("run") from session header log button (only consumer); -project-area launch arg |
| General page 'Set up' offers | panel | `App/UI/ProjectAreaOffers.swift` | General tab of any project missing an area |
| Run tab | tab | `App/UI/ProjectRunView.swift` | tab 'Run' (exists only when run.json has ≥1 config); session header 'Open the log' button via ProjectAreaRoute; -run-start <id> launch arg |
| Run configuration card (head) | row | `App/UI/ProjectRunView.swift` | Run tab |
| Run card drawer | panel | `App/UI/ProjectRunView.swift` | Run card after first start |
| Run history popover | popover | `App/UI/ProjectRunView.swift` | history glyph on a run card |
| Run configuration editor sheet | sheet | `App/UI/ProjectRunView.swift` | run.add; run.edit.<id> |
| Run tab empty state | empty-state | `App/UI/ProjectRunView.swift` | delete last config in Run tab |
| Session header run default control | hover-control | `App/UI/ProjectRunView.swift` | any session screen; split-pane session header (onOpenProject nil → log button only sets a pending route) |
| Tests tab | tab | `App/UI/ProjectTestsView.swift` | tab 'Tests' (exists only when tests.json has ≥1 suite); -tests-run <id> launch arg |
| Test suite card (head) | row | `App/UI/ProjectTestsView.swift` | Tests tab |
| Live-run drawer | panel | `App/UI/ProjectTestsView.swift` | press play on a suite |
| Finished-run drawer (TestStepList) | panel | `App/UI/TestStepList.swift` | suite card after a run, or persisted last result on next launch |
| TestSummaryBar | status | `App/UI/Components/TestSummaryBar.swift` | Tests drawers; TestStepDetailSheet 'The run' section |
| Test step detail sheet | sheet | `App/UI/TestStepList.swift` | click a step row; -tests-step <suite> launch arg |
| Test artifact preview | sheet | `App/UI/TestStepList.swift` | artifact chip / artifact row |
| Tests tab empty state | empty-state | `App/UI/ProjectTestsView.swift` | only if tests.json is emptied while the tab is open |
| Issues tab | tab | `App/UI/ProjectIssuesView.swift` | tab 'Issues' (exists iff a GitHub remote is found at root or one level down); -issues-expand <n> launch arg |
| Issues empty state | empty-state | `App/UI/ProjectIssuesView.swift` | Issues tab with zero issues |
| Attention Center rows for run and test failures | row | `App/Core/RunRegistry.swift` | sidebar bell; menu bar monitor |
| Onboarding 'What the agents may do' → group 'Running the project' | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | first-run flow step 'capabilities' |
| Settings › Privacy (per-session grants, advanced section) | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings › Privacy |
| Settings › Agents › Presets editor › Grants | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings › Agents › presets |
| Command palette 'Create a Test Workspace' | menu | `App/Core/PaletteModel.swift` | command palette |

### Concepts

- `U` **Run configuration** — One runnable dev workflow: shell command + cwd + env + ports + preview_url + ready_pattern + depends_on + default + source + notes, stored in .uncoil/run.json (RunConfig.swift:17-41). *Overlaps:* Test suite (same shape minus ports/preview/ready/depends + framework/artifacts), Task (a session-driving unit of work)
- `U` **Default run configuration** — The one flagged default:true, or the only one; what the session header button and id-less MCP calls resolve to (RunConfig.swift:183-188). *Overlaps:* Default test suite (model + MCP only, no UI)
- `U!` **Source (detected | user | agent)** — Provenance flag deciding whether re-detection may replace an entry (RunConfig.swift:6-10). Shared by suites. *Overlaps:* Blueprint.needsReview ('an agent wrote this'), Extensions install provenance
- `U!` **Ready pattern (regex)** — Regex matched against process output to flip starting→running; fallback is an open declared port or a 2s survival grace (RunRegistry.swift:430-447). *Overlaps:* Ports (alternative readiness signal)
- `U!` **Dependencies (depends_on ids)** — Configuration ids started and awaited first; cycle-checked (RunRegistry.swift:590-609). *Overlaps:* Procfile multi-process (detected as separate configs without dependencies)
- `U!` **Run issue (code + hint)** — Machine-readable failure classification from exit code + log substrings (RunDiagnostics.swift:16-82); 15 stable codes documented for agents. *Overlaps:* Docker container health (a second, separate failure signal for the same run)
- `U` **Run status** — idle/starting/running/exited(code)/failed (RunRegistry.swift:100-118). *Overlaps:* Docker container health, Test suite state (isRunning + latest record)
- `U` **Docker container health** — Polled every 5s for commands that contain 'docker compose'/'docker run --name' (DockerStatus.swift:60-70,160-178); allRunning / degraded(reason) / allStopped. *Overlaps:* Run status
- `U` **Run history + log files** — Last 10 runs per configuration with timestamped logs under App Support projects/<id>/run (RunRegistry.swift:143-215). *Overlaps:* Test run record (different store, different retention: 1 per suite)
- `U` **Detect / Look for tests / Look** — Filesystem heuristics that append suggested entries (source=detected) without touching user/agent entries. Run: package.json dev|start|serve (+pnpm/yarn/bun, next/vite/remotion ports), .xcworkspace/.xcodeproj build&&open, go.mod (cmd/ lookup), compose files, Dockerfile EXPOSE, Procfile lines, Makefile dev|run|start|serve, Django manage.py, pyproject [project.scripts] (+uv), bare index.html → python http.server; root + one level. Tests: Xcode container → xcodebuild test (macOS destination hardcoded), Package.swift → swift test, go.mod → go test -json, Cargo.toml → cargo test, package.json test script (jest/vitest parsed, else unknown; npm placeholder ignored), pytest config (+uv), Maestro dirs .maestro/maestro/e2e/flows with appId:/url:. *Overlaps:* GitHubRepoDiscovery (Issues tab gate), TodoDiscovery (Tasks tab gate), ProjectAreaFacts
- `U` **Test suite** — id, name, command, cwd, env, framework, default, source, notes, artifacts, extra in .uncoil/tests.json (TestSuiteConfig.swift:43-62). *Overlaps:* Run configuration
- `U!` **Framework (parser selector)** — swift | xcodebuild | go | cargo | pytest | jest | maestro | unknown — decides which output parser runs and whether per-test rows exist (TestSuiteConfig.swift:10-34). *Overlaps:* Detected stack (the same facts RunDetection re-derives)
- `U` **Test run record / step / summary** — Persisted last result per suite (cases, summary passed/failed/skipped + isDetailed, logTail, artifacts) at App Support projects/<id>/tests/<suite>.json (TestRegistry.swift:4-30,394-416). *Overlaps:* Run history entry
- `U` **Artifacts directory** — Optional project-relative dir a suite writes screenshots/videos to; files modified during the run are attached to steps by name overlap (TestArtifacts.swift:62-99). Paths outside the project refused. *Overlaps:* Session artifacts (uncoil_artifacts tool)
- `U` **Fix with agent (RunRepair)** — Builds a prompt containing raw MCP JSON calls and submits it to the project's most recently active live agent session, else copies to clipboard (RunRepair.swift:10-64). *Overlaps:* Fix with agent (TestRepair) — opens a NEW session, Hand this issue to an agent — opens a NEW session
- `U` **Fix with agent (TestRepair)** — Always creates a new session on settings.defaultProvider titled 'fix <suite|test>' with failures, artifacts, an anti-assertion-weakening instruction and an MCP note (TestRepair.swift:17-140). *Overlaps:* RunRepair, Issues hand-off, Tasks assign/dispatch
- `U` **Hand this issue to an agent** — Creates a new session on defaultProvider titled '#N title' and submits a fenced prompt (ProjectIssuesView.swift:339-353; GitHubIssues.swift:189-209). *Overlaps:* TestRepair, TaskDispatch
- `U` **GitHub issue / label / repository slug** — Open issues (never PRs) fetched per discovered owner/repo, keyed repo#number (GitHubIssues.swift:4-38). *Overlaps:* Pull requests panel on the General tab (same remote, different tab), Tasks (TODO.md)
- `U` **Project area / area facts / offers** — ProjectArea enum (overview, tasks, run, tests, issues) + four booleans in ProjectAreaFacts decide tab existence and the General-page offers (ProjectAreaAvailability.swift:15-108). *Overlaps:* Detection (each fact = a separate filesystem walk)
- `U` **Attention kinds .runtime / .testFailure** — .runtime = 'Runtime problem' reused for failed runs, daemon trouble and task-capture errors; .testFailure = 'Test failed' (AttentionCenter.swift:4-40,281-287; MainWindow.swift:475). *Overlaps:* Run issue banner, Tests red suite
- `U!` **Grants runs.read / runs.write / runs.control** — Capability keys gating uncoil_run actions, default-on, control flagged risky; test_* actions reuse them (CapabilityCatalog.swift:131-139; PolicyEngine.swift:41-42; RunsHandler+Tests.swift:6-10). *Overlaps:* tasks.* grants (same pattern)
- `U!` **Test Workspace (acceptance workspace)** — Temporary sample repo for exercising Uncoil itself (TestWorkspaceService.swift:25-48). *Overlaps:* Tests tab (name/icon collision)

### Flows

- **Turn Run on for a project that has none** (4 steps) — friction: The tab is invisible until detection succeeds, so 'write run.json by hand / ask an agent' (the empty-state advice) is never shown to someone who has no tab. If an agent writes run.json over MCP instead, nothing invalidates the 90s page snapshot, so the tab shows up late (no ProjectPageStore call anywhere in App/ControlPlane).
- **Start, watch and repair a run** (5 steps) — friction: Three distinct signals for 'is it healthy' (status, issue, container health); the user reads regex/port/id concepts to fix a not_ready; the repair path silently changes behaviour depending on whether any agent session happens to be alive.
- **Run the default from a session** (4 steps) — friction: In the split-pane header onOpenProject is not passed (SessionDetailView.swift:278-284), so the log button leaves a pending route and does nothing visible; the header re-reads run.json from disk on every render; a project-level control sits among session-level ones.
- **Create or edit a run configuration by hand** (4 steps) — friction: No way to set notes; no regex validation; depends_on typed as ids from memory; id is immutable and shown with its wire name; 'default' is set elsewhere (star) than the rest of the record.
- **Turn Tests on, run a suite, act on failures** (6 steps) — friction: Nothing in the UI creates, edits, deletes or defaults a suite; correcting a wrong xcodebuild destination or picking a framework means editing JSON or asking an agent. 'Fix with agent' means something different from the Run tab's button of the same name.
- **Register a suite the agent wrote** (2 steps) — friction: The only authoring path for suites is agent- or hand-driven; the human UI is read-only on configuration.
- **Triage a GitHub issue** (3 steps) — friction: Pull requests for the same remote live on the General tab (ProjectDashboardView.swift:214-227), issues on their own tab; the hand-off is a third variant of 'give this to an agent'.
- **Agent-driven run repair over MCP** (4 steps) — friction: Agent and human views drift: MCP status labels are idle/exited while the UI says ready/bitti; the UI has no 'replace detected' that MCP has.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| .uncoil/run.json (configurations[]: id, name, command, cwd, env, ports, preview_url, ready_pattern, depends_on, default, source, notes, + unknown keys preserved) | project | repo-owned file, RunConfigFile (App/Core/RunConfig.swift:138-215) | Run tab editor sheet, star, trash, Detect; General 'Set up' → Look; MCP uncoil_run detect/update/remove/set_default; hand edit | yes |
| .uncoil/tests.json (suites[]: id, name, command, cwd, env, framework, default, source, notes, artifacts, + unknown keys) | project | repo-owned file, TestConfigFile (App/Core/TestSuiteConfig.swift:147-224) | Tests tab refresh/'Look for tests' (append only); General 'Set up' → Look; MCP test_detect/test_update; hand edit. NO in-app editor. | yes |
| Run logs and history (history.json + logs/<config>-<stamp>.log, 10 per config) | project | ~/Library/Application Support/Uncoil/projects/<id>/run/ (RunRegistry.swift:143-215,290-296) | never by the user; pruned automatically | yes |
| Test results (<suite>.json, last record only) | project | ~/Library/Application Support/Uncoil/projects/<id>/tests/ (TestRegistry.swift:157-159,394-416) | never by the user | yes |
| Grants runs.read / runs.write / runs.control (also gate test_* actions) | session | SessionRecord.capabilities / SessionPreset capabilities; defaults in PolicyEngine.swift:41-42 | Settings › Privacy per-session advanced toggles (PrivacySettingsPages.swift:198-212); Settings › Agents presets editor Grants (AgentSettingsPages.swift:683-696); explained in onboarding (OnboardingPlatformSteps.swift:264-269) |  |
| Notification event 'Errors and problems' (.problem) covering .runtime and .testFailure | global | SettingsStore.notifications (NotificationPrefs.swift:10-60) | Settings › Notifications |  |
| GitHub token ('github-token') | account | Keychain (GitHubIssues.swift:57,160) | Settings › Uncoil › GitHub (per Issues empty-state copy) |  |
| Default provider (settings.defaultProvider) + agent prompt language | global | SettingsStore | Settings › Agents; Settings › General language |  |
| Readiness/poll tunables: readinessTimeout 60s, survivalGrace 2s, containerPollInterval 5s, logTailLimit 32k/64k, liveCaseLimit 500, artifact limit 200, failureLimit 10, keptRunsPerConfiguration 10 | global | hardcoded (RunRegistry.swift:166,243-251; TestRegistry.swift:148-150; TestArtifacts.swift:47; TestRepair.swift:20) | code only | yes |
| ProjectPageFreshness.window = 90s (tab availability cache) | global | hardcoded (ProjectPageStore.swift:11) | code only | yes |
| Maestro output dir '.maestro-output', xcodebuild destination 'platform=macOS,arch=arm64', static site port 8080, Django port 8000, DerivedData path '.build-cache/DerivedData' | global | hardcoded in detectors (RunDetection.swift:157-161,345-349,392-396; TestDetection.swift:71-73,183,206) | code only; users edit the generated command afterwards | yes |
| UI-test launch args -run-start, -tests-run, -tests-step, -issues-expand, -project-area | session | LaunchConfig.swift:38-47,106-110 | command line (ui-testing only) |  |

### Visibility gates

- `App/Core/ProjectPageStore.swift:118; App/Core/ProjectAreaAvailability.swift:92` — Run tab exists iff RunConfigFile.load(root).configurations non-empty → the whole Run tab (and therefore its empty state, Detect and New buttons)
- `App/Core/ProjectPageStore.swift:119; App/Core/ProjectAreaAvailability.swift:93` — Tests tab exists iff TestConfigFile.load(root).suites non-empty → the whole Tests tab
- `App/Core/ProjectPageStore.swift:117; App/Core/GitHubIssues.swift:263-265; App/Core/ProjectAreaAvailability.swift:94` — Issues tab exists iff GitHubRepoDiscovery.hasRepository (root or one level down has a .git with a GitHub remote) → the whole Issues tab; the offer for it is non-actionable (ProjectAreaAvailability.swift:71-76)
- `App/Core/ProjectPageStore.swift:11,74-79; App/UI/ProjectAreaOffers.swift:109; App/UI/ProjectDashboardView.swift:81-84,199-202` — Area facts recomputed only when loadedAt is nil or ≥90s old, or after an offer's onChanged; MCP writes never invalidate → when a newly written run.json/tests.json turns into a tab
- `App/Core/ProjectAreaAvailability.swift:106-108; App/UI/ProjectDashboardView.swift:85` — Selected area falls back to General when its fact goes false → deleting the last configuration/suite ejects the user from the tab on next refresh
- `App/UI/ProjectAreaOffers.swift:19-23; App/Core/ProjectAreaAvailability.swift:99-101` — 'Set up' offers listed for every area not present, minus Tasks → discoverability of Run/Tests/Issues
- `App/UI/ProjectDashboardView.swift:160` — Run tab green dot iff runningCount(project) > 0 → only 'running' is surfaced on the tab; failed/starting are not
- `App/UI/ProjectRunView.swift:178` — Session header run button iff defaultConfiguration != nil (flagged default, or exactly one config) → session.runButton, spinner
- `App/UI/ProjectRunView.swift:212` — Session header log button iff state.logFileURL != nil → session.runLogsButton; its tint = container health degraded
- `App/UI/ProjectRunView.swift:220-221; App/UI/SessionDetailView.swift:150-157 vs 278-284` — onOpenLogs navigates only when SessionHeaderBar received onOpenProject (main screen yes, split pane no) → whether 'Open the log' does anything in a pane
- `App/UI/ProjectRunView.swift:402-405` — Run card drawer iff status != idle || issue != nil || containers non-empty || logTail non-empty → status bar, output, issue banner, container strip
- `App/UI/ProjectRunView.swift:355,380` — Restart glyph only while running/starting; trash disabled while running/starting → secondary controls
- `App/UI/ProjectRunView.swift:436` — Preview chip iff status == running && previewURL parses → run.preview.<id>
- `App/Core/RunRegistry.swift:395; App/Core/DockerStatus.swift:60-70,160-167` — Container polling only when the command string contains 'docker compose'/'docker-compose' or 'docker run' with --name → container strip and degraded tint
- `App/UI/ProjectRunView.swift:412-421,694-702` — Live 3-line pulse iff !showLog && logTail non-empty && status != idle; stdin field iff running/starting → drawer content
- `App/UI/ProjectTestsView.swift:115` — Suite card drawer iff isRunning || latest != nil → summary bar, steps
- `App/UI/ProjectTestsView.swift:52-58` — Red suites auto-expand once per project appearance → expanded set
- `App/UI/TestStepList.swift:88,63-65` — Filter chips clickable iff summary.isDetailed; default filter = failed when failed > 0 → tests.filter.* interactivity
- `App/UI/TestStepList.swift:193-197,135-137` — Suite-level 'Fix with agent' iff !didPass && (failedCount == 0 || failedCount == cases.count) && project != nil → tests.repair.<suite>
- `App/UI/TestStepList.swift:367-376` — Per-row wand iff outcome == failed && onRepair (project) non-nil → tests.step.repair.<case>
- `App/UI/TestStepList.swift:138-152` — Output disclosure iff cases empty && logTail non-empty; step rows iff isDetailed && cases non-empty → drawer content
- `App/UI/Components/TestSummaryBar.swift:102` — Zero tallies hidden while live → CountChips
- `App/UI/ProjectIssuesView.swift:61-74,109,182-189,257` — Issues: label filter iff labels non-empty; skeleton iff !hasLoadedOnce; empty-state copy depends on problems; 'Open on GitHub' iff htmlURL; repository summary iff >1 repo → Issues tab chrome
- `App/UI/MainWindow.swift:908-911; App/Core/RunRegistry.swift:238; App/Core/TestRegistry.swift:139` — Attention notification sent only if kind.notificationEvent != nil && projectID != nil && sessionID != nil → run/test failures never notify
- `App/UI/SidebarView.swift:166-171; App/UI/MenuBarMonitorView.swift:174-182` — Attention row tap: sessionID → session, else projectID → project (General) → run/test rows never open the Run/Tests tab
- `App/ControlPlane/RunsHandler+Tests.swift:16-32; App/ControlPlane/RunsHandler.swift:24-53,70-80` — MCP test_* actions require runs.read/write/control; run actions same; project_id override requires sessions.cross_project → agent access
- `CLAUDE.md (MCP section)` — Control plane gated off under -ui-testing unless -control-plane → agent side in fixtures

### Open questions

- Is a test suite a kind of run (one file, one tab, one grant, one repair path) or a separate concept? The code says both (RunsHandler+Tests.swift:16-20 vs TestRegistry.swift:112-115).
- Who is the intended author of .uncoil/run.json and .uncoil/tests.json — the person or the agent? Run assumes the person (full editor), Tests assumes the agent (no editor).
- Should 'Fix with agent' ever interrupt a live session (RunRepair) or always open a new one (TestRepair, Issues)? The user cannot currently tell which will happen.
- Should Attention rows for run/test failures deep-link to the tab and fire notifications, and should a repaired run auto-resolve its row like a green suite does?
- Is 'source: detected|user|agent' a user-facing concept worth a badge, or internal provenance? It is shown raw today.
- Is 'Dev Preview' meant to become an in-app surface (web view, simulator, device) or stay a process manager that opens a browser? RUN_PREVIEW.md and the tab name disagree.
- Should Pull Requests and Issues share one GitHub area with one repository-discovery rule (root vs root+one level)?
- Is 'Run' intended to be a project-level affordance (project header, palette) rather than a button on every session header?
- How should a project's stack be represented once (framework list, package manager, Xcode container, Docker) so Run, Tests, offers and future features read the same facts?
- Should the UI expose the MCP-only 'replace detected suggestions' reset, or should that stay agent-only?

---

## Tasks area and task orchestration (Project › Tasks tab, dispatch/orchestrator/merge/commit sheets, App/Tasks models, uncoil_tasks MCP surface)

From the user's chair, Tasks is a tab on the project page that appears only once a TODO.md exists. It parses every TODO.md-style file in the project into checkbox tasks and shows them in four modes (List, Kanban, Sessions, Document). The everyday job is "give this checkbox to an agent": a Start button on a list row opens a session for the chosen CLI and types a prompt into it. Around that one job the screen exposes a large vocabulary the user did not ask for — roles (Owner/Implementer/Review/Test/Observer/Orchestrator), assignments, execution states (12), claim states, worktrees, fingerprints and relinking, presets, permission profiles, per-provider model/effort/working-mode pickers, an "orchestrator" that computes a plan it never runs, and a merge gate governed by a per-project settings file that has no UI. Agents get a parallel 36-action MCP tool that can do more to task state than the UI can (claim, report progress, report tests, submit reviews), so what the user sees in the badges depends on whether the agent happened to be launched through a path whose prompt mentions the MCP tool. The result is one screen carrying five ways to start an agent, two prompt builders, two board models, five policy objects, and a state machine most of whose states nothing in the app ever enters.

### Findings

#### [CRITICAL] T1 — Eight verbs start an agent on a task, through two different pipelines with different prompts, state handling and attention behaviour

*Category:* duplicate-concept

- `App/UI/ProjectTasksView.swift:786` — Button("Start With \(provider.displayName)") { sendToAgent(task, role: .implementer, reuseSession: false, provider: provider) }
- `App/UI/ProjectTasksView.swift:1134` — Button("Start with \(settings.defaultProvider.displayName) (Quick)") { sendToAgent(task, role: .implementer, reuseSession: true) }
- `App/UI/ProjectTasksView.swift:1137` — Menu("Start in a new session") {
- `App/UI/ProjectTasksView.swift:1133` — Button("Send to Agent…") { dispatchTarget = (task, document) }
- `App/UI/ProjectTasksView.swift:1173` — Button("Run with Orchestrator") { sendToAgent(task, role: .orchestrator, reuseSession: false) }
- `App/UI/ProjectTasksView.swift:330` — Text("Start tasks…")
- `App/UI/ProjectTasksView.swift:1179` — Button("Request Review") { reviewOrTest(task, role: .reviewer, state: .reviewRequested) }
- `App/UI/ProjectTasksView.swift:1384` — private func prompt(for task: ProjectTask, role: TaskAgentRole) -> String {
- `App/Tasks/TaskDispatch.swift:84` — static func prompt(_ context: Context) -> String {
- `App/UI/ProjectTasksView.swift:1291` — AttentionStore.shared.report(             kind: .input,

**Why it matters:** The quick paths (inline Start, Quick, new-session submenu, Run with Orchestrator, Request Review, Run Tests, Start tasks…) go through sendToAgent with a 4-line prompt that never mentions uncoil_tasks or the task id; the sheet path goes through finishDispatch with TaskPromptBuilder's full rules and raises an extra attention row. A user cannot predict which behaviour they get from which verb, and every new option (model, worktree, preset) is added to only one of the two pipelines.

**Direction:** One start pipeline and one prompt builder; the sheet becomes the 'more options' disclosure of the same action rather than a second product.

#### [CRITICAL] T2 — The orchestrator is a facade: the plan is computed and persisted but never executed, 'Stop the Orchestrator' stops nothing, and its invisible settings gate every merge

*Category:* coupling

- `App/UI/ProjectTasksView.swift:1495` — store.store(plan)         orchestratorPlan = plan
- `App/UI/ProjectTasksView.swift:1327` — for task in tasks {             sendToAgent(task, role: .implementer, reuseSession: false,
- `App/Tasks/TaskOrchestrator.swift:185` — if input.settings.automaticReview {                 dispatches.append(PlannedDispatch(                     taskID: task.id, taskText: task.text, sourcePath: task.sourcePath,                     role: .reviewer,
- `App/UI/MenuBarMonitorView.swift:164` — private func stopOrchestrator(_ project: Project) {         let store = OrchestratorStore(projectID: project.id)         store.stopDispatching()
- `App/Tasks/TaskOrchestrator.swift:414` — func update(settings: OrchestratorSettings) {
- `App/Tasks/TaskDelivery.swift:218` — var blockers = mayComplete(tests: tests, requiresTests: settings.automaticTests)         let latestReview = reviews.max { $0.finishedAt < $1.finishedAt }         if settings.automaticReview {             switch latestRev
- `App/UI/TaskMergeSheet.swift:24` — private var settings: OrchestratorSettings {         OrchestratorStore(projectID: project.id).settings
- `App/UncoilApp.swift:167` — MenuBarMonitorEngine.summary(             statuses: sessionStore.statuses,             attention: attention.items         )

**Why it matters:** markDispatched, recover, TaskLeaseKeeper and update(settings:) have no callers in App; `queuedTaskCount` is computed in AttentionRefresher (AttentionCenter.swift:595) but never passed to the summary. Meanwhile the defaults of OrchestratorSettings (automaticReview = true, automaticTests = true) decide that every hand-run task's Merge sheet shows 'No test result.' and 'No review result.' with no way for the user to see or change that. The word 'orchestrator' appears in a role, a menu, a preset, a grant and a sheet class, each meaning something else.

**Direction:** Either ship an executor and a visible policy screen, or delete the plan store, the menu item and the settings-driven merge gate and let the sheet be what it is: multi-select start.

#### [HIGH] T3 — Per-provider launch options (model, effort, working mode, preset, permission profile, account) are exposed inside the task flow, twice, and two of them do nothing

*Category:* agent-leak

- `App/UI/TaskDispatchSheet.swift:209` — pickerRow(String(localized: "Agent")) {
- `App/UI/TaskDispatchSheet.swift:228` — pickerRow(String(localized: "Profile")) {
- `App/UI/TaskDispatchSheet.swift:277` — pickerRow(String(localized: "Working mode")) {
- `App/UI/TaskDispatchSheet.swift:291` — pickerRow(String(localized: "Preset")) {
- `App/UI/TaskDispatchSheet.swift:309` — pickerRow(String(localized: "Permission profile")) {                     Text(                         request.permissionProfile.isEmpty                             ? "session default"                             : "\(re
- `App/UI/TaskOrchestratorSheet.swift:185` — if !capabilities.models.isEmpty {                     Picker("", selection: Binding(                         get: { launch.model }, set: { launch.model = $0 }
- `App/UI/ProjectTasksView.swift:1266` — record = projectStore.createSession(                 projectID: project.id,                 provider: request.provider,                 accountID: request.accountID,                 title: String(localized: "\(request.pr
- `App/Core/ProjectStore.swift:439` — record.capabilities = Self.defaultSessionCapabilities
- `App/Core/Models.swift:336` — case .dangerouslySkipPermissions: "Dangerously Skip Permissions"

**Why it matters:** The dispatch sheet duplicates Settings › Agents › Agent Behavior (working mode) and Session Presets, then the orchestrator sheet duplicates the dispatch sheet's model/effort/mode row with a different default (nil instead of settings.workingMode). `presetID` is never read after applyPreset, `permissionProfile` only becomes a line of prompt text ('Permission profile: …', TaskDispatch.swift:100-102), and the created session keeps the global capability defaults — so '3 grants' on screen grants nothing. Working-mode labels are the CLIs' own vocabulary ('Approve for Me', 'Dangerously Skip Permissions') surfacing in a task screen.

**Direction:** Keep provider (and maybe account) at the task level; move model/effort/mode to the provider's own defaults and drop Preset/Permission profile from the sheet until they are honoured.

#### [HIGH] T4 — Execution state never advances for UI-started agents; badges depend on the agent calling MCP

*Category:* visibility-logic

- `App/UI/ProjectTasksView.swift:1374` — metadata.setState(.agentStarting, assignmentID: assignment.id)
- `App/UI/ProjectTasksView.swift:1404` — case .owner, .implementer, .observer:             return """             Carry out the task below, under \(location). Tick the checkbox in TODO.md when you are done.
- `App/ControlPlane/TasksHandler.swift:81` — case "report_task_progress":             return requiring("tasks.write", grants, request) {                 setExecutionState(request, caller: caller, state: .running)
- `App/Tasks/ProjectTaskModels.swift:194` — case waitingForPermission     case waitingForUser
- `App/UI/ProjectTasksView.swift:772` — if !task.isDone, assignments.isEmpty {                 Menu {

**Why it matters:** Only agentStarting/blocked/queued/completed are set from the UI; running, testsFailing, reviewRequested come from MCP; waitingForPermission, waitingForUser and failed are set by no code path at all (grep over App). The session already has a live AgentSessionStatus (running/waiting) from hooks, but the task never reads it. A task started with 'Start With Claude' shows 'Agent starting' until the user manually completes it, and the inline Start disappears after the first assignment, so a second run needs the context menu.

**Direction:** Derive the task's live state from the assigned session's status; drop the states nothing enters.

#### [HIGH] T5 — Reattach is unreachable when a tracked task is reworded (inferred from code)

*Category:* navigation

- `App/Tasks/ProjectTaskMetadataStore.swift:193` — /// Marks the assignments whose task could not be re-resolved. They keep     /// pointing at their last known task so the user can decide.
- `App/UI/ProjectTasksView.swift:1214` — if assignments.contains(where: \.needsRelinking) {             Divider()             Button("Reattach to This Task") {
- `App/UI/ProjectTasksView.swift:1129` — private func cardActions(_ task: ProjectTask, in document: TaskDocument) -> some View {
- `App/Core/AttentionCenter.swift:617` — guard let document = documents.first(where: { $0.task(id: taskID) != nil }),                       let task = document.task(id: taskID) else {                     // The task is gone from the file; the relink row is what
- `App/UI/AttentionCenterView.swift:152` — Button(action: onResolve) {

**Why it matters:** `assignments` inside cardActions is `metadata.assignments(for: task.id)` for the row's current id. A reworded task gets a new id, so no current row owns the flagged assignments; the old id no longer parses, so no row shows the Reattach entry. The 'Task link lost' attention row offers only the generic resolve button. The concept (fingerprint, relink) is fully exposed to the user, but the repair action has no reachable surface in the exact case the concept exists for.

**Direction:** Make relink a picker on the attention row / Sessions view ('which task is this?'), or drop the visible concept and re-bind silently by similarity.

#### [HIGH] T6 — A user meets ~20 named concepts and ~50 enum values to move one checkbox to one agent

*Category:* concept-overload

- `App/Tasks/ProjectTaskModels.swift:243` — enum TaskAgentRole: String, Equatable, Codable, CaseIterable, Identifiable {     /// Accountable for the task, not necessarily doing the work.     case owner     case implementer     case reviewer     case tester     ///
- `App/UI/ProjectTasksView.swift:1150` — Menu(record.displayTitle) {                     ForEach(TaskAgentRole.allCases) { role in
- `App/Tasks/TaskClaim.swift:7` — enum TaskClaimState: String, Equatable, Codable, CaseIterable, Identifiable {     case available     case claimed     case running     case released     case expired     case blocked     case completed
- `App/Tasks/TaskBoardMapping.swift:11` — enum Lane: String, Equatable, Codable, CaseIterable, Identifiable {         case backlog         case todo         case inProgress         case blocked         case review         case done         /// A heading that mat
- `App/Tasks/TaskBoardMapping.swift:254` — enum Status: String, Equatable, Codable, CaseIterable, Identifiable {         case all         case open         case done         case assigned         case unassigned         case running         case awaitingReview   
- `App/Core/AttentionCenter.swift:12` — // MARK: Task rows     case taskAssigned     case reviewRequested     case changesRequested     case taskBlocked     case taskFailed     case taskCompleted     case mergeReady     /// A task's session lost its link to a 

**Why it matters:** Role (6), execution state (12), claim state (7), filter status (8), lane (7), default columns (5, unused), attention kinds (8 task + 1 reported), view modes (4), plus source, assignment, worktree, fingerprint, preset, permission profile, profile, model, effort, working mode, auto-start, wave. Owner and Observer are selectable in two menus yet the quick prompt tells an Observer to 'Carry out the task' (ProjectTasksView.swift:1404-1409). Every one of these vocabularies is a partially overlapping projection of 'is anyone on this, and is it done?'.

**Direction:** Collapse to one visible status vocabulary and two roles (do / review); keep the rest internal.

#### [HIGH] T7 — Four view modes with four different capability sets; the Document view cannot start anything and Kanban refuses the aggregate

*Category:* navigation

- `App/UI/ProjectTasksView.swift:577` — private func taskRow(_ task: ProjectTask, in document: TaskDocument) -> some View {
- `App/UI/ProjectTasksView.swift:822` — .contextMenu { cardActions(task, in: documentFor(task)) }         .accessibilityIdentifier("tasks.row.\(task.id)")
- `App/UI/ProjectTasksView.swift:1010` — .contextMenu { cardActions(task, in: document) }         .accessibilityIdentifier("tasks.card.\(task.id)")
- `App/UI/ProjectTasksView.swift:868` — Text("Kanban works on a single source; pick a TODO.md above.")
- `App/UI/ProjectTasksView.swift:737` — Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
- `App/UI/ProjectTasksView.swift:1051` — private var sessionsView: some View {         let grouped = Dictionary(grouping: metadata.document.assignments, by: \.sessionID)

**Why it matters:** Document: toggle/rename/reveal, no context menu, no Start. List: Start + full context menu, but the checkbox glyph is not clickable and toggling is only in Document or via 'Complete'. Kanban: drag moves the file, context menu, but single-source only. Sessions: read-only mirror of the sidebar. The user has to know which mode owns which verb; the Sessions mode duplicates a list the sidebar already shows, while the sidebar and session header show no task at all (`assignments(forSession:)` has no caller outside App/Tasks).

**Direction:** One row component with one action set in every mode; Sessions mode becomes a chip on the session, not a mode.

#### [HIGH] T8 — Merge and Commit are two finishing paths with different, hidden preconditions; the Document checkbox bypasses the completion gate the context menu enforces

*Category:* visibility-logic

- `App/UI/ProjectTasksView.swift:1201` — if assignments.contains(where: { $0.worktreePath != nil }) {             Button("Merge…") { mergeTarget = task }         }         Button("Commit / PR…") {
- `App/UI/TaskMergeSheet.swift:259` — guard let worktree = worktreePath else {             loading = false             failure = "The task has no worktree; there is no branch to merge."
- `App/UI/ProjectTasksView.swift:1738` — private func complete(_ task: ProjectTask, in document: TaskDocument) {         let blockers = results.failingTestBlockers(taskID: task.id)
- `App/UI/ProjectTasksView.swift:584` — Button {                     toggle(task, in: document)
- `App/Tasks/TaskDispatch.swift:19` — var createsWorktree = false

**Why it matters:** The default start never creates a worktree (createsWorktree defaults false and only the sheet exposes it), so most users never see 'Merge…' and the onboarding sentence 'hands back a diff you review before anything merges' describes the minority path. 'Commit / PR…' is always shown and commits at the project root when there is no worktree. The gate that refuses a tick on failing tests is enforced in 'Complete' and in MCP complete_task (TasksHandler.swift:640-652) but not on the Document view checkbox.

**Direction:** One 'Finish' action whose content depends on whether there is a branch; gate ticking in one place.

#### [MEDIUM] T9 — Labels are inconsistent or mistranslated across the task vocabulary

*Category:* terminology

- `App/Tasks/TaskBoardMapping.swift:269` — case .open: String(localized: "On")
- `App/Tasks/ProjectTaskModels.swift:419` — id: "open", title: "On",
- `App/UI/TaskCreateSheet.swift:87` — field(String(localized: "Title")) {                     Picker("", selection: $headingPath) {                         Text("End of file (no heading)").tag([String]())
- `App/UI/TaskDispatchSheet.swift:228` — pickerRow(String(localized: "Profile")) {
- `App/UI/Settings/SettingsView.swift:132` — case .accounts: String(localized: "Accounts")
- `App/Tasks/ProjectTaskModels.swift:260` — case .reviewer: String(localized: "Review")         case .tester: String(localized: "Test")
- `App/Tasks/TaskOrchestrator.swift:190` — dependsOn: [task.id], serialReason: "uygulama bitince"
- `App/Tasks/ProjectTaskModels.swift:289` — debugDescription: "bilinmeyen rol: \(raw)"
- `App/UI/TaskDispatchSheet.swift:439` — Button(request.autoStart ? "Send and start" : "Send (hold)")

**Why it matters:** 'On' (Turkish 'Açık' rendered as On instead of Open) is the second filter chip a newcomer reads and the default column title. 'Title' labels the heading picker. The same thing is 'Profile' in the sheet and 'Accounts' in Settings, next to a different 'Permission profile'. Review appears as role 'Review', action 'Request Review', filter 'Awaiting review', state 'Review requested', lane 'Review', attention 'Review requested'. Turkish leftovers survive in plan text and decode errors.

**Direction:** One glossary pass: Open/Done, Heading, Account, and a single word per concept.

#### [MEDIUM] T10 — Task start menus list all seven agent CLIs whether installed or not, unlike the sidebar launcher

*Category:* agent-leak

- `App/UI/ProjectTasksView.swift:785` — ForEach(AgentProvider.agents, id: \.self) { provider in                         Button("Start With \(provider.displayName)") {
- `App/Core/Models.swift:40` — static let agents: [AgentProvider] = allCases.filter(\.isAgent)
- `App/UI/SidebarView.swift:709` — ForEach(settings.launcherProviders) { provider in
- `App/Core/SettingsStore.swift:282` — var launcherProviders: [AgentProvider] {         LauncherPrefs.resolved(launcher, installed: installedProviders)

**Why it matters:** Inline Start, 'Start in a new session', the dispatch sheet and the orchestrator sheet each offer Claude, Codex, Gemini, OpenCode, Grok, Hermes, Cursor; choosing one that is not on the machine yields a session that fails at launch. The sidebar already solved this with an installed-only list.

**Direction:** Use the same launcher provider list everywhere.

#### [MEDIUM] T11 — 'Quick' start injects the prompt into an arbitrary live session

*Category:* coupling

- `App/UI/ProjectTasksView.swift:1356` — let existing = reuseSession             ? projectStore.sessions(for: project.id).first(where: {                 $0.provider == provider && sessionStore.status(of: $0.id) != .terminated             })             : nil
- `App/UI/ProjectTasksView.swift:1379` — message = String(localized: "\(task.displayText.prefix(60)) → \(provider.displayName) (\(record.displayTitle))\(launchNote)")

**Why it matters:** The first non-terminated session of the default provider — possibly mid-turn on another task, sleeping, or a handoff — receives a new task prompt; the user learns which one from the banner after the fact. The dispatch sheet exposes the same choice explicitly (Target), so the shortcut duplicates the sheet with less information.

**Direction:** Quick = new session, or show the target session name in the menu item.

#### [MEDIUM] T12 — Two board models and three policy objects are persisted or defined but never used

*Category:* duplicate-concept

- `App/Tasks/ProjectTaskModels.swift:457` — var columns: [TaskBoardColumnMapping] = TaskBoardColumnMapping.defaults
- `App/Tasks/ProjectTaskModels.swift:416` — /// The default board: file state on the outside, execution state in between.     static let defaults: [TaskBoardColumnMapping] = [
- `App/Tasks/TaskBoardMapping.swift:232` — enum BoardMode: String, Equatable, Codable {         case fileBacked         case virtual
- `App/Tasks/TaskDelivery.swift:8` — struct TaskWorktreePolicy: Equatable, Codable {
- `App/Tasks/TodoDiscovery.swift:33` — /// User-tunable scan rules, stored per project.     struct Rules: Equatable, Codable {
- `App/Tasks/TodoSourceStore.swift:85` — rules: TodoDiscovery.Rules = .default
- `App/Tasks/ProjectTaskModels.swift:460` — /// Opt-in: write a portable HTML-comment id into the file.     var portableIDsEnabled = false

**Why it matters:** metadata.json ships a 5-column execution-state board the Kanban never reads (it uses heading lanes); TaskWorktreePolicy, TodoDiscovery.Rules ('stored per project' — never stored), boardMode.virtual and portableIDsEnabled are seams with no surface. Each is a future setting waiting to sprawl, and each is one more shape a reader of the code has to reconcile with what the screen shows.

**Direction:** Delete or quarantine reserved concepts until they have a surface.

#### [MEDIUM] T13 — Attention rows for one dispatch are raised twice, and one of them wears the wrong kind

*Category:* visibility-logic

- `App/UI/ProjectTasksView.swift:1291` — AttentionStore.shared.report(             kind: .input,             title: String(localized: "\(project.name) › \(task.displayText)"),             detail: String(localized: "Assigned to the \(record.displayTitle) session
- `App/Core/AttentionCenter.swift:35` — case .input: String(localized: "Waiting for a reply")
- `App/Tasks/TaskAttention.swift:60` — case .assigned, .agentStarting, .running:                     items.append(item(                         .taskAssigned, task: task, title: who,
- `App/Tasks/TaskAttention.swift:128` — if task.isDone {                 items.append(item(                     .taskCompleted, task: task, title: title,

**Why it matters:** A sheet dispatch produces a reported 'Waiting for a reply' row (priority 3, warn colour) plus a derived 'An agent was assigned to the task' row for the same event; the quick path produces only the derived one. Every ticked task with any assignment also becomes a 'Task done' row on each scan. Task noise competes with genuine permission/input waits in the same list and in the menu bar counters.

**Direction:** Attention should derive task rows from one source; assignment is not an attention event.

#### [MEDIUM] T14 — Entry into Tasks depends on a file name and a one-time card; alternates are undocumented and the palette shortcut is a bare '+'

*Category:* discoverability

- `App/Tasks/TodoDiscovery.swift:32` — static let defaultFileNames: Set<String> = ["TODO.md", "todo.md", "TODOS.md"]
- `App/UI/ProjectDashboardView.swift:56` — if area == .tasks, hasTaskSources {
- `App/Tasks/TodoStarter.swift:49` — /// Which projects have already been offered a `TODO.md` and said no. /// /// Per project, and permanent
- `App/Core/PaletteModel.swift:160` — for prefix in ["+", "todo:", "task:"] where trimmed.lowercased().hasPrefix(prefix) {
- `App/UI/ProjectTasksView.swift:480` — Text("No TODO.md found in this project")

**Why it matters:** A project with TASKS.md or docs/backlog.md has no Tasks tab and no way to say so (Rules has no UI). Dismissing the hint hides the feature from that project forever. The in-tab empty state is unreachable because the tab is hidden without sources. The palette capture prefix is only learned by accident.

**Direction:** Let the project point at its task file(s); make the offer reversible.

#### [MEDIUM] T15 — Tasks and GitHub Issues are two work-item systems with two unrelated 'send to agent' paths and no shared state

*Category:* duplicate-concept

- `App/UI/ProjectIssuesView.swift:339` — private func sendToAgent(_ issue: GitHubIssue) {         let record = projectStore.createSession(             projectID: project.id,             provider: settings.defaultProvider,             accountID: nil,            
- `App/UI/ProjectIssuesView.swift:348` — await TerminalRegistry.shared.submitText(                 prompt, for: record.id, provider: record.provider
- `App/UI/ProjectTasksView.swift:1438` — SessionPromptDelivery.deliver(             prompt, to: record, project: project,

**Why it matters:** Issues bypasses SessionPromptDelivery, accounts, assignments, roles and attention; Tasks has all of them. Both live as sibling tabs on the same project page. A user who starts from an issue gets none of the task tracking, and a task cannot reference an issue.

**Direction:** One 'work item → agent' primitive shared by tasks, issues, blueprints and palette ask.

#### [LOW] T16 — reviewOrTest ignores its state argument and 'Run Tests' marks the tester as merely 'Running'

*Category:* other

- `App/UI/ProjectTasksView.swift:1382` — private func reviewOrTest(         _ task: ProjectTask,         role: TaskAgentRole,         state: ProjectTaskExecutionState     ) {
- `App/UI/ProjectTasksView.swift:1395` — _ = state

**Why it matters:** Small, but it shows the state machine has more values than the UI has intentions for; the caller passes .testsFailing for a run that has not happened yet.

**Direction:** Remove the parameter; let results drive the state.

#### [LOW] T17 — Handoff to a new session leaves the task assignment on the old session

*Category:* coupling

- `TODO.md:369` — - [ ] Re-point the task-session relationship at the new session.
- `App/Usage/HandoffService.swift:317` — let created = projectStore.createSession(             projectID: project.id,             provider: destination.provider,             accountID: destination.accountID,

**Why it matters:** A relationship the Tasks tab surfaces prominently (role buttons, Sessions view, attention) silently goes stale through a flow owned by another subsystem.

**Direction:** Assignments should follow the session lineage (handoff, child) automatically.

#### [LOW] T18 — Menu bar carries three task shortcuts, one of which acts on nothing, behind a settings toggle

*Category:* settings-sprawl

- `App/UI/MenuBarMonitorView.swift:153` — Menu("Stop the Orchestrator") {
- `App/UI/Settings/MenuBarSettingsPage.swift:124` — SettingsLabel(title: String(localized: "Task shortcuts"), detail: String(localized: "Board, task session, orchestrator."))

**Why it matters:** 'Task Board' opens the project page, not the Tasks tab (MainRoute .project); 'Stop the Orchestrator' clears a stored plan with no executor; Settings describes both as if they were live controls.

**Direction:** Route to the tab; remove the stop item with T2.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Tasks tab (project area) | tab | `App/UI/ProjectDashboardView.swift` | Project header area tab (ProjectDashboardView.swift:56, :139); Menu bar › Task Board › <project> (MenuBarMonitorView.swift:136-142, routes to the project, not the tab); Onboarding Tasks step text 'Ope |
| Tasks toolbar + source status strip | toolbar | `App/UI/ProjectTasksView.swift` | Always visible when sources exist |
| Message banner | banner | `App/UI/ProjectTasksView.swift` | Set by ~20 code paths via `message =` |
| Document view | panel | `App/UI/ProjectTasksView.swift` | Mode picker › Document |
| List view + filter bar | panel | `App/UI/ProjectTasksView.swift` | Default mode (ProjectTaskViewPreferences.mode = .list, TaskBoardMapping.swift:239) |
| Kanban view | panel | `App/UI/ProjectTasksView.swift` | Mode picker › Kanban |
| Sessions view | panel | `App/UI/ProjectTasksView.swift` | Mode picker › Sessions |
| Card context menu (cardActions) | menu | `App/UI/ProjectTasksView.swift` | Right-click on list row (:822); Right-click on kanban card (:1010) |
| TaskDispatchSheet 'Send to agent' | sheet | `App/UI/TaskDispatchSheet.swift` | Context menu › Send to Agent…; List row Start menu › Send with Details… |
| TaskOrchestratorSheet 'Hand tasks to agents' | sheet | `App/UI/TaskOrchestratorSheet.swift` | Toolbar 'Start tasks…' (ProjectTasksView.swift:325-337, help 'Pick the open tasks, pick an agent, start them together') |
| TaskMergeSheet 'Merge' | sheet | `App/UI/TaskMergeSheet.swift` | Context menu › Merge… (only when an assignment has a worktree) |
| TaskCommitSheet 'Commit — {task}' | sheet | `App/UI/TaskCommitSheet.swift` | Context menu › Commit / PR… (always offered) |
| TaskCreateSheet 'New task' | sheet | `App/UI/TaskCreateSheet.swift` | Toolbar 'New task' (disabled when no document is selected) |
| TaskDiffSheet 'Change' | sheet | `App/UI/TaskDiffSheet.swift` | Context menu › Show Diff; Stale-edit sheet › Compare |
| TaskStaleEditSheet 'The edit could not be applied' | sheet | `App/UI/TaskStaleEditSheet.swift` | Any file write from the Tasks tab that returns .conflict (ProjectTasksView.swift:1698-1702) |
| TodoHintCard on project General page | empty-state | `App/UI/ProjectDashboardView.swift` | Project General page when !hasTaskSources && !dismissed (:180-191) |
| Onboarding › Tasks step | screen | `App/UI/Onboarding/OnboardingProjectSteps.swift` | First-run flow step 'tasks'; -onboarding-step tasks |
| Onboarding › Capabilities step (task groups) | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | First-run flow step 'capabilities' |
| Menu bar › task section | menu | `App/UI/MenuBarMonitorView.swift` | Menu bar icon |
| Attention Center task rows | row | `App/Tasks/TaskAttention.swift` | Attention Center panel, menu bar counters, notifications |
| Command palette task capture | row | `App/Core/PaletteModel.swift` | Command palette when the current project has task sources |
| uncoil_tasks MCP tool (agent-facing) | other | `App/ControlPlane/TasksHandler.swift` | Any agent session with the control plane |

### Concepts

- `U` **Task (checkbox line)** — One `- [ ]` line in a TODO.md-style file, with its continuation block, heading chain, nesting and a fingerprint (ProjectTaskModels.swift:113-183). *Overlaps:* GitHub Issue (ProjectIssuesView) — a second kind of work item with its own 'send to agent'
- `U!` **Source / TODO file** — A discovered file named TODO.md, todo.md or TODOS.md anywhere in the project except dependency dirs (TodoDiscovery.swift:22-32). 'All Sources (Aggregate)' merges them. *Overlaps:* Document view mode (also 'the file')
- `U` **View mode** — List / Kanban / Sessions / Document, persisted per project (TaskBoardMapping.swift:209-228). *Overlaps:* Sessions mode duplicates the sidebar's session list
- `U` **Execution state** — 12-value enum of what Uncoil believes an assigned agent is doing: unassigned, queued, assigned, agentStarting, running, waitingForPermission, waitingForUser, testsFailing, reviewRequested, blocked, failed, completed (ProjectTaskModels.swift:188-240). Shown as 'Agent starting', 'Waiting for you', etc. *Overlaps:* Claim state, Filter status, Lane, Board column mapping, AgentSessionStatus (session-level running/waiting)
- `i!` **Claim state / lease** — 7-value takeability enum (available, claimed, running, released, expired, blocked, completed) derived from a 15-minute lease plus execution states (TaskClaim.swift:7-105). Leases are only created via MCP claim_task. *Overlaps:* Execution state (isActive)
- `U` **Filter status** — 8 chips: all, open ('On'), done ('Completed'), assigned, unassigned, running ('Agent running'), awaitingReview, blocked (TaskBoardMapping.swift:254-278). Also the vocabulary of MCP list_tasks_by_status. *Overlaps:* Execution state, Lane
- `U!` **Lane / board column** — Heading→lane recognition (Backlog, To do, In Progress, Blocked, Review, Done, Other) with per-heading override (TaskBoardMapping.swift:11-111). A second, unused board model `TaskBoardColumnMapping.defaults` ('On', 'Being worked on', 'Waiting', 'Problem', 'Done') is persisted in metadata.json (ProjectTaskModels.swift:405-447, :457). *Overlaps:* Execution state, TaskBoardColumnMapping (dead duplicate)
- `U!` **Assignment** — A (task, session, role) link stored in Uncoil metadata, with state, worktree, fingerprint and history (ProjectTaskModels.swift:318-367). Many-to-many by design. *Overlaps:* Claim/lease, Session parent/child relation, Handoff relation
- `U!` **Role** — What an agent was asked to do: owner, implementer, reviewer ('Review'), tester ('Test'), observer, orchestrator (ProjectTaskModels.swift:243-295). Affects only prompt wording, claim policy and whether a worktree is warranted. *Overlaps:* Session preset names ('Claude Worker', 'Codex Reviewer', 'Task Orchestrator'), 'Request Review'/'Run Tests' actions
- `U!` **Dispatch / Start / Send** — Starting an agent on a task. Five user-facing verbs with different semantics: inline 'Start With X', 'Start with X (Quick)' (reuses a live session), 'Start in a new session', 'Send to Agent…' (sheet), 'Start tasks…' (batch sheet), plus 'Run with Orchestrator', 'Request Review', 'Run Tests' which also create sessions. *Overlaps:* Sidebar launcher (SidebarView.swift:733), palette ask (MainWindow.swift:504-527), Issues 'send to agent' (ProjectIssuesView.swift:339-351), Blueprint runner (BlueprintCards.swift:24-38), MCP dispatch_task
- `U!` **Orchestrator** — Five different things share the word: (a) TaskAgentRole.orchestrator; (b) TaskOrchestrator.plan — pure wave/dependency/conflict planner (TaskOrchestrator.swift:106-209); (c) the 'Start tasks…' sheet, whose class is TaskOrchestratorSheet; (d) OrchestratorStore/OrchestratorSettings persisted per project; (e) built-in preset 'Task Orchestrator' and grant tasks.orchestrate (SessionPreset.swift:61-68). *Overlaps:* 'Start tasks…' sheet (no orchestrator wording in-sheet)
- `U` **Worktree** — Per-task git worktree under .uncoil-worktrees/, optional in the dispatch sheet; a precondition for 'Merge…' (:1201) and for MCP submit_task_for_merge. *Overlaps:* Session worktree (sidebar launcher per worktree), TaskWorktreePolicy (unused)
- `U!` **Fingerprint / relinking** — Strong/positional/text keys plus Dice similarity used to re-attach assignments after the file changes; unresolved ones are flagged (TaskFingerprint.swift:10-206). *Overlaps:* Handoff (TODO.md:369 'Re-point the task-session relationship at the new session' — not done)
- `U!` **Preset (SessionPreset)** — Named template (provider, extra args, prompt template, grantable capabilities, permission mode) meant for MCP create_child (SessionPreset.swift:3-8). Edited in Settings › Agents › Session Presets. *Overlaps:* Role, Working mode, Permission profile
- `U!` **Permission profile / grants** — The list of capability keys a session may use (PolicyEngine.defaultGrants). Shown in the dispatch sheet as 'session default' or '{n} grants' and injected into the prompt text; never applied to the created session. *Overlaps:* Preset.grantedCapabilities, Settings capability defaults, onboarding capability groups
- `U!` **Profile (account)** — An AccountProfile (isolated CLI config root). Called 'Profile' in the dispatch sheet, 'Accounts' in Settings (SettingsView.swift:132). *Overlaps:* 'Permission profile' in the same sheet
- `U!` **Model / Effort / Working mode (launch selection)** — Per-provider CLI flags detected from `--help` (AgentLaunchOptions.swift:47-126); working mode has 12 provider-specific values with labels like 'Dangerously Skip Permissions', 'Approve for Me' (Models.swift:273-344). *Overlaps:* Preset.permissionMode (a free-text label mapped onto working mode, TaskDispatchSheet.swift:466-471)
- `U` **Auto start / hold** — Whether the prompt is submitted or only typed into the terminal ('Send and start' vs 'Send (hold)'). *Overlaps:* Blueprint 'startsImmediately'
- `U` **Test result / Review verdict / Merge record** — Results recorded by agents through MCP (report_test_result, submit_task_review) or by the merge sheet; gate completion and merging (TaskDelivery.swift:71-259, TaskResultStore.swift). *Overlaps:* Project Tests tab (ProjectTestsView) — a separate test runner with no link to task test results
- `U!` **Conflict (two meanings)** — (1) A git merge-conflict region inside the TODO file, which makes it read-only (TaskGitStatus); (2) a stale-edit conflict when a patch hits a changed block (TodoEditor.write .conflict). Both surface as 'conflict' wording. *Overlaps:* Merge sheet 'Merge conflict' blocker (worktree)
- `i` **Wave / dependency / serial reason** — Planner output: tasks grouped into waves, ordered by mentions of 'after/before/once', serialised when they mention the same paths (TaskOrchestrator.swift:143-200). Never shown; plan.summary() has no callers.
- `i` **Heartbeat / recovery** — TaskLeaseKeeper and TaskOrchestrator.recover define staleness and recovery actions; neither is called from the app (only tests). *Overlaps:* AgentSessionStatus liveness
- `U` **Capture** — Palette shortcut to append a task line under a heading ('+', 'todo:', 'task:'). *Overlaps:* 'New task' sheet, MCP create_task

### Flows

- **Newcomer: first task to first agent** (7 steps) — friction: The default path uses a prompt that cannot report back, so the state badge the screen is built around never updates; the one visible affordance (Start) disappears after first use.
- **'Start with X (Quick)' from the context menu** (3 steps) — friction: 'Quick' silently injects a prompt into an unrelated running session; the user learns which one only from the banner afterwards.
- **'Send to Agent…' with details** (5 steps) — friction: Nine decisions before one task starts; two of the rows (Preset, Permission profile) have no effect on the session; the prompt builder differs from the quick path.
- **'Start tasks…' (orchestrator sheet)** (4 steps) — friction: What the sheet does (open N sessions in parallel) and what the stored 'orchestrator' promises (waves, auto review/tests, retries) are different products; the user sees both names.
- **Request Review / Run Tests** (3 steps) — friction: A review requested from the UI cannot satisfy the merge gate's 'No review result.' blocker unless the agent independently uses MCP.
- **Finish: Complete / Merge… / Commit / PR…** (4 steps) — friction: Three finishing verbs with different preconditions; the merge gate is driven by a settings file the user cannot see or change.
- **External edit → relink** (4 steps) — friction: Inferred from the code: when a tracked task is reworded so its id changes, no row carries the Reattach entry and the attention row cannot be actioned — the link is lost with no UI way back except the Sessions view (which also has no reattach action).
- **Agent-side loop (MCP)** (2 steps) — friction: The agent can reach states (running, testsFailing, waiting) the UI has no control for, so the badge vocabulary is only meaningful for MCP-aware agents.
- **Kanban drag between headings** (2 steps) — friction: Drag changes the file's structure (moves the whole block); execution state is untouched, so a card in 'Done' can still say 'Running'.
- **Palette capture** (1 steps) — friction: Undiscoverable prefix; a third way (with 'New task' sheet and MCP create_task) to add a line.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| ProjectTaskViewPreferences.mode | project | …/projects/<id>/tasks/view.json | Tasks toolbar mode picker (ProjectTasksView.swift:266-278) |  |
| ProjectTaskViewPreferences.selectedSourcePath | project | view.json | Source picker (:280-302) | yes |
| ProjectTaskViewPreferences.headingOverrides | project | view.json | Kanban custom-column gear menu (:904-919) | yes |
| ProjectTaskViewPreferences.columnOrder | project | view.json | NO UI (only read at :876) | yes |
| ProjectTaskViewPreferences.boardMode (fileBacked/virtual) | project | view.json | NO UI; 'the flag is the seam' (TaskBoardMapping.swift:230-235) | yes |
| ProjectTaskViewPreferences.filter (status, query, sourcePath, heading, sessionID) | project | view.json | status chips + search field only (:665-716); sourcePath/heading/sessionID have NO UI (TaskBoardMapping.swift:280-284) |  |
| ProjectTaskViewPreferences.expandedTaskIDs | project | view.json | Row chevrons | yes |
| ProjectTaskMetadataDocument.assignments / leases / needsRelinking | project | …/tasks/metadata.json | Tasks actions, MCP assign/claim |  |
| ProjectTaskMetadataDocument.columns (TaskBoardColumnMapping.defaults) | project | metadata.json | NO UI; not read by the Kanban (ProjectTaskModels.swift:405-447, :457) | yes |
| ProjectTaskMetadataDocument.portableIDsEnabled | project | metadata.json | NO UI; no reader (ProjectTaskModels.swift:460-461) | yes |
| OrchestratorSettings (maxParallelAgents, allowedProviders, allowedModels, maxWorktrees, automaticReview, automaticTests, automaticTodoUpdate, automaticRetry, maxRetries, requiresApprovalForMerge, requiresApprovalForDestructive, tokenBudget, costBudgetUSD) | project | …/tasks/orchestrator.json | NO UI anywhere; `update(settings:)` has no caller (TaskOrchestrator.swift:8-41, :414) |  |
| OrchestratorStore.document.dispatches (stored plan) | project | orchestrator.json | Written by 'Start tasks…' preview (ProjectTasksView.swift:1495); cleared by menu bar 'Stop the Orchestrator' | yes |
| TaskWorktreePolicy (serialisesConflictingTasks, maxWorktrees, cleanup) | project | nowhere (Codable, never persisted) | NO UI; no caller outside Tests (TaskDelivery.swift:8-69) | yes |
| TodoDiscovery.Rules (excluded/included dirs, additionalFileNames, excludedPaths, respectsGitIgnore, maximumDepth) | project | nowhere — documented as 'stored per project' but always `.default` (TodoDiscovery.swift:34-71; TodoSourceStore.swift:85) | NO UI | yes |
| SettingsStore.defaultProvider / defaultAccount(for:) | global | settings.json | Settings › Agents |  |
| SettingsStore.workingMode(for: provider) | global | settings.json providerBehaviors | Settings › Agents › Agent Behavior (AgentSettingsPages.swift:436-448) |  |
| SettingsStore.presets | global | settings.json | Settings › Agents › Session Presets (AgentSettingsPages.swift:536-590) |  |
| SettingsStore.sessionCapabilityDefaults | global | settings.json | Onboarding capabilities step / Settings |  |
| SettingsStore.language.resolvedAgent() | global | settings.json | Settings › General ('The language Uncoil writes in when it hands a task…', GeneralSettingsPage.swift:73) |  |
| MenuBarPrefs.showTasksSection | global | settings.json | Settings › Menu Bar 'Task shortcuts' (MenuBarSettingsPage.swift:123-124) | yes |
| NotificationPrefs taskCompleted / mergeReady events | global | settings.json | Settings › Notifications |  |
| TodoHintDismissal | project | UserDefaults tasks.todoHintDismissedProjects | TodoHintCard 'Not for this project' | yes |
| AgentLaunchCatalog capability cache | session | in-memory per run | first sheet open per provider (`--help` subprocess) | yes |
| TaskDispatchRequest (per-send) | window | sheet @State | Dispatch sheet |  |

### Visibility gates

- `App/UI/ProjectDashboardView.swift:56, :139; App/Core/ProjectAreaAvailability.swift` — page.hasTaskSources (a TODO.md/todo.md/TODOS.md exists outside excluded dirs) → Whether the Tasks tab exists at all, and the count badge
- `App/UI/ProjectDashboardView.swift:180` — !hasTaskSources && !todoHintDismissed → TodoHintCard on the General page
- `App/UI/ProjectTasksView.swift:88-103` — !sources.hasLoadedOnce → skeleton; sources.isEmpty → emptyState → Loading vs 'No TODO.md found' (the latter is effectively unreachable because the tab is hidden without sources)
- `App/UI/ProjectTasksView.swift:772` — !task.isDone && assignments.isEmpty → Inline 'Start' menu on a list row
- `App/UI/ProjectTasksView.swift:615, :758, :991` — state != .unassigned → Execution-state badge/label
- `App/UI/ProjectTasksView.swift:763, :1214` — assignments.contains(where: \.needsRelinking) → 'Needs relinking' label and 'Reattach to This Task' menu item
- `App/UI/ProjectTasksView.swift:1164` — !assignments.isEmpty → 'Open Session' submenu
- `App/UI/ProjectTasksView.swift:1188` — task.isDone → 'Reopen' vs 'Complete'
- `App/UI/ProjectTasksView.swift:1196` — results.latestReview(for:)?.findings non-empty → 'Send the Review Findings to the Session'
- `App/UI/ProjectTasksView.swift:1201` — assignments.contains { $0.worktreePath != nil } → 'Merge…' menu item
- `App/UI/ProjectTasksView.swift:867-878` — selectedDocuments.count == 1 → Kanban renders columns; otherwise only the hint sentence
- `App/UI/ProjectTasksView.swift:904` — column.isCustom (heading matched no lane) → Lane-mapping gear on a Kanban column
- `App/UI/ProjectTasksView.swift:321` — selectedDocuments.isEmpty → 'New task' disabled
- `App/UI/ProjectTasksView.swift:1589-1591, :1666-1671, :1642-1646` — gitStatuses[path]?.isEditable == false (conflict regions present) → Every file write refused with a banner; checkbox disabled via conflictTaskIDs (:592)
- `App/UI/TaskDispatchSheet.swift:74-76` — !request.isExistingSession → 'New session' section (agent/profile/model/effort/mode/preset/permission profile)
- `App/UI/TaskDispatchSheet.swift:243, :260; App/UI/TaskOrchestratorSheet.swift:185, :199` — !capabilities.models.isEmpty / !capabilities.efforts.isEmpty (from `<cli> --help`) → Model and Effort pickers — Claude gets both, Codex gets efforts and maybe a model, Gemini/OpenCode/Grok/Cursor get none, Hermes gets efforts only (AgentLaunchOptions.swift:56-124)
- `App/UI/TaskDispatchSheet.swift:347` — request.createsWorktree → 'Worktree name' row
- `App/UI/TaskDispatchSheet.swift:36-44, :166-174` — selected session's projectID != task project → Cross-project warning
- `App/UI/TaskDispatchSheet.swift:431-435, :439` — !request.autoStart → Hint text and button title 'Send (hold)'
- `App/UI/TaskMergeSheet.swift:250` — loading || merging || !preview.hardBlockers.isEmpty → 'Approve and merge' enabled
- `App/UI/TaskMergeSheet.swift:259-263` — worktreePath == nil → Merge sheet shows failure text instead of content
- `App/Tasks/TaskDelivery.swift:218-231` — settings.automaticReview / settings.automaticTests (OrchestratorSettings, no UI) → 'No review result.' / 'No test result.' merge blockers
- `App/Tasks/TaskAttention.swift:138-144; App/Core/AttentionCenter.swift:648-665` — mergeBlockers == [] && !assignments.isEmpty && worktree exists → 'Ready to merge' attention row
- `App/Core/AttentionCenter.swift:566-571` — assignments non-empty for the project → Whether task files are scanned for attention at all
- `App/UI/MenuBarMonitorView.swift:133-160; App/Core/MenuBarPrefs.swift:101` — prefs.showTasksSection; attention rows with isTaskRow && sessionID != nil → Menu bar 'Task Board' / 'Task Session' / 'Stop the Orchestrator'
- `App/Core/PaletteModel.swift:112-115, :157-165` — captureTargets non-empty (current project has task sources) and query starts with '+', 'todo:' or 'task:' → Palette 'Capture a Task' group
- `App/ControlPlane/PolicyEngine.swift:38, :52; App/ControlPlane/TasksHandler.swift:21-133` — grants contain tasks.read / tasks.write (default) vs tasks.delete / tasks.orchestrate / tasks.worktree / tasks.merge (opt-in) → Which uncoil_tasks actions an agent may call
- `App/UI/ProjectTasksView.swift:785, :1138; App/UI/TaskDispatchSheet.swift:211; App/UI/TaskOrchestratorSheet.swift:176` — AgentProvider.agents (all 7 CLIs, installed or not) → Provider choices in every task start path — unlike the sidebar launcher, which uses settings.launcherProviders resolved against installed binaries (SidebarView.swift:709; SettingsStore.swift:282-288)

### Open questions

- Is the orchestrator meant to become a real executor (waves, auto review/tests, retries, budgets), or is 'Start tasks…' — parallel multi-select start — the whole feature now? The answer decides whether OrchestratorSettings, the plan store, 'Stop the Orchestrator', the 'Task Orchestrator' preset and the tasks.orchestrate grant stay.
- Should Owner, Observer and Orchestrator be user-selectable roles at all, given only implementer/reviewer/tester have distinct behaviour in the app?
- Who is expected to pick model/effort per task? If it is a power-user need, does it belong in the task flow or in the provider's defaults with a per-session override on the session header?
- Is TODO.md the only work-item source by design, or should Issues (and palette 'ask', blueprints) converge on one 'work item → agent' primitive with shared assignment/attention state?
- Should the task's live status be derived from the assigned session's hook status (running/waiting/completed) instead of a separate 12-state machine that only MCP-aware agents advance?
- Is the Sessions view mode needed once sessions show their task (sidebar chip / header)?
- Should the merge gate (review + tests required) be a project-level policy with a UI, a per-task choice, or removed in favour of showing the facts without blocking?
- Does 'Merge…' need a task worktree at all, or should the finishing action work on whatever branch the session is on?

---

## Session screen and terminal (SessionDetailView / SessionHeaderBar / split / popout / sleeping / Codex approval / image drop / session creation paths / status vocabulary)

From the user's chair a "session" is one terminal running one agent CLI (or a plain shell) inside a project or worktree, with a dense header above it. The header is a mini-dashboard: provider name, title, a faint "(model · effort)" aside, an account menu, a usage ring, the path, a branch/worktree menu, a status capsule whose text is whatever the last event wrote, an "MCP" badge, a run/stop button (plus a log button), an editor button with its own menu, a conditional handoff button, and a restart button. Below it, depending on state, the user sees the terminal, a "paused/asleep" card with a Wake button, a Codex approval strip (only when the app is launched with a hidden flag), or a "this session is open in another window" card. The same session can also be shown as a split pane (same header, X instead of back) or a popout window (a 34pt strip with just title and orb). Sessions are born from a dozen call sites — sidebar hover strip, palette, menu bar, Ask, blueprints, GitHub issues, test repair, task dispatch, orchestrator, handoff, control-plane children — that ask anywhere from zero questions (sidebar) to eleven (task dispatch), with three different title conventions and two that forget the default account. A session has no explicit closed state: clicking a "Closed" row silently relaunches it. Actions on a session are split across the header (restart only), the palette (restart/close/popout), the sidebar context menu (pin/move/group/popout/pause/hibernate/wake/delete), the group screen (send/interrupt/restart/delete) and Settings (restart-all, per-session capability grants) with almost no overlap, and "permission" means three different mechanisms with three different UIs.

### Findings

#### [CRITICAL] S1 — The session header is a fourteen-control dashboard that mixes identity, metadata, status, project actions and account economics on one bar

*Category:* concept-overload

- `App/UI/SessionHeaderBar.swift:83` — HStack(alignment: .center, spacing: 12) {
- `App/UI/SessionHeaderBar.swift:113` — if let runtime = runtimeInfo.summary {
- `App/UI/SessionHeaderBar.swift:130` — Menu {
- `App/UI/SessionHeaderBar.swift:174` — UsageChip(
- `App/UI/SessionHeaderBar.swift:199` — BranchMenuButton(
- `App/UI/SessionHeaderBar.swift:239` — StatusOrb(status: status, size: 13)
- `App/UI/SessionHeaderBar.swift:250` — McpStatusBadge(sessionID: record.id)
- `App/UI/SessionHeaderBar.swift:254` — RunDefaultControl(project: project, onOpenLogs: onOpenProject)
- `App/UI/SessionHeaderBar.swift:256` — EditorOpenControl(directory: workingDirectory)
- `App/UI/SessionHeaderBar.swift:265` — ControlButton(                         iconName: "arrow-move-right",
- `App/UI/SessionHeaderBar.swift:279` — ControlButton(                     iconName: "refresh",
- `App/UI/ProjectRunView.swift:175` — let configurations = RunConfigFile.load(projectRoot: project.rootURL).configurations
- `App/UI/SessionHeaderBar.swift:345` — .task(id: record.provider) {             guard record.provider.isAgent else { return }             capabilities = await AgentLaunchCatalog.detect(

**Why it matters:** Back, provider, title, model/effort aside, account menu, usage ring, path, branch+tree menu, status capsule, MCP badge, run/stop, run log, editor, editor menu, handoff, restart: sixteen affordances across three text tiers, each with its own data loop (git every 15s, branches every 3s, usage every 30s, run.json on every render, a CLI --help spawn). Every new feature has landed here (usage, handoff, run, MCP), and the pattern will continue. The user cannot tell which of these are about the session, the account, the project or the app.

**Direction:** Split identity/state (what am I looking at) from project actions (run, editor, branch) and account economics (usage, handoff); give the header a fixed budget.

#### [CRITICAL] S2 — 'Permission' is three different mechanisms with three different UIs, two of which share one status

*Category:* duplicate-concept

- `App/Hooks/SessionStore+Hooks.swift:85` — if message.localizedCaseInsensitiveContains("permission") {                 setStatus(.waitingForPermission, detail: message, for: sessionID)
- `App/UI/SessionDetailView.swift:41` — if let approval = sessionStore.codexApprovals[record.id] {                     CodexApprovalPanel(
- `App/Core/LaunchConfig.swift:87` — codexAppServerEnabled = arguments.contains("-codex-app-server")
- `App/Codex/CodexAppServerSession.swift:494` — sessionStore?.setStatus(.waitingForPermission, detail: title, for: recordID)
- `App/Core/PermissionNotifications.swift:58` — let allowOnce = UNNotificationAction(             identifier: PermissionNotificationPolicy.allowOnceAction,             title: String(localized: "Allow Once"),
- `App/UI/Settings/PrivacySettingsPages.swift:216` — ForEach(service.granted()) { request in                     requestRow(request) {
- `App/UI/TaskDispatchSheet.swift:309` — pickerRow(String(localized: "Permission profile")) {
- `App/UI/Settings/AgentSettingsPages.swift:443` — title: String(localized: "Working Mode"),             subtitle: String(localized: "How much each agent does without asking.")

**Why it matters:** Claude's permission prompt is answered inside the TUI and only reflected as a status; Codex's is answered in a panel above the terminal that only exists under a launch flag; agent-to-agent control-plane grants are answered from a notification banner or a Settings page with a session picker. On top of that, 'Working mode', 'Permission profile', 'Session Access' and 'Advanced Permissions' all describe how much the agent may do. The user cannot build one model of 'the agent asked me something'.

**Direction:** One 'requests' surface per session that hosts whichever mechanism produced the request, and one vocabulary for pre-authorisation (mode) vs runtime approval.

#### [HIGH] S3 — Status vocabulary: ten internal states, four different renderings, and a free-text detail that overrides the label with provider jargon

*Category:* terminology

- `App/Core/Models.swift:629` — case .unknown: String(localized: "Checking…")         case .idle: String(localized: "Ready")
- `App/UI/SessionHeaderBar.swift:240` — Text(sessionStore.detail(of: record.id) ?? status.label)
- `App/Codex/CodexAppServerSession.swift:297` — sessionStore?.setStatus(.idle, detail: String(localized: "Structured Codex ready"), for: recordID)
- `App/Terminal/TerminalHost.swift:608` — sessionStore.setStatus(.idle, detail: String(localized: "PTY fallback: \(reason)"), for: recordID)
- `App/Hooks/SessionStore+Hooks.swift:80` — setStatus(.running, detail: event.toolName.map { "tool: \($0)" }, for: sessionID)
- `App/Core/AgentResume.swift:33` — String(localized: "Started fresh — \(provider.displayName) no longer has this conversation.")
- `App/UI/ProjectDashboardView.swift:756` — Text(status.label)
- `App/UI/SessionGroupView.swift:210` — Text(sessionStore.detail(of: record.id)                      ?? sessionStore.status(of: record.id).label)
- `App/Core/Models.swift:652` — case .waitingForPermission: Theme.claude
- `App/ControlPlane/HelpRegistry.swift:157` — Waits until each child status ∈ {idle, waitingForInput, waitingForPermission, completed, terminated}

**Why it matters:** The same session reads 'Ready' on the dashboard, 'Structured Codex ready' or 'tool: Bash' in its header, an orb only in the sidebar, and 'idle' to an agent. 'Done' (.completed) is a Codex-only state in practice (Claude's stop hook goes to .idle) so two providers finish differently. The 'waiting for permission' colour is Claude's brand colour for every provider. Nothing tells the user which of these are states and which are commentary.

**Direction:** Separate a small user-facing state set from a provider-neutral 'activity' line; stop provider transports from writing their internals into the capsule.

#### [HIGH] S4 — Session actions are scattered over five surfaces with almost no overlap: the header can only restart

*Category:* duplicate-concept

- `App/UI/SessionHeaderBar.swift:279` — ControlButton(                     iconName: "refresh",                     help: String(localized: "Restart the session")
- `App/Core/PaletteModel.swift:365` — items.append(PaletteItem(id: "cmd.restart", title: String(localized: "Restart the Session"),
- `App/Core/PaletteModel.swift:368` — items.append(PaletteItem(id: "cmd.close", title: String(localized: "Close the Session"),
- `App/UI/MainWindow.swift:415` — case .closeSession(let id):             TerminalRegistry.shared.closeTerminal(for: id)             sessionStore.setStatus(.terminated, for: id)             projectStore.markSessionEnded(id, exitCode: nil)
- `App/UI/AppKit/SidebarOutline.swift:815` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/UI/AppKit/SidebarOutline.swift:867` — items.append((String(localized: "Pause"), {
- `App/UI/AppKit/SidebarOutline.swift:832` — add(to: menu, title: String(localized: "Delete the Session")) {
- `App/UI/SessionGroupView.swift:139` — Button("Interrupt") { interruptTargets() }
- `App/UI/MenuBarMonitorView.swift:97` — TerminalRegistry.shared.interrupt(record.id)
- `App/UI/Settings/AgentSettingsPages.swift:298` — if let title = AgentProcessRestart.offer(

**Why it matters:** Restart: header, palette, group, Settings, account alert. Close: palette only. Pause/Hibernate/Wake: sidebar menu only. Popout: palette + sidebar + drag. Interrupt: group screen and menu bar only, never on the session itself. Pin/Move/Group/Delete: sidebar only. The user has to remember which surface holds which verb; the session screen, the obvious home, holds one.

**Direction:** Model a single session action set and render it from one place (header overflow + context menu + palette from the same list).

#### [HIGH] S5 — A closed session has no closed state: opening it silently relaunches the agent, and recorded transcripts are never shown

*Category:* visibility-logic

- `App/UI/SessionDetailView.swift:81` — // Selecting a session always (re)starts its agent: the registry                     // reuses a live terminal or launches fresh (resuming Claude when                     // a provider session id is known). No "restart" 
- `App/Terminal/TerminalHost.swift:18` — /// Sessions whose process exited; the next request recreates the terminal     /// (auto-relaunch — the user never sees a "restart" screen).
- `App/Terminal/TerminalHost.swift:139` — sessionStore?.setStatus(                 .idle,                 detail: resumeObstacle?.message(for: provider),                 for: recordID             )
- `App/Core/LaunchConfig.swift:201` — let history = projectStore.createSession(             projectID: project.id,             provider: .codex,             accountID: nil,             title: "codex: past task"         )
- `App/Core/SessionTranscriptStore.swift:65` — func data(for sessionID: UUID) -> Data? {
- `App/UI/SessionDetailView.swift:72` — if let mode = record.sleepMode {                     SleepingSessionView(record: record, mode: mode) {

**Why it matters:** The app distinguishes 'Closed' in labels and dims the sidebar row, and a demo fixture even seeds a 'past task', but the only thing a user can do with a closed session is relaunch it (possibly starting a fresh conversation with a one-line explanation in the status capsule). A sleeping session, by contrast, gets a deliberate card with a Wake button. Transcripts are recorded to disk (Settings › Data and Transcripts) yet no UI reads them (no transcriptStore reads under App/UI).

**Direction:** Give 'closed' the same explicit card treatment as 'asleep' (what happened, what reopening will do, history if any).

#### [HIGH] S6 — Twelve session-creation call sites, zero to eleven questions, three title conventions, and two that forget the default account

*Category:* onboarding

- `App/UI/SidebarView.swift:733` — let record = projectStore.createSession(             projectID: project.id,             provider: provider,             accountID: provider == .terminal ? nil : account?.id,             title: provider == .terminal      
- `App/UI/MainWindow.swift:488` — let record = projectStore.createSession(             projectID: projectID,             provider: provider,             accountID: provider == .terminal ? nil : account?.id,             title: provider == .terminal ? "ter
- `App/UI/MenuBarMonitorView.swift:186` — let record = projectStore.createSession(             projectID: project.id,             provider: provider,             accountID: provider == .terminal ? nil : account?.id,
- `App/UI/ProjectIssuesView.swift:340` — let record = projectStore.createSession(             projectID: project.id,             provider: settings.defaultProvider,             accountID: nil,             title: "#\(issue.number) \(issue.title)"
- `App/Core/TestRepair.swift:118` — let session = projectStore.createSession(             projectID: project.id,             provider: provider,             // Default account and default launch settings: the user's own             // defaults are what a s
- `App/UI/TaskDispatchSheet.swift:73` — targetSection                     if !request.isExistingSession {                         newSessionSection                     }                     roleAndWorktreeSection                     previewSection
- `App/UI/BlueprintCards.swift:23` — let provider = settings.defaultProvider         let record = projectStore.createSession(
- `App/ControlPlane/SessionsHandler+Children.swift:116` — let record = projectStore.createSession(             projectID: projectID, provider: preset.provider, accountID: account?.id,             title: "\(preset.provider.rawValue): \(preset.name)", worktreePath: worktreePath)
- `App/Core/Models.swift:833` — var hasPlaceholderTitle: Bool {

**Why it matters:** The ordinary path (sidebar/palette/menu bar) asks nothing; task dispatch asks target, provider, profile, model, effort, working mode, preset, permission profile, role, worktree, worktree name. The issue and test-repair paths pass accountID nil (the comment in TestRepair says 'Default account' but passes nil), so a user who set a default profile gets sessions under the provider's own login there and under the profile everywhere else. Placeholder-title detection depends on exact strings, so only two of the twelve paths ever auto-title.

**Direction:** One NewSessionRequest with defaults resolved in one place; a single optional 'advanced' expansion shared by every path.

#### [HIGH] S7 — Provider-specific machinery is wired into the generic session screen, including a Codex transport that is off unless launched with a flag

*Category:* agent-leak

- `App/UI/SessionDetailView.swift:178` — private struct CodexApprovalPanel: View {
- `App/UI/SessionDetailView.swift:229` — Text("You need to sign in to your Codex account. You can run `codex login` through the terminal fallback.")
- `App/Core/LaunchConfig.swift:79` — // The protocol client stays behind         // this flag rather than being deleted: it is what structured approvals         // and turn state are built on, and it is still covered by tests.         codexAppServerEnabled 
- `App/Codex/CodexAppServerSession.swift:85` — feed("\u{001B}[2mChecking the Codex app-server…\u{001B}[0m\r\n")
- `App/Terminal/TerminalHost.swift:130` — if LaunchConfig.shared.codexApprovalFixture, record.provider == .codex {                 sessionStore?.setCodexApproval(
- `App/UI/SessionDetailView.swift:45` — if LaunchConfig.shared.codexApprovalFixture {
- `App/Terminal/RuntimeClient.swift:15` — static func submissionParts(_ text: String, provider: AgentProvider) -> [Data] {         let enter = provider == .terminal             ? Data([0x0D])             : Data([0x1B, 0x5B, 0x31, 0x33, 0x75])
- `App/Terminal/RuntimeClient.swift:718` — if provider == .claude,                    String(decoding: buffer, as: UTF8.self).contains("manual mode on") {

**Why it matters:** SessionStore carries codexApprovals/codexAuthentication maps by name; the screen has Codex-only panels; TerminalHost seeds a Codex fixture approval; RuntimeClient sniffs Claude's 'manual mode on'. Adding a provider with its own approval protocol would add another named map and another panel. Meanwhile the one in-session approval UI that exists is unreachable in normal use.

**Direction:** Provider adapters produce neutral 'request'/'notice' events; the session screen renders those without knowing the provider.

#### [HIGH] S8 — Launch options (model, effort, working mode, flags) are asked in three places, shown read-only in a fourth, and promised 'per session' in onboarding but absent from the session

*Category:* settings-sprawl

- `App/UI/Onboarding/OnboardingToolSteps.swift:25` — subtitle: String(localized: "This is the mode every new session starts in. You can change it per session at any time, and change the default later in Settings."),
- `App/UI/Settings/AgentSettingsPages.swift:437` — Picker(selection: Binding(                         get: { settings.workingMode(for: provider) },                         set: { settings.setWorkingMode($0, for: provider) }
- `App/UI/Settings/AgentSettingsPages.swift:392` — title: String(localized: "Run Parameters"),             subtitle: String(localized: "Appended to the launch command; applies from the next session on.")
- `App/UI/TaskDispatchSheet.swift:275` — pickerRow(String(localized: "Working mode")) {
- `App/UI/TaskOrchestratorSheet.swift:213` — Text("Mode: default").tag(AgentWorkingMode?.none)
- `App/UI/SessionHeaderBar.swift:110` — // Model and effort: reference, not status. Parenthesised,                     // small and faint so it reads as an aside to the name
- `App/Terminal/TerminalHost.swift:1049` — let selectionArguments = record.launchSelection.map {             AgentLaunchCatalog.launchArguments(for: record.provider, selection: $0)         } ?? []
- `App/Terminal/TerminalHost.swift:1055` — if record.launchSelection?.workingMode == nil, !modeArguments.isEmpty {             command += " " + modeArguments.joined(separator: " ")         }         if let presetArguments, !presetArguments.isEmpty {
- `App/Core/Models.swift:286` — case .dangerouslySkipPermissions

**Why it matters:** Selection args, settings-wide mode args, preset args and free-text Run Parameters are concatenated with precedence rules only the launcher knows. The header's aside shows model/effort but not mode, and cannot change any of them. A plain new session cannot pick a model at all. Working-mode labels are CLI flag names ('Dangerously Skip Permissions', 'Provider default').

**Direction:** One 'how this session runs' object, settable at creation and visible/editable (restart-applies) from the session; retire free-text flags into it.

#### [HIGH] S9 — The MCP badge is shown for every agent session, including providers that never wire the control plane, so it can sit on 'MCP waiting' forever

*Category:* agent-leak

- `App/UI/SessionHeaderBar.swift:237` — if record.provider.isAgent {                 HStack(spacing: 7) {                     StatusOrb(status: status, size: 13)
- `App/UI/SessionHeaderBar.swift:250` — McpStatusBadge(sessionID: record.id)
- `App/ControlPlane/McpStatus.swift:36` — func state(for sessionID: UUID, now: Date = .now) -> McpLinkState {         guard isServing else { return .off }         guard let seen = lastContact[sessionID] else { return .waiting }
- `App/Core/Models.swift:140` — var wiresControlPlane: Bool {         switch self {         case .claude, .codex, .opencode: true
- `App/ControlPlane/McpStatus.swift:52` — case .off: "MCP off"         case .waiting: "MCP waiting"         case .connected: "MCP connected"

**Why it matters:** Gemini, Grok, Cursor and Hermes sessions get an amber 'MCP waiting' badge with help text 'the agent has not called the uncoil MCP yet' although the app never hands them the socket (inferred from the two predicates). The badge also uses the internal acronym as its only label. Each header widget checks a different provider predicate; there is no single place that says what a provider can show.

**Direction:** Gate the badge on wiresControlPlane (or hide it entirely for non-wired providers) and drive all header widgets from one per-provider capability record.

#### [MEDIUM] S10 — One thing, three names: account / profile / login

*Category:* terminology

- `App/UI/SessionHeaderBar.swift:143` — Text(account?.name ?? String(localized: "No account"))
- `App/UI/SessionHeaderBar.swift:151` — localized: "Which login this session runs under. The config directory is handed to the agent when it starts, so switching applies from the next start."
- `App/UI/TaskDispatchSheet.swift:228` — pickerRow(String(localized: "Profile")) {
- `App/UI/Settings/SettingsView.swift:132` — case .accounts: String(localized: "Accounts")
- `App/UI/LoginTerminalSheet.swift:8` — struct LoginTerminalSheet: View {     let profile: AccountProfile

**Why it matters:** The header says account/login, task dispatch says Profile with a 'Default' entry, Settings says Accounts, and the type is AccountProfile. 'No account' in the header actually means the provider's own default login, which the code elsewhere models as a real account (nil).

**Direction:** Pick one word and one label for the nil case ('Default login').

#### [MEDIUM] S11 — Internal names surface as UI labels: Preset, grants, MCP, Structured Codex, PTY fallback, Provider Session ID, Agent Status Hooks

*Category:* terminology

- `App/UI/TaskDispatchSheet.swift:288` — pickerRow(String(localized: "Preset")) {
- `App/UI/TaskDispatchSheet.swift:310` — Text(                         request.permissionProfile.isEmpty                             ? "session default"                             : "\(request.permissionProfile.count) grants"                     )
- `App/UI/Settings/SettingsView.swift:136` — case .presets: String(localized: "Session Presets")
- `App/UI/Settings/SettingsView.swift:148` — case .hooks: String(localized: "Agent Status Hooks")
- `App/UI/AppKit/SidebarOutline.swift:827` — add(to: menu, title: String(localized: "Copy the Provider Session ID")) {
- `App/Codex/CodexAppServerSession.swift:296` — feed("\u{001B}[2mStructured Codex ready.\u{001B}[0m\r\n")
- `App/Codex/CodexAppServerSession.swift:608` — feed("\r\n\u{001B}[33m\(message) Starting the PTY fallback.\u{001B}[0m\r\n")
- `App/Core/SessionPreset.swift:20` — /// Permission mode label; reserved for future provider-specific mapping.     var permissionMode: String

**Why it matters:** These are implementation nouns (a preset is a create_child template; grants are PolicyEngine keys; PTY/app-server are transports). Showing them asks the user to learn the architecture to use the product.

**Direction:** Rename at the surface to what they do ('Agent template', 'Access', 'Uncoil tools'), and keep transport chatter out of the terminal.

#### [MEDIUM] S12 — Feature-visibility decisions are made ad hoc inside views against the provider enum and raw stores; there is no capability registry

*Category:* visibility-logic

- `App/UI/SessionHeaderBar.swift:66` — guard record.provider.isAgent else { return nil }
- `App/UI/SessionHeaderBar.swift:129` — if record.provider.isAgent, !accountChoices.isEmpty {
- `App/Terminal/TerminalHost.swift:768` — guard record.provider.isAgent else { return { false } }
- `App/Terminal/TerminalHost.swift:154` — private func shouldUseCodexAppServer(record: SessionRecord, settings: SettingsStore) -> Bool {         guard record.provider == .codex,               LaunchConfig.shared.codexAppServerEnabled,
- `App/Core/Models.swift:13` — /// This list was written out by hand in twenty-two places — some with the     /// terminal, some without, and the difference between the two was never     /// stated.
- `App/Core/Models.swift:94` — /// The distinction was made ad hoc — twenty-odd `provider == .terminal`     /// comparisons, each deciding for itself — and the places that forgot it     /// are what put "Claude is waiting for your input" and an MCP ba
- `App/Terminal/TerminalHost.swift:1018` — if record.provider == .claude, let sid = resumeID {             command += " --resume \(shellQuote(sid))"         }         if record.provider == .codex, let sid = resumeID {
- `App/UI/ProjectRunView.swift:175` — let configurations = RunConfigFile.load(projectRoot: project.rootURL).configurations         if let config = RunConfigFile.defaultConfiguration(configurations) {

**Why it matters:** The code's own comments record the cost of this ('twenty-two places'). isAgent, wiresControlPlane, resumesConversation, reportsStatusThroughHooks, extensionScoping and six per-provider resume branches are the registry, spread over an enum and a launcher. Views decide what to show by asking these directly; the dashboard and group rows forgot to ask and show status for terminals.

**Direction:** A per-provider capability record consumed by one 'session surface policy' that every view reads.

#### [MEDIUM] S13 — Split pane, popout window and 'held elsewhere' are three ways to see a session, each with a different subset of chrome and different entry points

*Category:* navigation

- `App/UI/SessionDetailView.swift:105` — guard let splitBinding = splitSessionID,                   let provider = providers.first else { return false }
- `App/UI/SessionDetailView.swift:265` — /// Right half of a drag-to-split: the same session header as the pane it was /// dragged out of, over the same terminal.
- `App/UI/SessionPopoutWindow.swift:27` — HStack(spacing: 8) {                         Spacer().frame(width: 70)  // traffic lights                         ProviderMark(provider: record.provider, size: 13)
- `App/UI/AppKit/SidebarOutline.swift:815` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/Core/PaletteModel.swift:371` — items.append(PaletteItem(id: "cmd.popout", title: String(localized: "Open in a Popout Window"),
- `App/UI/AppKit/SidebarOutline.swift:647` — /// A drag ending outside the window with nothing accepting it opens the         /// session in its own window — the behaviour the old drag handle had.
- `App/UI/MainWindow.swift:755` — if case .heldElsewhere = windows.claim(id, by: windowID), id == splitSessionID {

**Why it matters:** Split is only reachable by dragging a sidebar row onto the terminal (no menu, no palette, no hint); popout has three entries under two names ('New Window' vs 'Popout Window') and loses restart/account/usage/branch/run/editor. The ownership rule ('one window at a time') is explained only after the fact by an overlay.

**Direction:** One 'open beside / open in window' action pair with the same chrome everywhere.

#### [MEDIUM] S14 — Key behaviours are hidden gestures with no in-screen hint

*Category:* discoverability

- `App/UI/SidebarView.swift:715` — .contextMenu {                     let choices = settings.accounts(for: provider)                     if provider.isAgent, choices.count > 1 {
- `App/UI/SidebarView.swift:921` — .help("Drag onto a group to move it; drop outside the window to open it in a new one")
- `App/Terminal/TerminalKeyHandling.swift:210` — NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
- `App/Terminal/TerminalKeyHandling.swift:70` — static func editingBytes(         keyCode: UInt16,         modifiers: NSEvent.ModifierFlags,         optionIsMeta: Bool = false
- `App/UI/SessionDetailView.swift:249` — Text("Hover a project, pick an agent")

**Why it matters:** Account choice on right-click, split on drag-onto-terminal, popout on drag-out, Shift+Enter newline, ⌘⌫/⌘←/⌥← translations, ⌘V image capture — all learned by accident. The empty state literally instructs a hover.

**Direction:** Surface the same actions through visible controls and keep gestures as accelerators.

#### [MEDIUM] S15 — The empty state shows only Claude and Codex marks and teaches a hover-only control while the app supports seven agents and a configurable launcher

*Category:* empty-state

- `App/UI/SessionDetailView.swift:245` — HStack(spacing: 12) {                 ProviderMark(provider: .claude, size: 20)                 ProviderMark(provider: .codex, size: 20)             }             Text("Hover a project, pick an agent")
- `App/Core/Models.swift:1` — enum AgentProvider: String, Codable, CaseIterable, Identifiable {     case claude     case codex     case gemini     case opencode     case grok     case hermes     case cursor     case terminal
- `App/UI/SidebarView.swift:708` — ForEach(settings.launcherProviders) { provider in

**Why it matters:** The only screen a new user sees before any session neither lists the agents that are installed nor offers to start one.

**Direction:** Make the empty state the launcher (installed agents, one click) rather than a description of one.

#### [MEDIUM] S16 — Terminal-only sessions are half-gated: no status in the header, but status labels on the dashboard and group rows, broadcast prompts, auto-titles from shell commands

*Category:* agent-leak

- `App/UI/SessionHeaderBar.swift:234` — // A terminal session has no agent, so it has no agent status and             // no control plane
- `App/UI/ProjectDashboardView.swift:754` — HStack(spacing: 6) {                     StatusOrb(status: status, size: 11)                     Text(status.label)
- `App/UI/SessionGroupView.swift:242` — private func sendPrompt() {         let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)         guard !text.isEmpty else { return }         let targets = records.filter { targetIDs.contains($0.id) }
- `App/Terminal/TerminalHost.swift:1091` — let record = projectStore?.sessions.first { $0.id == recordID }         if record?.hasPlaceholderTitle ?? false { typedLine = .init() }
- `App/Core/Models.swift:838` — || title == "terminal"
- `App/Core/SessionSleep.swift:59` — /// Suspending only signals a process, so it asks nothing of the provider —     /// a plain shell suspends as well as an agent does.

**Why it matters:** 'Terminal' is modelled as a provider, so every session surface has to remember to special-case it, and several do not: a shell shows 'Checking…'/'Ready'/'Closed' on the dashboard, receives 'Send to All' prompts, and is renamed after the first command typed (inferred from the typed-line watcher applying to any placeholder title).

**Direction:** Treat a shell as a distinct kind with its own minimal surface rather than an agent with features switched off.

#### [MEDIUM] S17 — Restart is implemented five times with two independent counters

*Category:* duplicate-concept

- `App/UI/SessionDetailView.swift:85` — .id(restartToken + (sessionStore.restartCounter[record.id] ?? 0))
- `App/UI/SessionDetailView.swift:171` — private func restart() {         TerminalRegistry.shared.closeTerminal(for: record.id)         projectStore.updateSession(record.id) { $0.lastActivityAt = .now }         restartToken += 1
- `App/UI/SessionDetailView.swift:302` — private func restart() {         TerminalRegistry.shared.closeTerminal(for: record.id)
- `App/UI/MainWindow.swift:411` — case .restartSession(let id):             TerminalRegistry.shared.closeTerminal(for: id)             projectStore.updateSession(id) { $0.lastActivityAt = .now }             sessionStore.bumpRestart(id)
- `App/UI/SessionGroupView.swift:264` — private func restartTargets() {         for id in targetIDs {             TerminalRegistry.shared.closeTerminal(for: id)
- `App/UI/Settings/AgentSettingsPages.swift:307` — private func restartRunningSessions() {         for id in restartTargets {             TerminalRegistry.shared.closeTerminal(for: id)

**Why it matters:** Same three-line ritual copied into five views; the header's restart and the palette's restart go through different counters that happen to be summed. Any change to what 'restart' means (e.g. confirm when the conversation cannot be resumed) has five places to miss.

**Direction:** One SessionActions.restart(id) owned by the store.

#### [MEDIUM] S18 — Sleep verbs and states do not line up, and a paused session counts as 'working'

*Category:* terminology

- `App/UI/AppKit/SidebarOutline.swift:880` — items.append((String(localized: "Hibernate"), {
- `App/Core/Models.swift:637` — case .suspended: String(localized: "Paused")         case .hibernated: String(localized: "Asleep")
- `App/UI/SleepingSessionView.swift:15` — case .suspended: String(localized: "This session is paused")         case .hibernated: String(localized: "This session is asleep")
- `App/Core/WorkingTree.swift:32` — var isWorking: Bool {         switch self {         case .thinking, .running, .waitingForPermission, .waitingForInput: true         // Frozen mid-action, not finished: it still has work in flight and         // cannot ev
- `App/UI/SessionHeaderBar.swift:373` — private var busyWarning: String? {         let busy = treeSessions.filter { sessionStore.status(of: $0.id).isWorking }

**Why it matters:** Pause→Paused is consistent; Hibernate→Asleep is not, and the orb draws both as the same hollow ring. Because suspended counts as isWorking, switching a branch from the header warns 'X is working in this tree' for a session the user paused (inferred from the two predicates).

**Direction:** One pair of verbs/states (Pause/Paused, Sleep/Asleep) and a distinct 'frozen' predicate for the branch warning.

#### [MEDIUM] S19 — Per-session capabilities are edited in Settings › Uncoil › Permissions through a session picker, three windows away from the session

*Category:* settings-sprawl

- `App/UI/Settings/PrivacySettingsPages.swift:149` — Picker(selection: $selectedSessionID) {                         ForEach(projectStore.sessions) { session in                             Text(sessionLabel(session)).tag(UUID?.some(session.id))
- `App/UI/Settings/PrivacySettingsPages.swift:181` — Text(record.capabilities == nil                              ? "Using the default profile"                              : "Customised for this session")
- `App/Core/ProjectStore.swift:439` — record.capabilities = Self.defaultSessionCapabilities

**Why it matters:** The session screen gives no sign that a session has custom access, and the only editor lists every session in the app in one popup. This is session state living under an app-level settings tab.

**Direction:** Show and edit a session's access from the session (or its context menu), keep Settings for the default profile.

#### [MEDIUM] S20 — The advanced path (task dispatch) competes with the everyday path: eleven pickers to hand over one task, including a read-only 'Permission profile' row and a 'Preset' that rewrites other rows

*Category:* onboarding

- `App/UI/TaskDispatchSheet.swift:93` — .frame(width: 620, height: 620)
- `App/UI/TaskDispatchSheet.swift:293` — set: { id in                             request.presetID = id                             applyPreset(id)
- `App/UI/TaskDispatchSheet.swift:309` — pickerRow(String(localized: "Permission profile")) {                     Text(
- `App/UI/TaskDispatchSheet.swift:326` — pickerRow(String(localized: "Role")) {
- `App/UI/TaskDispatchSheet.swift:339` — pickerRow(String(localized: "Create a worktree")) {

**Why it matters:** A user who just wants 'send this to Claude' meets provider, profile, model, effort, working mode, preset, permission profile, role, worktree and name. The same sheet is the only place model/effort exist.

**Direction:** Default-and-go with one 'options' disclosure; reuse the same disclosure for plain new sessions.

#### [LOW] S21 — Test fixtures branch inside production session views and the launcher

*Category:* visibility-logic

- `App/UI/SessionDetailView.swift:45` — if LaunchConfig.shared.codexApprovalFixture {                                 sessionStore.setCodexApproval(nil, for: record.id)
- `App/Terminal/TerminalHost.swift:130` — if LaunchConfig.shared.codexApprovalFixture, record.provider == .codex {
- `App/UI/UsageChip.swift:195` — guard LaunchConfig.shared.usageFixture, UsageCardAutoOpen.claim() else { return }

**Why it matters:** Fixture logic is visibility logic; it adds branches to the very views a restructuring will have to move.

**Direction:** Seed fixtures through the stores, not the views.

#### [LOW] S22 — Popout has two names and the window is titled 'Session'; the branch chip's tree name reads oddly for the root

*Category:* terminology

- `App/UI/AppKit/SidebarOutline.swift:815` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/Core/PaletteModel.swift:371` — title: String(localized: "Open in a Popout Window"),
- `App/UncoilApp.swift:91` — WindowGroup("Session", id: "session-window", for: UUID.self) { $sessionID in
- `App/UI/BranchBadge.swift:14` — ? String(localized: "main copy")
- `App/UI/SessionHeaderBar.swift:218` — Text("· \(treeName)")

**Why it matters:** Small, but each is a word the user has to reconcile ('New Window' = 'Popout Window' = 'Session'; 'main · main copy').

**Direction:** One name per action; drop the tree suffix when the session runs in the project root.

#### [LOW] S23 — The editor button silently rewrites a global setting, and the branch switch types text into other sessions

*Category:* coupling

- `App/UI/EditorOpenControl.swift:46` — settings.preferredEditor = candidate                         settings.save()                         open(with: candidate)
- `App/UI/SessionHeaderBar.swift:386` — private func announceSwitch(to branch: String) {         refreshBranch()         let note = String(localized: "The working tree moved to branch \(branch).")         for session in treeSessions where sessionStore.status(o

**Why it matters:** Two header controls have side effects beyond the session (app default changed; other agents' prompts written into). Neither says so.

**Direction:** Keep header actions session-scoped or label the wider effect.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Session screen | screen | `App/UI/SessionDetailView.swift` | MainWindow.routedDetail case .session (MainWindow.swift:587); MainRoute.request(.session(id)) from palette, attention center, menu bar, handoff |
| Session header bar | toolbar | `App/UI/SessionHeaderBar.swift` | SessionDetailView.header (leadingIcon chevron.left); SplitSessionPane (leadingIcon xmark) |
| Codex approval panel | banner | `App/UI/SessionDetailView.swift` | sessionStore.codexApprovals[record.id] non-nil, only set by CodexAppServerSession.handleApproval (CodexAppServerSession.swift:483-495) which only runs under -codex-app-server (LaunchConfig.swift:87) o |
| Codex authentication banner | banner | `App/UI/SessionDetailView.swift` | sessionStore.codexAuthentication[record.id] == .required (set in CodexAppServerSession.swift:570) |
| Sleeping session view | empty-state | `App/UI/SleepingSessionView.swift` | SessionDetailView when record.sleepMode != nil (line 72) |
| Split session pane | panel | `App/UI/SessionDetailView.swift` | Only by dragging a sidebar session row onto the session view (SessionDetailView.swift:105-115); splitSessionID state in MainWindow.swift:20, hosted at MainWindow.swift:596-605 |
| Session popout window | window | `App/UI/SessionPopoutWindow.swift` | Palette 'Open in a Popout Window' (PaletteModel.swift:371; MainWindow.swift:420); Sidebar context menu 'Open in a New Window' (SidebarOutline.swift:815); Drag a sidebar row outside the window (Sidebar |
| Session elsewhere view | empty-state | `App/UI/WindowOverlays.swift` | MainWindow.swift:571-583 when sessionHolder(of:) != nil; SessionPopoutWindow.swift:43-52 |
| Empty detail view | empty-state | `App/UI/SessionDetailView.swift` | MainWindow.routedDetail when selection is nil or the record/project cannot be found |
| Session group screen | screen | `App/UI/SessionGroupView.swift` | MainWindow.routedDetail case .group |
| Login terminal sheet | sheet | `App/UI/LoginTerminalSheet.swift` | Settings › Agents › Accounts (AgentSettingsPages.swift:120); Onboarding accounts step (OnboardingIntroSteps.swift:319) |
| Usage card popover | popover | `App/UI/UsageCard.swift` | UsageChip click (UsageChip.swift:152, 198); -usage-fixture auto-open (UsageChip.swift:194-197) |
| Handoff sheet | sheet | `App/UI/HandoffSheet.swift` | Header handoff button (SessionHeaderBar.swift:264-275); UsageCard hand-off row via onRequestHandoff; Attention Center row → HandoffRoute (AttentionCenterView.swift:135 → SessionHeaderBar.swift:314-321 |
| Agent launcher strip (hover) | hover-control | `App/UI/SidebarView.swift` | Sidebar project row hover; Project dashboard |
| Sidebar session row context menu | menu | `App/UI/AppKit/SidebarOutline.swift` | Right-click on a session row |
| Command palette session commands | menu | `App/Core/PaletteModel.swift` | Command palette |
| Task dispatch sheet (session creation with options) | sheet | `App/UI/TaskDispatchSheet.swift` | ProjectTasksView.swift:245 |
| Task orchestrator sheet footer | sheet | `App/UI/TaskOrchestratorSheet.swift` | Project › Tasks |
| Settings › Uncoil › Permissions (per-session grants) | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings window; SettingsRoute |
| MCP status badge | status | `App/ControlPlane/McpStatus.swift` | SessionHeaderBar.swift:250 for every record.provider.isAgent |
| Status orb | status | `App/UI/StatusOrb.swift` | SessionHeaderBar, SessionGroupView, SidebarView row, ProjectDashboardView SessionCard, SessionPopoutWindow |
| Dashboard session card | row | `App/UI/ProjectDashboardView.swift` | Project dashboard |
| Agent hookup card + location picker | panel | `App/UI/AgentHookupCard.swift` | ExtensionsView.swift:787; Settings › Agents (AgentsSettingsPage.swift:97 uses AgentLocationPicker) |

### Concepts

- `U!` **Session (SessionRecord)** — One terminal running one provider CLI (or a shell) in a project root or worktree; carries provider, accountID, title, providerSessionID (resume handle), worktreePath, parentSessionID, handoffFromSessionID, capabilities, extraArguments, launchSelection, groupID, sleepMode/sleptAt, endedAt/exitCode, restartCount, isPinned, sortIndex (Models.swift:734-795). *Overlaps:* Provider session / thread (providerSessionID), Task assignment, Child session
- `U` **Provider / agent / session kind (AgentProvider incl. .terminal)** — Enum of 8 cases: claude, codex, gemini, opencode, grok, hermes, cursor, terminal. 'Terminal' is a provider with isAgent=false (Models.swift AgentProvider). Nine derived facts (isAgent, reportsStatusThroughHooks, wiresControlPlane, extensionScoping, hasBuiltInUpdater, resumesConversation, defaultShiftEnterNewline, launchCommand, loginCommand) are the de-facto capability registry. *Overlaps:* ExtensionAgentID (Extensions window's agent identity, used by AgentHookupCard/AgentLocationPicker)
- `U` **Account / Profile / login (AccountProfile)** — An isolated config directory handed to the CLI via CLAUDE_CONFIG_DIR / CODEX_HOME at launch (SessionAccountChange.swift:3-10; TerminalHost.swift:227-231). nil = the provider's own default login. *Overlaps:* Usage (a limit belongs to the account), Provider default login (nil)
- `U` **Usage / provider limit** — Remaining % of the most constrained window for a (provider, account) key; drives chip colour, handoff offers and Attention rows (UsageChip.swift, UsageAlert). *Overlaps:* Handoff
- `U` **Handoff** — Creating a '(continued)' session on another provider/account with a written handover file, optionally after asking the outgoing agent (HandoffService.swift:302-345). *Overlaps:* Child session (parentSessionID) — modelled separately on purpose (Models.swift:756-762), Restart with resume
- `U` **Session status (AgentSessionStatus)** — 10 states: unknown, idle, thinking, running, waitingForPermission, waitingForInput, completed, suspended, hibernated, terminated. Labels: Checking…, Ready, Thinking, Running, Waiting for permission, Waiting for a reply, Done, Paused, Asleep, Closed (Models.swift:629-641). Derived predicates: needsAttention, attentionPriority, isKnownLive, isWorking (WorkingTree.swift:32-38). *Overlaps:* Status detail (free text), Attention (unseenAttention), endedAt on the record, McpLinkState, Codex thread status
- `U!` **Status detail** — Free-form string set alongside the status by whichever source last wrote: hooks ('tool: Bash', hook message), Codex app-server ('Structured Codex ready', 'Codex thinking', 'Writing a reply', 'Approval answered', 'Codex login required', 'PTY fallback: …'), resume obstacle ('Started fresh — …'), fixture text. *Overlaps:* Status label
- `U` **Sleep (SessionSleepMode suspended / hibernated)** — suspended = SIGSTOP, process kept; hibernated = process killed, relaunched with resume on wake (SessionSleep.swift:9-14). *Overlaps:* Closed/terminated, Restart
- `U` **Closed / ended / deleted** — Three separate notions: status .terminated (in-memory), record.endedAt (persisted, set by exit/close/control-plane stop), and record removal (Delete). A closed record stays in the sidebar and relaunches on click (SessionDetailView.swift:81-84). *Overlaps:* Sleep, Restart
- `U` **Restart** — closeTerminal + bump lastActivityAt + bump a counter so TerminalHostView rebuilds and the registry relaunches (with resume if the provider store still has the conversation). *Overlaps:* Wake (hibernated wake is a restart with resume), Relaunch-on-open of a closed session
- `U!` **Resume (providerSessionID, AgentResumeDecision / AgentResumeObstacle)** — Whether relaunch carries --resume/resume/--session; decided per provider store (AgentResume.swift). Obstacles become status details. *Overlaps:* Restart, Sleep
- `U!` **Working mode (AgentWorkingMode)** — 12-case enum of provider permission flags (providerDefault, auto, plan, manual, acceptEdits, dangerouslySkipPermissions, askForApproval, approveForMe, fullAccess, dontAsk, onRequest, readOnly), options filtered per provider (Models.swift:273-330). *Overlaps:* Run Parameters free-text flags, Preset extraArguments, Permission profile / capabilities (a different 'permission'), Codex approval policy + sandbox (mapped from mode, AgentLaunchOptions.swift:196-214)
- `U` **Model / effort (AgentLaunchSelection + AgentLaunchCapabilities + SessionRuntimeInfo)** — Optional model/effort chosen at task dispatch; capabilities detected by running the CLI's --help; header resolves reported (hook) → chosen → provider default (SessionRuntimeInfo.swift:45-69). *Overlaps:* Run Parameters, Preset extraArguments
- `U!` **Preset (SessionPreset)** — Template: provider, extraArguments, initialPromptTemplate, grantedCapabilities, permissionMode; the only way create_child may spawn (SessionPreset.swift:1-8). *Overlaps:* Working mode, Run Parameters, Capabilities, Blueprint (a prompt template for a project)
- `U!` **Capabilities / grants (record.capabilities, PolicyEngine, CapabilityCatalog)** — Control-plane grant keys per session; nil = default profile; set at birth from ProjectStore.defaultSessionCapabilities (ProjectStore.swift:439) and by presets for children. *Overlaps:* Working mode (both called 'permission'), Codex approval, Claude permission prompt
- `U` **Permission / approval (three mechanisms)** — (1) Claude hook 'notification' containing 'permission' → status waitingForPermission + banner; answered only inside the terminal (SessionStore+Hooks.swift:84-94). (2) Codex structured approval → CodexApprovalPanel in the session, only under -codex-app-server (CodexAppServerSession.swift:455-495). (3) Control-plane PermissionRequest between sessions → Settings › Permissions rows + notification actions Allow Once/Deny/Open (PermissionNotifications.swift:56-100). *Overlaps:* Working mode, Capabilities
- `U!` **MCP link / control plane (McpLinkState)** — Whether the socket server is up and whether this session's uncoil-mcp helper has called in (McpStatus.swift:36-43). *Overlaps:* Agent hookup level in Extensions (AgentHookupCard 'connected')
- `U!` **Hooks** — Claude Code hook bridge that reports status/prompt/model (only Claude, Models.swift reportsStatusThroughHooks). *Overlaps:* Codex app-server events, Terminal output heuristics (waitUntilInputReady)
- `U` **Split pane / popout window / window ownership (SessionOwnership)** — A session's terminal NSView can be mounted in one window; split shows a second session beside the selected one; popout opens a session in its own window; SessionElsewhereView mediates conflicts. *Overlaps:* New main window (NewWindowOverlay)
- `U` **Worktree / working tree name** — record.worktreePath ?? project.rootPath; the root is called 'main copy' (BranchBadge.swift:14), worktrees by folder name. *Overlaps:* Branch
- `U` **Run default configuration** — The .uncoil/run.json default configuration, surfaced in the session header as play/stop + log button (ProjectRunView.swift:163-236). *Overlaps:* Tests screen
- `U` **Image drop / image paste mode** — Images dropped or ⌘V-pasted are written into <cwd>/.uncoil/dropped/<8-char token>/ and their relative paths typed into the prompt (SessionImageDrop.swift, SessionImageDropService.swift); ImagePasteMode attachFile | agent. *Overlaps:* Artifacts (uncoil_artifacts) — different directory
- `U` **Transcript retention** — Raw PTY output appended to Application Support/transcripts/<id>.log per TranscriptRetentionPolicy (SessionTranscriptStore.swift). Never read by any UI (no transcriptStore reads in App/UI). *Overlaps:* Provider's own resume history, Dead-terminal scrollback kept for 4 sessions (TerminalHost.swift:23-27)
- `U` **Scratch / one-off session** — A session in a synthetic 'Scratch' project (ProjectStore.swift:59-90). *Overlaps:* New Session in a project
- `U` **Group / bulk management** — SessionGroup; group screen with prompt broadcast, interrupt, restart, delete. *Overlaps:* Multi-select in sidebar
- `U!` **Structured Codex / app-server / PTY fallback** — Alternative Codex transport speaking JSON over a Unix socket instead of the TUI; disabled unless -codex-app-server (LaunchConfig.swift:79-87). *Overlaps:* Ordinary Codex TUI session
- `U` **Auto-title** — First prompt (hook, app-submitted, or typed bytes watched by RuntimeTerminalDelegate) replaces placeholder titles ': new session' / 'terminal' (SessionAutoTitle.swift, Models.swift:833-840). *Overlaps:* Rename (no rename for sessions exists in the sidebar menu; only groups have Rename)
- `U` **Child session (parentSessionID)** — Session spawned by another via create_child; drawn with a corner-down-right glyph (SidebarView.swift:912-917). *Overlaps:* Handoff '(continued)', Task assignment role
- `U` **Attention (unseenAttention / needsAttention)** — Sessions that notified and were not opened; sidebar pulse; cleared when the session screen mounts (MainWindow.swift:611). *Overlaps:* Status waitingFor*

### Flows

- **New session from sidebar hover launcher (the everyday path)** (4 steps) — friction: Asks nothing (no model/effort/mode/account), which is fine, but the control is hover-only and the same choice is duplicated with different affordances in the palette, menu bar and dashboard. Right-click for account is undiscoverable.
- **New session from palette / menu bar / one-off** (3 steps) — friction: Three copies of the same title/account logic; palette lists sessionKinds × projects (8 × N items) plus scratch items.
- **Ask an agent… (prompt-first session)** (2 steps) — friction: Readiness is heuristic; the user sees the prompt appear seconds later with no indication that the app is waiting.
- **Send a task to an agent (the most-questions path)** (4 steps) — friction: Eleven questions, four of which (working mode, preset, permission profile, profile) are alternate spellings of 'how much may it do / as whom'. None of these options exist for a plain new session.
- **Other creation paths with their own rules** (7 steps) — friction: Two paths skip the default account (issue, test repair) so those sessions run under the provider's own login even when the user set a default profile — inferred from accountID: nil at both sites. Title conventions differ (provider prefix vs none).
- **Open a closed session** (3 steps) — friction: Looking at history costs a relaunch (and quota if the agent greets). The demo fixture's 'codex: past task' history session (LaunchConfig.swift:201-209) behaves the same.
- **Pause / Hibernate / Wake** (3 steps) — friction: Sleep is only reachable from the sidebar context menu; the header has no pause. Vocabulary shifts Pause/Hibernate/Wake → Paused/Asleep → 'paused'/'asleep'. A paused session counts as isWorking and blocks branch switching with 'X is working in this tree' (WorkingTree.swift:32-38, SessionHeaderBar.swift:373-380) — inferred.
- **Restart from five places** (5 steps) — friction: Two counters (local restartToken + store restartCounter) are summed in .id() (SessionDetailView.swift:85); each site re-implements the sequence.
- **Change the account of a running session** (2 steps) — friction: A menu that looks live but only takes effect on restart; the alert is the only explanation.
- **Approve a Codex command vs answer a Claude permission prompt** (3 steps) — friction: One concept ('the agent wants permission'), three UIs, and the in-session one is behind a launch flag.
- **Drop or paste an image** (4 steps) — friction: Setting lives under Settings › General › Keyboard and Input; a plain terminal silently gets the ordinary paste.
- **Split and popout** (3 steps) — friction: Split has no menu/palette entry and no hint; popout has three entries under two names; popout chrome drops most of the header.
- **Switch branch from the header** (3 steps) — friction: Powerful but hidden inside a metadata line; typing text into other sessions is surprising.
- **Handoff when an account is running out** (3 steps) — friction: Four entry points; the header button exists only while alerting.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| defaultProvider ('Default agent') | global | SettingsStore | Settings › General › Defaults (GeneralSettingsPage.swift:12-25); used by blueprints, issues, tasks, test repair | yes |
| defaultAccount(for:) / accounts | account | SettingsStore.accounts (AccountProfile) | Settings › Agents › Accounts; LoginTerminalSheet; per session via header menu (record.accountID); launcher right-click; TaskDispatchSheet 'Profile' |  |
| workingMode(for:) ('Working Mode' / 'Default agent mode') | global per provider, overridable per session only through task dispatch (record.launchSelection.workingMode) | SettingsStore; SessionRecord.launchSelection | Onboarding step (OnboardingToolSteps.swift:22-58); Settings › Agents › Working Mode (AgentSettingsPages.swift:437-460); TaskDispatchSheet; TaskOrchestratorSheet |  |
| extraArguments ('Run Parameters') | global per provider | SettingsStore.extraArguments[provider] | Settings › Agents › Run Parameters free-text (AgentSettingsPages.swift:385-412) |  |
| SessionPreset.extraArguments / grantedCapabilities / permissionMode | global (preset list) | SettingsStore.presets | Settings › Agents › Session Presets; picked in TaskDispatchSheet; used by create_child |  |
| record.capabilities ('Session Access' / 'Advanced Permissions') | session | SessionRecord.capabilities (nil = default) | Settings › Uncoil › Permissions with a session picker (PrivacySettingsPages.swift:144-224); never from the session screen | yes |
| launchSelection (model / effort) | session (set once at task dispatch / orchestrator) | SessionRecord.launchSelection | TaskDispatchSheet, TaskOrchestratorSheet; shown read-only in header aside |  |
| shiftEnterNewline(for:) | global per provider | SettingsStore | Settings › General › Keyboard and Input (AgentSettingsPages.swift:489-506) | yes |
| optionAsMetaKey | global | SettingsStore | Settings › General › Keyboard and Input (AgentSettingsPages.swift:472-487) |  |
| imagePasteMode | global | SettingsStore | Settings › General › Keyboard and Input › Clipboard (AgentSettingsPages.swift:508-527) | yes |
| transcriptRetentionPolicy | global | SettingsStore; files under Application Support/transcripts | Settings › Uncoil › Data and Transcripts (PrivacySettingsPages.swift:286-293) |  |
| usageWarningsEnabled / usageWarningThreshold | global | SettingsStore | Settings › General › Provider Limits (GeneralSettingsPage.swift:88-120) | yes |
| preferredEditor | global | SettingsStore | Settings › General › Defaults; also silently rewritten by EditorOpenControl's menu on every pick (EditorOpenControl.swift:44-50) | yes |
| launcherProviders ('Quick Launch') | global | SettingsStore.launcher.order | Settings › Appearance › Quick Launch (LauncherSettingsPage.swift) | yes |
| binaryPath / agentBinaryLocation ('Locate…') | global per provider | SettingsStore | Settings › Agents › Installed Agents; Extensions › Connected agents card (AgentLocationPicker) | yes |
| permissionTimeout | global | SettingsStore | Settings › Uncoil › Permissions › Duration (PrivacySettingsPages.swift:126-142) | yes |
| ProjectScopeService per-project MCP/skill scope | project | ExtensionRegistry | Project extension picker; applied at launch (TerminalHost.swift:363-368, 555-580) |  |
| language.agent directive | global | SettingsStore.language | Settings › General › Language | yes |
| TerminalMetalEnabled | global (hidden) | UserDefaults | `defaults write` only (TerminalKeyHandling.swift:124-135) | yes |
| codexAppServerEnabled / codexApprovalFixture / attentionFixture / usageFixture | session (process launch args) | LaunchConfig | Command line only (LaunchConfig.swift:79-96) |  |
| isPinned / sortIndex / groupID / sleepMode | session | SessionRecord | Sidebar context menu and drag only |  |

### Visibility gates

- `App/UI/SessionHeaderBar.swift:129, 173, 237, 346; App/Terminal/TerminalHost.swift:768` — record.provider.isAgent → Account menu, UsageChip, status capsule + McpStatusBadge, capability detection task, image-paste interception. Terminal sessions lose all of these in the header but still show status.label on the dashboard (ProjectDashboardView.swift:756) and group rows (SessionGroupView.swift:210).
- `App/UI/SessionHeaderBar.swift:129-162` — !accountChoices.isEmpty (any AccountProfile for the provider) → Account is a Menu when profiles exist, plain Text when one is set and no profiles exist, nothing when neither.
- `App/UI/SessionDetailView.swift:41-67` — sessionStore.codexApprovals[record.id] != nil / codexAuthentication == .required → Codex approval panel / auth banner. Only reachable when LaunchConfig.codexAppServerEnabled (LaunchConfig.swift:87) or the UI-test fixture (TerminalHost.swift:130-150).
- `App/UI/SessionDetailView.swift:72-88` — record.sleepMode != nil → SleepingSessionView instead of TerminalHostView (mounting would relaunch).
- `App/UI/SessionHeaderBar.swift:65-72, 264-275; App/UI/UsageCard.swift onHandOff` — usageAlert.state.isAlerting (UsageAlert.evaluate ≥ threshold) → Handoff button in the control cluster and the hand-off row in the card.
- `App/UI/SessionHeaderBar.swift:281-282; App/UI/AppKit/SidebarOutline.swift:826` — record.providerSessionID != nil → Restart help suffix '(continues with its history)'; 'Copy the Provider Session ID'.
- `App/UI/SessionHeaderBar.swift:193-227, 352-361` — branch != nil (GitService.currentBranch polled every 15s) → Branch chip and tree name; non-git directories show only the path.
- `App/UI/ProjectRunView.swift:175-182` — RunConfigFile.defaultConfiguration(...) != nil, read from disk on every header render → Run/stop button, spinner while starting, log button only when logFileURL exists, plus a divider.
- `App/UI/EditorOpenControl.swift:17-21, 44` — PreferredEditor.directoryCapable / settings.preferredEditor.opensDirectories → Which editor icon the button wears and which apps the menu lists.
- `App/ControlPlane/McpStatus.swift:36-43` — McpStatusStore.isServing / lastContact[sessionID] → 'MCP off' / 'MCP waiting' / 'MCP connected' — evaluated for every agent session even when Models.swift wiresControlPlane is false (gemini, grok, cursor, hermes), so those sessions show 'MCP waiting' in amber forever while the control plane runs (inferred from the two predicates).
- `App/UI/MainWindow.swift:571-583, 755-761; App/UI/SessionPopoutWindow.swift:43-52, 84-90` — windows.ownership.outcome(claiming:by:) == .heldElsewhere → SessionElsewhereView instead of the terminal; split pane silently dropped.
- `App/UI/MainWindow.swift:596-605` — splitSessionID != nil && != selected id → SplitSessionPane in the HSplitView.
- `App/UI/AppKit/SidebarOutline.swift:845-895; App/Core/SessionSleep.swift:61-90` — SessionSleep.canWake / canSuspend / canHibernate(status, provider.resumesConversation, providerSessionID) → Which of Wake / Pause / Hibernate appear in the sidebar menu; Hibernate absent (not disabled) for gemini/terminal or before an id is known.
- `App/UI/SessionDetailView.swift:45-53` — LaunchConfig.shared.codexApprovalFixture → Test-only branch inside the production approval handler.
- `App/Terminal/TerminalHost.swift:154-160` — shouldUseCodexAppServer: provider == .codex && codexAppServerEnabled && binaryPath != nil && no extra args on settings or record → Structured Codex transport vs PTY; the banner/panel surfaces depend on it.
- `App/Terminal/TerminalHost.swift:76-84` — runtimePhase == .connecting || .ready → Daemon-backed terminal (survives app restart) vs in-process fallback (dies with app); invisible to the user except via the Runtime Mismatch alert (MainWindow.swift:119-130).
- `App/Core/Models.swift:833-840; App/Terminal/TerminalHost.swift:1085-1107` — record.hasPlaceholderTitle (': new session', ': yeni oturum', 'terminal') → Whether the first typed line / first prompt renames the session.
- `App/UI/SidebarView.swift:858-870; App/Core/ProjectStore.swift:772-785` — status.needsAttention || unseenAttention.contains(id) → Sidebar pulse colour and animation; cleared by mounting the session (MainWindow.swift:611).
- `App/UI/SidebarView.swift:708; App/Core/PaletteModel.swift:312; App/UI/ProjectExtensionPicker.swift:324` — settings.launcherProviders → Which providers the hover strip, palette one-off items and extension picker tabs offer; the palette 'New Session' list uses AgentProvider.sessionKinds instead (PaletteModel.swift:341).

### Open questions

- Is the Codex app-server path (and therefore the in-session approval panel and auth banner) intended to ship, or is it permanently behind -codex-app-server? The answer decides whether the session screen has one runtime permission UI or zero.
- The brief mentions a 'Changes panel' in the session screen; no such surface exists in scope (no ChangesPanel/DiffPanel/WorkingTreeChanges symbols anywhere in App/). Was it removed, or is it a planned feature?
- Should Interrupt/Stop be a first-class session action? Today it exists only in the group screen and the menu bar monitor.
- Are recorded transcripts (SessionTranscriptStore) meant to become a readable history, or only a privacy/debug artefact? This shapes what a 'closed' session card should offer.
- Is the nil account (the provider's own login) meant to be a real, nameable account in the UI? The header, task dispatch and usage layer each treat it differently.
- Do gemini/grok/cursor/hermes sessions deliberately show an MCP badge (S9), or is that an oversight of the isAgent gate?
- Is auto-titling a terminal session after its first typed shell command intended (inferred behaviour from the typed-line watcher)?

---

## Usage tracking and handoff (App/Usage, UsageChip, UsageCard, HandoffSheet, Settings > General > Provider Limits, TODO N.7)

From the user's chair, "usage" is a tiny ring-and-percent chip beside the account name in every agent session's header. Clicking it opens a popover ("the card") that lists each provider limit window with a bar, a reset countdown, plan/email, credits, where the number came from, and, only when the account is low, a row that starts a handoff. A limit belongs to a login, not a session, so the same account low in five sessions produces one "Limit approaching" or "Limit reached" row in the Attention Center (and, through it, the menu-bar drop-down and, for "reached", a macOS "Errors and problems" notification). Handoff is a sheet reachable from three places (header button, card row, Attention "Hand off" pill) that lists other installed agent logins ordered by how much they have left, optionally runs the outgoing CLI non-interactively to ask it what it was doing, writes a markdown handover into `.uncoil/handoff/` in the working tree, creates a "(continued)" session on the chosen login, and types one line pointing the new agent at that file. The only settings are a "Warn before an account runs out" toggle and a "Warn at" 5/10/15/20/30 % picker under Settings > General > Provider Limits. Everything else, the 40 % yellow band, refresh cadence, which providers can be read (3 of 7), which can be asked for a handover (2 of 7), the Keychain behaviour, the handover location, the 180 s ask timeout, is hard-coded and invisible. The feature shipped in v0.2.0 (commit bcaa920, 2026-08-13) with no CHANGELOG entry and no onboarding step, so the user first meets the concept as a dashed "—" in a header. TODO N.7.5 plans a rules engine (per-account thresholds, destinations incl. model, fallback chains, per-project overrides, ask-vs-auto, per-session exclusion, a handoff history, loop guard) and today has no home in the UI to land in.

### Findings

#### [CRITICAL] UH-01 — The one decision ("is this account low?") is recomputed in five views/services with the global threshold, and N.7.5 would add a sixth trigger

*Category:* visibility-logic

- `App/UI/SessionHeaderBar.swift:65` — private var usageAlert: UsageAlert.Evaluation? { … UsageAlert.evaluate(usage.snapshot(for: UsageKey(provider: record.provider, accountID: record.accountID)), threshold: settings.usageWarningThreshold)
- `App/UI/SessionHeaderBar.swift:317` — handoff = UsageAlert.evaluate(usage.snapshot(for: UsageKey(…)), threshold: settings.usageWarningThreshold)
- `App/UI/UsageChip.swift:207` — onRequestHandoff?(UsageAlert.evaluate(snapshot, threshold: settings.usageWarningThreshold))
- `App/UI/UsageCard.swift:190` — private var alert: UsageAlert.Evaluation { UsageAlert.evaluate(snapshot, threshold: threshold) }
- `App/Usage/UsageAttention.swift:104` — let evaluation = UsageAlert.evaluate(account.snapshot, threshold: snapshot.threshold)
- `App/Usage/HandoffService.swift:106` — let evaluation = UsageAlert.evaluate(snapshot, threshold: threshold)
- `App/Usage/UsageStore.swift:33` — What it deliberately does not own is any opinion about what the numbers mean: no thresholds, no warnings, no handoffs.
- `TODO.md:404` — A rule is: *when account A drops below N%, hand off to B*.

**Why it matters:** The store is pure by design, so every surface re-derives the verdict itself and threads the threshold through props. A per-project or per-account threshold (N.7.5) has to be plumbed into all six sites or they will disagree about what "low" means, which is precisely the inconsistency the UsagePresentation comment (line 32-35) says the design exists to prevent.

**Direction:** One evaluated "account limit state" per UsageKey computed once (store or a single derived object) that chip, card, header, attention, sheet and future rules all read.

#### [CRITICAL] UH-02 — N.7.5's rules engine has no home: its eight concepts map onto five different existing surfaces and two colliding verbs

*Category:* concept-overload

- `TODO.md:404` — - [ ] A rule is: *when account A drops below N%, hand off to B*. - [ ] Let the destination be another account of the same provider, or a different provider entirely. - [ ] Let the destination model be chosen, not just th
- `TODO.md:410` — - [ ] Let rules be scoped per project, and let a project override the global one. - [ ] Per rule: ask first, or run automatically. - [ ] A per-rule threshold, not one global number. - [ ] Let a session be excluded from a
- `TODO.md:415` — - [ ] Show every handoff that has happened, with its rule and its package.
- `App/UI/HandoffSheet.swift:153` — Text(String(localized: "Ask this agent what it was doing first"))
- `App/UI/Settings/GeneralSettingsPage.swift:91` — Section("Provider Limits") {
- `App/Core/Models.swift:762` — var handoffFromSessionID: UUID?
- `App/Usage/HandoffService.swift:47` — Deliberately not automatic. Every step here is something the user asked for by choosing a destination; the rule that no work moves without being asked is enforced by there being no path through this type that starts itse

**Why it matters:** Today's pieces live in: General (threshold), Agents > Accounts (accounts), the sheet (destination, "ask this agent"), the session header (per-session state), nowhere (per-project, history, model choice, chain). "Ask first" in N.7.5 means ask the user; "Ask this agent" in the sheet means ask the outgoing CLI, same verb, opposite party. The only record of a handoff is `handoffFromSessionID`, which no view reads, so "show every handoff" has no data model to grow from. Building rules on top of this layout would put a fourth trigger (automatic) into a feature whose three manual triggers are already glued by a global mailbox.

**Direction:** Decide the single owner and single settings home of "limits & handoff" (per account, with project override) before N.7.5, and rename one of the two "ask" concepts.

#### [HIGH] UH-03 — The usage chip is drawn for all seven agents but only three have any route; four sessions show a permanent dashed "—"

*Category:* agent-leak

- `App/UI/SessionHeaderBar.swift:173` — if record.provider.isAgent {     UsageChip(
- `App/Core/Models.swift:120` — case .claude, .codex, .gemini, .opencode, .grok, .cursor, .hermes: true
- `App/Usage/UsageStore.swift:60` — let resolved = providers ?? [     CodexUsageProvider(),     ClaudeUsageProvider(probeDirectory: Self.defaultProbeDirectory()),     GeminiUsageProvider(), ]
- `App/Usage/UsageStore.swift:90` — func isSupported(_ provider: AgentProvider) -> Bool {     providers[provider] != nil }
- `App/Usage/UsagePresentation.swift:169` — String(localized: "Uncoil has no way to read usage for \(provider.displayName).")
- `App/UI/UsageChip.swift:166` — // No number, and no placeholder pretending to be one. Text(verbatim: "—")

**Why it matters:** OpenCode, Grok, Hermes and Cursor sessions carry a dead control with a tooltip that explains Uncoil's own limitation, forever. `isSupported` exists exactly for this and is used only by a unit test. Inferred from UsageStore.swift:127-138 (the unsupported branch never sets `refresh.lastAttempt`) plus UsageRefreshPolicy.swift:71 and UsageChip.swift:218-224: those chips also re-run `refresh` every 30 s, and each run rewrites the snapshot with a new `updatedAt`, which through MainWindow.swift:1181 re-derives the whole Attention Center each tick.

**Direction:** Gate the chip on a capability (`isSupported`) rather than on `isAgent`, and record the attempt for unsupported providers so the loop stops.

#### [HIGH] UH-04 — One feature is governed from four settings pages under four unrelated names

*Category:* settings-sprawl

- `App/UI/Settings/GeneralSettingsPage.swift:97` — title: String(localized: "Warn before an account runs out"), detail: String(localized: "Raises a row in the Attention Center when a login is close to a provider limit. The figures in each session's header are shown eithe
- `App/Core/AttentionCenter.swift:150` — case .runtime, .testFailure, .mergeConflict, .taskFailed, .taskBlocked,      .relinkNeeded, .agentCrashed, .usageExhausted:     .problem
- `App/Core/NotificationPrefs.swift:38` — case .problem: String(localized: "A runtime error, a failing test or a dropped connection.")
- `App/UI/MenuBarMonitorView.swift:81` — if settings.menuBar.showSessionsSection, !attention.items.isEmpty {     ForEach(attention.items.prefix(6)) { item in         Button("\(item.kind.label): \(item.title)")
- `CHANGELOG.md:32` — every row in Settings › Agents now has a "Locate…" button … the Agents list, session launch and the usage checks all ask the same question and now get the same answer.
- `App/UI/Settings/SettingsView.swift:107` — case .general, .input: .general case .installedAgents, .accounts, .cliTools, .launchArgs, .agentBehavior, .presets,

**Why it matters:** The user who wants to stop, or get, a "Limit reached" banner has to know it is an "Errors and problems" notification; the user who wonders why limits show in the menu bar has to find `showSessionsSection`; the account whose limit is measured is configured under Agents while the limit itself is under General. Nothing in "Provider Limits" mentions the menu bar or notifications. Every other provider-specific control sits under Settings > Agents (installedAgents, accounts, cliTools, launchArgs, agentBehavior, presets); this is the one that does not.

**Direction:** Co-locate limit and handoff settings with accounts under Agents, and name the notification/menu-bar consequences in the same pane.

#### [HIGH] UH-05 — Provider asymmetry leaks through generic UI: the ask toggle is offered to agents that cannot be asked, and Claude's Keychain rule turns into "Not signed in"

*Category:* agent-leak

- `App/UI/HandoffSheet.swift:151` — Toggle(isOn: $askAgent) {
- `App/Usage/HandoffProducer.swift:40` — static func canProduce(_ provider: AgentProvider) -> Bool {     provider == .claude || provider == .codex }
- `App/Usage/HandoffProducer.swift:95` — return Result(failure: String(localized: "Uncoil cannot ask \(provider.displayName) for a handover."))
- `App/Usage/ClaudeUsageProvider.swift:154` — guard allowKeychain else {     throw UsageFetchError(.credentialsMissing, detail: "needs the Keychain") }
- `App/Usage/UsageStore.swift:214` — case .credentialsMissing, .notApplicable: return .noCredentials
- `App/Usage/UsagePresentation.swift:158` — case .noCredentials:     String(localized: "Not signed in to \(provider.displayName) on this Mac.")
- `App/Usage/ClaudeUsageProvider.swift:126` — Uncoil is a different application, so macOS asks the user before handing it over, and that dialog is exactly what a refresh on a timer must never raise.
- `App/Core/Models.swift:521` — // No verified variable for an isolated Gemini config root, so Uncoil // does not claim to isolate one: profiles for it would share the // CLI's own home and quietly overwrite each other. case .gemini: nil

**Why it matters:** A Gemini/OpenCode/Hermes/Grok/Cursor session that runs low shows the same "Ask this agent what it was doing first" toggle as Claude; the answer arrives only after the wait, as a failure sentence. A Claude user whose CLI is not on Uncoil's search path but whose login is in the Keychain is told they are not signed in until they press refresh, at which point macOS asks a question about another app's credential. A Gemini profile reports the default login's numbers under the profile's name. None of these rules are visible before the user acts.

**Direction:** Drive the toggle and the destination list from a per-provider capability table (can read usage / can be asked / can isolate accounts) and word the Keychain case as "needs your permission" rather than "not signed in".

#### [HIGH] UH-06 — The handover is written into the user's repository as an untracked file and feeds back into the next package and the agent's own view

*Category:* coupling

- `App/Usage/HandoffPrompt.swift:11` — static let directory = ".uncoil/handoff"
- `App/Usage/HandoffService.swift:385` — let relative = "\(HandoffPrompt.directory)/\(session.id.uuidString.prefix(8)).md" let url = URL(fileURLWithPath: session.workingDirectory(in: project))     .appendingPathComponent(relative)
- `App/Core/GitService.swift:36` — if let status = run(["-C", repoPath, "status", "--porcelain"], trimming: false) {     snapshot.changedFiles = status
- `App/Core/SessionImageDropService.swift:116` — .appendingPathComponent(".gitignore")
- `App/Usage/HandoffService.swift:380` — Relative, because that is the one form of path a CLI agent never has to ask permission to read: it is inside the directory it was started in.

**Why it matters:** `git status --porcelain` lists untracked files, so after one handoff `.uncoil/handoff/<id>.md` is a "changed file" in the next package, in the header's changed-files count, and in whatever the incoming agent commits. The image-drop feature solved the identical problem with a local `.gitignore`; the handoff did not. This is an everyday cost for anyone who hands off more than once on a branch.

**Direction:** Write the handover outside the tree (or ignore it the way image drops do) and pass the absolute path; keep a copy in app support for the future history view.

#### [HIGH] UH-07 — Three entry points to one sheet, wired through a global mailbox, plus a fourth surface (menu bar) that looks like an entry point but is not

*Category:* navigation

- `App/UI/SessionHeaderBar.swift:258` — // In the control cluster, not only inside the usage card. A // popover is its own window and its contents are outside the // app's accessibility tree, so anything that lives only in one // is unreachable to a UI test
- `App/UI/UsageCard.swift:199` — private func handoffRow(_ action: @escaping () -> Void) -> some View {
- `App/UI/AttentionCenterView.swift:128` — // A usage row is the one kind with something to *do* beyond going // there, and burying that action inside a popover on the session // header put it where neither a hurried user nor a test could // reach it.
- `App/Usage/HandoffService.swift:3` — /// "Open the handoff for this session", from anywhere. /// /// The Attention Center knows which session is low but does not own the sheet; /// the session header owns the sheet but does not hear about the row. This is /
- `App/UI/MenuBarMonitorView.swift:174` — private func open(_ item: AttentionItem) {     AttentionStore.shared.markRead(item.id)     if let sessionID = item.sessionID {         MainRoute.shared.request(.session(sessionID))

**Why it matters:** The comments record that each entry was added because the previous one was unreachable (popover outside the accessibility tree, hurried user). The result is the same action in the header cluster, inside the card, and in the Attention panel, with the Attention route depending on whichever header happens to be mounted to pick up `HandoffRoute.shared`. The menu-bar row shows "Limit approaching: Claude · Work" and merely navigates. A user cannot form a rule for where handoff lives.

**Direction:** Make the handoff a session-level action with one owner (not the header view) that any surface can invoke directly, and pick one visible affordance per state.

#### [HIGH] UH-08 — Two thresholds, only one of them a setting; two constants for the same default

*Category:* duplicate-concept

- `App/Usage/UsagePresentation.swift:27` — /// The default threshold for `.critical`, and the number the handoff /// feature will eventually take its cue from. static let criticalPercent: Double = 15 static let lowPercent: Double = 40
- `App/Usage/UsagePresentation.swift:38` — if percent <= threshold { return .critical } if percent <= max(threshold, lowPercent) { return .low }
- `App/Usage/UsageAlert.swift:38` — static let defaultThreshold: Double = 15
- `App/UI/Settings/GeneralSettingsPage.swift:121` — localized: "How much of the tightest limit has to be left before Uncoil says something."

**Why it matters:** The chip and bars turn yellow at 40 % remaining; the Attention Center, the header button and the sheet ignore that band entirely. The settings copy promises one number that decides when "Uncoil says something", but the colour says something earlier. `criticalPercent` and `defaultThreshold` are the same 15 in two enums, each with its own comment claiming to be the number handoff takes its cue from.

**Direction:** Either expose the yellow band or drop it; keep one named default.

#### [MEDIUM] UH-09 — Nothing introduces the feature: no onboarding step, no CHANGELOG line, no docs page; the first contact is a dashed ring

*Category:* discoverability

- `App/Core/OnboardingState.swift:9` — enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {     case welcome     case clis     case accounts     case workingModes     case hooks     case notifications     case capabilities     case tools     ca
- `CHANGELOG.md:75` — - Reading a Claude account's limit asks the CLI first, and stops asking for your password.
- `TODO.md:172` — Nothing here exists today: no usage, quota or rate-limit handling appears anywhere in the app.

**Why it matters:** `grep -i 'hand off|handover|handoff|Limit approaching|Provider Limits' CHANGELOG.md` returns nothing, and `git show --stat bcaa920` touched neither CHANGELOG.md nor TODO.md, yet `git tag --contains bcaa920` says v0.2.0. The only changelog mentions of usage are two bug-fix lines about the Claude probe. The TODO intro still says the feature does not exist while N.7.1-N.7.4a are ticked. A user upgrading to 0.2.0 gets a new chip, new Attention rows, a new settings section and a handoff sheet with no sentence explaining any of them.

**Direction:** Write the release note and decide whether the concept belongs in onboarding's Accounts step.

#### [MEDIUM] UH-10 — The provider-default login is a real account with no name, shown as bare "Claude" beside "Claude · Work"

*Category:* terminology

- `App/Usage/HandoffService.swift:95` — // The provider's own default login is a destination in its own // right: most people never make a profile, and a list that only // offered profiles would be empty on a normal machine. let candidates: [(UUID?, String?)] 
- `App/Usage/HandoffService.swift:36` — var label: String {     guard let accountName, !accountName.isEmpty, … else {         return provider.displayName     }     return "\(provider.displayName) · \(accountName)"
- `App/UI/UsageCard.swift:60` — Text(account?.name ?? provider.displayName)
- `App/Usage/CodexUsageProvider.swift:51` — if let override = environment["CODEX_HOME"], !override.isEmpty {     return URL(fileURLWithPath: override) }

**Why it matters:** On a machine with profiles, the sheet lists "Continue with Claude" and "Continue with Claude · Work" and the user must know that the first means "the login outside Uncoil's profiles". The card header, the attention title and the sheet headline all use the same fallback. For Codex, what "default" means silently follows `$CODEX_HOME`. This gap will widen when rules name accounts (N.7.5).

**Direction:** Give the default login a displayed name (e.g. "Claude (default login)") everywhere the account dimension is shown.

#### [MEDIUM] UH-11 — "Hand off", "handoff", "handover", "Continue with", "(continued)", "has the work" name the act, the document and the result interchangeably

*Category:* terminology

- `App/UI/UsageCard.swift:207` — ? String(localized: "Hand this work to another agent") : String(localized: "Hand off before it runs out"))
- `App/UI/HandoffSheet.swift:160` — Without it the handover still carries the branch, the changed files and the diff — but not what was decided.
- `App/UI/HandoffSheet.swift:238` — It writes a handover file and stops. If it cannot answer, the handoff goes ahead with what Uncoil already knows.
- `App/Usage/HandoffService.swift:323` — title: String(localized: "\(session.displayTitle) (continued)"),
- `App/UI/HandoffSheet.swift:268` — Text(String(localized: "\(chosen?.label ?? "") has the work"))
- `App/UI/AttentionCenterView.swift:138` — Text(String(localized: "Hand off"))

**Why it matters:** Within one sheet the document is "a handover file" and "the handover", the act is "the handoff", the button elsewhere is "Hand off", the new session is "(continued)" and the completion says the destination "has the work". The relation between the two sessions is invisible (TODO.md:366-367: "A UI that walks the chain does not exist yet"), so "(continued)" is the only trace.

**Direction:** Pick one noun for the document and one verb for the act, and show the predecessor link on the continued session.

#### [MEDIUM] UH-12 — Rules the user cannot see: attention needs a live session, the picker offers 5 values of a 1-90 range, and "approaching" is red in the header but "not a problem" in the menu bar

*Category:* visibility-logic

- `App/Usage/UsageAttention.swift:37` — The live-session condition is the point. An account nobody is working on cannot be interrupted by running out, so warning about it would be telling the user something they cannot use
- `App/Usage/UsageAttention.swift:52` — guard (statuses[session.id] ?? .unknown) != .terminated else { continue }
- `App/UI/Settings/GeneralSettingsPage.swift:114` — ForEach([5, 10, 15, 20, 30], id: \.self) { percent in
- `App/Core/SettingsStore.swift:267` — usageWarningThreshold = min(90, max(1, percent))
- `App/Core/AttentionCenter.swift:132` — // Approaching is not yet a problem — that is the whole point of the // warning. Escalating the menu-bar icon for it would make the icon // mean "something needs you" when nothing does yet.
- `App/UI/UsageChip.swift:146` — private var severity: UsageDisplay.Severity {     UsageDisplay.severity(of: snapshot, threshold: settings.usageWarningThreshold) }

**Why it matters:** A red chip and a header handoff button on a session whose agent exited produce no Attention row, no badge and no menu-bar line; the same account in a running session does. The chip calls the state `critical` and paints it `Theme.danger` while the menu bar treats it as not a problem. Each rule is defensible; none is stated to the user.

**Direction:** State the live-session rule in the Provider Limits copy and align the header's red with the Attention Center's warn.

#### [MEDIUM] UH-13 — The handoff runs the outgoing CLI with permission-bypass flags in the project directory, under a toggle whose copy says "takes up to a minute" against a 180 s timeout

*Category:* coupling

- `App/Usage/HandoffProducer.swift:143` — + ["--fork-session", "--output-format", "json",    "--dangerously-skip-permissions"],
- `App/Usage/HandoffProducer.swift:208` — "--dangerously-bypass-approvals-and-sandbox",
- `App/Usage/HandoffProducer.swift:93` — timeout: TimeInterval = 180
- `App/UI/HandoffSheet.swift:160` — Takes up to a minute and uses a little of the remaining quota.
- `App/UI/HandoffSheet.swift:25` — Without this, asking the outgoing agent pinned the user in front of a /// spinner for up to three minutes with no way out.
- `App/Usage/HandoffProducer.swift:19` — **The bypass flag belongs here and only here.** Nobody is watching this /// process, so an approval prompt would hang it

**Why it matters:** The rationale is sound and documented in code, but the sheet does not say that a bypass-mode agent process will run in the working tree, and its duration claim disagrees with its own timeout. Users who have set a careful working mode for the session have no way to know the ask ignores it.

**Direction:** Say what the ask runs and how long it may take in the toggle's detail text.

#### [LOW] UH-14 — Dead routes with live labels: `codexStatusTUI` and `claudeWebSession` exist in the source enum and the provenance copy but no strategy produces them

*Category:* duplicate-concept

- `App/Usage/UsageSnapshot.swift:129` — case codexStatusTUI
- `App/Usage/CodexUsageProvider.swift:10` — What is deliberately *not* here is the interactive `/status` TUI.
- `App/Usage/UsagePresentation.swift:116` — case .codexStatusTUI: String(localized: "from Codex's status panel")
- `App/Usage/UsagePresentation.swift:119` — case .claudeWebSession: String(localized: "from your claude.ai session")
- `App/Usage/UsageStore.swift:62` — ClaudeUsageProvider(probeDirectory: Self.defaultProbeDirectory()),
- `TODO.md:223` — - [x] The optional `claude.ai` session route, absent unless a cookie is       supplied.

**Why it matters:** The TODO ticks the cookie route as an opt-in; there is no opt-in anywhere (`webSessionKey` is never passed). Two localised strings and two enum cases describe routes the user can never reach, and the provenance footer already exposes route names ("from the Codex app-server") that the user never configured.

**Direction:** Remove or wire the dead routes; consider whether the footer should name a route at all.

#### [LOW] UH-15 — Test scaffolding lives inside the production chip and service

*Category:* coupling

- `App/UI/UsageChip.swift:87` — enum UsageCardAutoOpen {     private static var used = false
- `App/UI/UsageChip.swift:194` — .onAppear {     guard LaunchConfig.shared.usageFixture, UsageCardAutoOpen.claim() else { return }     DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showCard = true }
- `App/Usage/HandoffService.swift:258` — guard let executable = LaunchConfig.shared.handoffStubPath     ?? settings.binaryPath(for: session.provider)
- `App/Usage/HandoffService.swift:393` — if LaunchConfig.shared.isUITesting {     UITestJournal.append("HANDOVER", url.path)

**Why it matters:** Not user-visible, but every new surface for this feature (N.7.5) inherits the pattern of checking launch flags inside views and services, which is the opposite of a capability registry.

**Direction:** Inject fixtures and stubs at the store/service boundary.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Usage chip | hover-control | `App/UI/UsageChip.swift` | Every agent session header, mounted at App/UI/SessionHeaderBar.swift:173-180 under `if record.provider.isAgent`, between the account menu and the path |
| Usage card (popover) | popover | `App/UI/UsageCard.swift` | UsageChip click; auto-opened 1.2 s after launch under `-usage-fixture` (UsageChip.swift:194-197) |
| Session header handoff button | toolbar | `App/UI/SessionHeaderBar.swift` | Session header, visible only while `usageAlert.state.isAlerting` |
| Handoff sheet | sheet | `App/UI/HandoffSheet.swift` | Header handoff button (SessionHeaderBar:273); Usage card handoff row via onRequestHandoff (UsageChip:205-210 → SessionHeaderBar:179); Attention Center "Hand off" pill via HandoffRoute.shared (Attentio |
| Attention Center usage rows | row | `App/UI/AttentionCenterView.swift` | Attention Center panel; sidebar attention badge (unread count, App/Core/AttentionCenter.swift:424) |
| Menu-bar monitor rows | menu | `App/UI/MenuBarMonitorView.swift` | Menu bar icon drop-down, gated by Settings > Menu Bar `showSessionsSection` |
| Settings > General > Provider Limits | panel | `App/UI/Settings/GeneralSettingsPage.swift` | Settings window > General, between Language and Quitting the App |
| macOS notification for Limit reached | banner | `App/Core/AttentionCenter.swift` | Notification Center, governed by Settings > Notifications > Events > Errors and problems |
| Handover file in the working tree | other | `App/Usage/HandoffService.swift` | Created by every completed handoff; visible in Finder, `git status`, the incoming agent's file tree |
| "(continued)" session in the sidebar | row | `App/Usage/HandoffService.swift` | Sidebar after a handoff; "Open it" in the sheet routes to it |

### Concepts

- `U` **Usage / usage figures** — Percent remaining per provider limit window for one login, normalised across providers (UsageSnapshot). Shown as the chip number, card bars, attention detail. *Overlaps:* Credits, Limit
- `U!` **Window** — One limit the provider reports: primary (session/5h), secondary (weekly), extra (model-scoped). App/Usage/UsageSnapshot.swift:16-93. Titles come from the provider parsers ("Session limit", "Weekly limit", "Weekly limit · Opus"). *Overlaps:* Limit, Usage
- `U` **Most constrained window / headline** — Whichever window has the least left; the single number the chip shows and the alert evaluates (UsageSnapshot.swift:280-284, UsagePresentation.swift:56-61). *Overlaps:* Window
- `U` **Account (incl. the unnamed provider-default login)** — UsageKey = provider + optional AccountProfile id; `nil` is the provider's own default home (~/.claude, ~/.codex or $CODEX_HOME). UsageStore.swift:3-7; CodexUsageProvider.swift:49-55. *Overlaps:* AccountProfile (Settings > Agents > Accounts), Destination
- `U` **Threshold / "Warn at"** — Percent remaining below which an account is "low": `usageWarningThreshold`, default 15, clamped 1-90 in the store (SettingsStore.swift:106, 266-268), offered as 5/10/15/20/30 in the picker. *Overlaps:* Severity.criticalPercent (same 15, second constant, UsagePresentation.swift:29), UsageAlert.defaultThreshold (UsageAlert.swift:38), N.7.5 per-rule threshold
- `U` **Severity band (healthy / low / critical / unknown)** — Colour band for the chip and bars. `critical` = user threshold; `low` = a hard-coded 40 % (`Severity.lowPercent`, UsagePresentation.swift:30, 36-41). Not exposed anywhere as a setting or a word. *Overlaps:* Alert state, Threshold
- `U` **Alert state (none / approaching / reached)** — UsageAlert.evaluate: no numbers → none; provider says limitReached or window ≤0 → reached; ≤ threshold → approaching (UsageAlert.swift:54-76). Drives attention kind, handoff row visibility, sheet headline. *Overlaps:* Severity band
- `U` **Stale figure** — A retained snapshot whose last refresh failed; kept, dimmed, and still alerts (UsageSnapshot.swift:289-294, UsageAlert.swift:78-89).
- `U!` **Source / provenance (route)** — Which fetch strategy answered: codexOAuthAPI, codexAppServerRPC, codexStatusTUI, claudeOAuthAPI, claudeCLIProbe, claudeWebSession, geminiCodeAssistAPI, cache (UsageSnapshot.swift:126-144). *Overlaps:* Strategy
- `U` **Unavailability reason (7)** — noCredentials, credentialsRejected, planReportsNoQuota, accountTierUnsupported, authenticationTypeUnsupported, providerUnsupported, allStrategiesFailed (UsageSnapshot.swift:154-172) with one sentence each (UsagePresentation.swift:156-186).
- `U` **Credits** — Money balance kept apart from quota (UsageSnapshot.swift:100-105).
- `i` **Fetch strategy / pipeline / attempt** — Ordered per-provider routes with typed errors and `continuesToFallback`; retained attempt records (UsageFetchStrategy.swift). Diagnostics text exists (UsageStore.swift:244-264) but is only called from Tests/UsageStoreTests.swift:248.
- `i` **Activity (active / idle / background) and refresh cadence** — 5 / 20 / 60 min intervals, backoff, auth block, post-reset look (UsageRefreshPolicy.swift:39-50). Driven from whichever chips are on screen (UsageChip.swift:216-224); `.background` is never produced by any view (chip maps isWorking → active/idle only, UsageChip.swift:144).
- `i` **userInitiated / Keychain permission** — A manual refresh is the only thing allowed to read the Claude Keychain item; timed refreshes throw `credentialsMissing("needs the Keychain")` (ClaudeUsageProvider.swift:73, 124-165; UsageFetchStrategy.swift:207-213).
- `U` **Handoff (the act)** — User-chosen move of a session's work to another login: HandoffService.run → prepare → collectFromAgent → handOver (HandoffService.swift:197-228). *Overlaps:* Handover (the document), Child session (parentSessionID), Account switch in the header (SessionAccountChange, SessionHeaderBar.swift:52-62)
- `U!` **Handover / package (the document)** — HandoffPackage: what Uncoil knows (project, worktree, branch, changed files, diff, task, tests, processes) + what the agent said (objective, workDone, decisions, openItems, knownProblems, suggestedNextStep) + provenance (HandoffPackage.swift:21-93). Rendered by HandoffPrompt.handover and written to `.uncoil/handoff/<id>.md`. *Overlaps:* Handoff
- `U` **Ground truth / "what Uncoil knows"** — The half of the package gathered from git and the session record without asking the agent (HandoffService.swift:131-194).
- `U` **Destination** — A provider + optional account id with its remaining % and isAlerting; every installed agent's default login plus each profile, minus the source (HandoffService.swift:25-43, 84-127). *Overlaps:* Account, N.7.5 rule destination / chain
- `U` **Ask the outgoing agent (askAgent)** — Sheet toggle, default on, not persisted; runs `claude -p --resume/--continue --fork-session --output-format json --dangerously-skip-permissions` or `codex exec resume … --dangerously-bypass-approvals-and-sandbox -o` through the login shell, 180 s timeout (HandoffProducer.swift:87-228). Only Claude and Codex can be asked (`canProduce`, 40-42). *Overlaps:* N.7.5 "Per rule: ask first, or run automatically" (asks the *user*, a different question with the same verb)
- `i` **Handoff chain (handoffFromSessionID)** — Relation from the continued session to its predecessor, distinct from parentSessionID (Models.swift:756-762). Written by HandoffService.swift:332-334; never read by any view.
- `i` **HandoffRoute** — Global mailbox (`HandoffRoute.shared.request(sessionID:)`) so the Attention Center can open a sheet owned by whichever SessionHeaderBar is mounted (HandoffService.swift:3-18; SessionHeaderBar.swift:314-321).
- `U` **Rule (planned, N.7.5)** — "when account A drops below N%, hand off to B": destination account/provider/model, fallback chain, per-project scope with override, ask-or-auto, per-rule threshold, per-session exclusion, preview, history, loop guard (TODO.md:399-417). Nothing exists in code. *Overlaps:* Threshold, Destination, askAgent, Attention rows, Session capabilities

### Flows

- **Reading usage in the background** (7 steps) — friction: For 4 of 7 agents (OpenCode, Grok, Hermes, Cursor) the chip is permanently "—" with a dashed ring; and because the unsupported branch never records `lastAttempt`, `refreshIfDue` re-runs every 30 s, rewriting the snapshot with a new `updatedAt`, which re-triggers a full Attention refresh each tick (inferred from UsageStore.swift:127-138 + UsageRefreshPolicy.swift:71 + MainWindow.swift:1181; not run).
- **Manual refresh (and the Keychain)** (4 steps) — friction: When the CLI cannot be located but the login is in the Keychain, timed reads say "Not signed in to Claude on this Mac." (credentialsMissing → noCredentials → UsagePresentation.swift:158-159) while the user is signed in; only a manual refresh, with a system dialog, fixes the wording. The rule is invisible to the user.
- **Limit approaching / reached → warning surfaces** (4 steps) — friction: The chip can be red on a stopped session with no Attention row (live-session rule), the toggle in General says "Raises a row in the Attention Center" but the row also drives the menu bar and a notification governed elsewhere, and "approaching" is deliberately not a problem while the chip and card call it critical/red.
- **Handoff end to end** (9 steps) — friction: Three entry points, one global mailbox, a per-presentation service; the sheet says "Takes up to a minute" while the timeout is 180 s and the code comment says "up to three minutes" (HandoffSheet.swift:25,160; HandoffProducer.swift:93); the handover file lands untracked in the user's repo; the new session is an ordinary sibling in the sidebar with no visible link.
- **Configuring the warning** (4 steps) — friction: One global number applied by five separate call sites; the 40 % yellow band is not mentioned anywhere; "Provider Limits" sits in General while every other provider-specific control lives under Agents.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| usageWarningsEnabled ("Warn before an account runs out") | global | settings.json (SettingsStore.Persisted.usageWarningsEnabled, App/Core/SettingsStore.swift:49, 103, 259-262, 805, 857) | Settings > General > Provider Limits (GeneralSettingsPage.swift:92-103) |  |
| usageWarningThreshold ("Warn at") | global | settings.json (SettingsStore.swift:50, 106, 266-268, 806, 858-859) | Settings > General > Provider Limits, segmented 5/10/15/20/30 (GeneralSettingsPage.swift:105-126) |  |
| Severity.lowPercent = 40 (yellow band) | global | hard-coded (App/Usage/UsagePresentation.swift:30, 36-41) | nowhere | yes |
| Refresh cadence 5 / 20 / 60 min, backoff 60 s→30 min, post-reset 30 s | global | hard-coded (App/Usage/UsageRefreshPolicy.swift:39-50) | nowhere | yes |
| menuBar.showSessionsSection | global | settings.json MenuBarPrefs (App/Core/MenuBarPrefs.swift:102) | Settings > Menu Bar |  |
| notifications.problem ("Errors and problems") | global | settings.json NotificationPrefs (App/Core/NotificationPrefs.swift:14, 26, 38) | Settings > Notifications > Events |  |
| askAgent ("Ask this agent what it was doing first") | session | @State in HandoffSheet, default true, not persisted (HandoffSheet.swift:21, 151-169) | Handoff sheet | yes |
| Claude claude.ai session cookie (webSessionKey) | global | nowhere; the injection point exists (ClaudeUsageProvider.swift:24-25, 76-83) but UsageStore builds the provider without it (UsageStore.swift:60-64) and no other caller passes it | nowhere |  |
| Handover location `.uncoil/handoff/` | project | hard-coded (App/Usage/HandoffPrompt.swift:11); files written into the session working directory (HandoffService.swift:382-403) | nowhere | yes |
| Ask timeout 180 s | global | hard-coded default parameter (HandoffProducer.swift:93) | nowhere | yes |
| Handoff bypass flags (--dangerously-skip-permissions / --dangerously-bypass-approvals-and-sandbox) | global | hard-coded (HandoffProducer.swift:143-144, 208) | nowhere |  |
| agentBinaryLocations / "Locate…" | global | settings.json (SettingsStore.swift:82-87) | Settings > Agents rows and the Extensions card (CHANGELOG.md:32) |  |
| AccountProfile (isolated config directory) | account | settings.json accounts + profiles root | Settings > Agents > Accounts |  |
| Per-project rule override (N.7.5) | project | does not exist | nowhere; nearest existing per-project surface is the project's Customize tabs ("MCP & Skills", CHANGELOG.md 0.2.0) — inferred landing spot |  |
| Per-session exclusion (N.7.5) | session | does not exist; nearest analogue is SessionRecord.capabilities / sessionCapabilityDefaults (Models.swift:763-765; SettingsStore.swift:78-80) | nowhere |  |

### Visibility gates

- `App/UI/SessionHeaderBar.swift:173-180` — `if record.provider.isAgent` → UsageChip mounts for all seven agents (Models.swift:118-121) although UsageStore has providers for only claude/codex/gemini (UsageStore.swift:60-64); `UsageStore.isSupported` (90-92) is called by no view (only Tests/UsageStoreTests.swift:205).
- `App/UI/UsageCard.swift:41-44` — `if let onHandOff, alert.state.isAlerting` → Card handoff row. `onHandOff` is nil when `session == nil || onRequestHandoff == nil` (UsageChip.swift:205).
- `App/UI/SessionHeaderBar.swift:264` — `if let usageAlert, usageAlert.state.isAlerting` → Header handoff button; `usageAlert` re-evaluates the snapshot with the global threshold (65-71).
- `App/Usage/UsageAttention.swift:101 and 51-52` — `guard snapshot.isEnabled else { return [] }` and only accounts with a non-terminated agent session → Attention rows; a red chip on a session whose process ended never produces a row.
- `App/UI/AttentionCenterView.swift:132-133` — `item.kind == .usageLow || item.kind == .usageExhausted, let sessionID = item.sessionID` → The "Hand off" pill; the only kind with an inline action.
- `App/UI/MenuBarMonitorView.swift:81-82` — `settings.menuBar.showSessionsSection, !attention.items.isEmpty` → `prefix(6)` → Usage rows in the menu bar; no handoff action there.
- `App/Core/AttentionCenter.swift:128-140` — `isProblem`: usageExhausted true, usageLow false → Menu-bar icon escalation (MenuBarMonitor.swift:134).
- `App/Core/AttentionCenter.swift:150-158` — `notificationEvent`: usageExhausted → .problem, usageLow → nil → macOS banner, under the "Errors and problems" event.
- `App/UI/Settings/GeneralSettingsPage.swift:105` — `if settings.usageWarningsEnabled` → Whether the "Warn at" picker and its note are visible.
- `App/UI/HandoffSheet.swift:59-62; App/Usage/HandoffService.swift:93-104` — `installedProviders.contains(provider)` where installed = `settings.binaryPath(for:) != nil || locateBinary(launchCommand) != nil`; `candidate != key` → Which destinations appear; default login is always a candidate alongside profiles (98-100).
- `App/Usage/HandoffProducer.swift:40-42, 95-96` — `HandoffProducer.canProduce`: `.claude || .codex` → Whether "Ask this agent" can succeed; the toggle itself is not gated (HandoffSheet.swift:151).
- `App/Usage/ClaudeUsageProvider.swift:73, 150-156` — `allowKeychain: userInitiated`; `guard usesDefaultHome` → Whether the Claude OAuth route may read the Keychain (manual refresh only, default account only).
- `App/Usage/ClaudeUsageProvider.swift:76-83` — `if let webSessionKey` → The claude.ai cookie strategy; never satisfied in the app (UsageStore.swift:60-64).
- `App/UI/UsageChip.swift:194-197` — `LaunchConfig.shared.usageFixture, UsageCardAutoOpen.claim()` → Auto-opening the card 1.2 s after launch in UI-test runs; test scaffolding inside the production view.
- `App/Usage/HandoffService.swift:258-260` — `LaunchConfig.shared.handoffStubPath ?? settings.binaryPath(for:) ?? locateBinary(...)` → Which executable the ask runs; UI-test stub takes precedence.
- `App/UI/MainWindow.swift:1181` — `.onChange(of: usage.entries) { onAttention() }` → Every usage cache mutation re-derives the whole Attention Center.

### Open questions

- Is the macOS keychain-access dialog actually raised by `SecItemCopyMatching` with `kSecUseAuthenticationUIFail` (App/Usage/UsageCredentials.swift:63)? The code comments (ClaudeUsageProvider.swift:124-137) and TODO.md:280-286 say yes; not verified in this audit.
- The 30 s re-refresh loop for unsupported providers (UH-03) and its Attention re-derivation are inferred from reading UsageStore.swift:127-138, UsageRefreshPolicy.swift:71, UsageChip.swift:218-224 and MainWindow.swift:1181; not observed at runtime.
- Where, if anywhere, should `UsageStore.diagnostics(for:)` surface? It is called only from Tests/UsageStoreTests.swift:248.
- TODO.md:315-317 leaves open whether the figure itself belongs in the menu-bar monitor; today only the derived rows reach it.
- Does the incoming agent end up committing `.uncoil/handoff/*.md`? Depends on each project's .gitignore; nothing in the app prevents it.
- N.7.4 open items that shape N.7.5: task re-pointing (TODO.md:369), completion notification (373), running-process capture (335-336), user preview/edit of the package (346).

---

## First-run onboarding (App/UI/Onboarding, OnboardingState/Presenter, SettingsStore onboarding fields, About > Setup guide)

Onboarding is a 13-page full-window overlay that opens on a fresh install (or when OnboardingFlow.currentVersion is bumped) and covers the main window until the user reaches the last page or presses Skip. From the user's side it is not a setup wizard with a required path but a guided tour of every subsystem Uncoil has: language, seven agent CLIs, seven account profiles, seven working-mode pickers, Claude Code hooks, macOS notifications, the MCP capability model (8 toggle groups), three third-party binaries, the first project plus editor, TODO.md tasks, the extension store and its scanner, and the command-palette hotkey. Eleven of the thirteen pages are flagged 'actionable', all are skippable, and none is required: pressing Skip on page one silently marks all eleven as done and the app appears. Every control on these pages is a re-implementation of a Settings control that also exists elsewhere (8 Settings panes plus the Extensions window), with one exception that exists only here (the new-session capability defaults). The 'Finish setup' resume row that the copy on three pages and the CHANGELOG promise is unreachable by construction, so the only way back into any step is Settings > About > 'Run again', which resets and replays all thirteen pages. The flow has grown from 9 to 11 to 13 steps in one week (three version bumps) because each new feature added a page, and TODO.md N.2 already calls it 'the worst thing about the product' and asks for a rewrite whose required path is 'detect the CLIs, pick one project, start'.

### Findings

#### [CRITICAL] ONB-01 — The 'Finish setup' resume row is unreachable, yet three pages, the About copy and the CHANGELOG promise it

*Category:* visibility-logic

- `App/UI/Onboarding/OnboardingView.swift:125` — if !remaining.isEmpty && !settings.shouldPresentOnboarding {
- `App/Core/SettingsStore.swift:736` — guard onboardingVersion != OnboardingFlow.currentVersion else { return [] }
- `App/Core/OnboardingState.swift:89` — return stampedVersion < currentVersion
- `App/UI/Onboarding/OnboardingView.swift:80` — settings.markOnboardingStepCompleted(step)
- `App/UI/Onboarding/OnboardingView.swift:103` — for step in settings.remainingOnboardingSteps {
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:75` — If you add Claude Code later, come back through “Finish setup” in the sidebar — or Settings › Uncoil › Agent Status Hooks.
- `App/UI/Onboarding/OnboardingProjectSteps.swift:185` — Add a project and Uncoil scans it for task files. You can come back to this from the sidebar.
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:288` — Anything you skipped stays listed at the bottom of the sidebar under “Finish setup”.
- `App/Core/OnboardingState.swift:7` — afterwards — an unfinished step stays listed in the sidebar's resume row

**Why it matters:** The row needs remaining non-empty (version != 3) and the overlay not due (version nil or < 3 is false) — only a version > 3 satisfies both, i.e. a downgrade. Every exit from the flow (skip link, corner Skip, Start working) marks the visited/remaining steps complete and stamps the version, so 'skip now, finish later' — the model the whole flow's copy relies on and TODO N.2's 're-enterable with no reset' — does not exist. The unit test that claims to cover it (OnboardingFlowTests.swift:129-136) tests the store, not the view gate.

**Direction:** Decide whether skipped and done are different states; if they are, model it in data and give each step a real re-entry point instead of a whole-flow reset; if not, delete the row and the copy.

#### [CRITICAL] ONB-02 — Setup is a tour of every subsystem: 13 pages, 11 'actionable', zero required, and it grows by one page per feature

*Category:* onboarding

- `App/Core/OnboardingState.swift:9` — enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
- `App/Core/OnboardingState.swift:48` — case .welcome, .finish: false
- `App/Core/OnboardingState.swift:61` — static let currentVersion = 3
- `App/UI/Onboarding/OnboardingView.swift:5` — Its job is to hand over the four things a new user cannot discover on their
- `TODO.md:42` — ## N.2 Setup is painful and incomplete — revise it from the start
- `TODO.md:52` — Make the required path short enough to finish in one sitting: detect the CLIs, pick one project, start.
- `TODO.md:490` — 1. [ ] N.2 — setup, rewritten. Every new user meets it, and it is currently the
- `TODO-archive-0.1.0.md:1874` — ## 36.3 What setup should also cover

**Why it matters:** Git history: 9 steps at 7bbb890 (2026-07-27, v1), 11 at 57393c7 the same day (liveStatus split into hooks+notifications, palette added, v2), 13 at fc7d752 (2026-08-03, workingModes+tools, v3). Stage 36.3 was literally titled 'What setup should also cover' and added three items. The view comment still says the flow exists to hand over 'four things'. isActionable is the only classification and it treats a hotkey and the first project the same; nothing marks a step required, recommended or explanatory, so every new feature can (and does) claim a page and a version bump that replays the tail for existing users.

**Direction:** Classify steps by necessity (required for first use / recommended / explanatory-only) and let the flow render only the first class; move the rest to contextual first-use moments.

#### [HIGH] ONB-03 — Every onboarding control is a hand-rolled copy of a Settings control (12 controls, 8 panes + Extensions window), and the copies drift

*Category:* duplicate-concept

- `App/UI/Onboarding/OnboardingIntroSteps.swift:64` — Picker(selection: Binding(
- `App/UI/Settings/GeneralSettingsPage.swift:47` — Picker(selection: Binding(
- `App/UI/Onboarding/OnboardingToolSteps.swift:43` — Picker("", selection: Binding(
- `App/UI/Settings/AgentSettingsPages.swift:434` — Picker(selection: Binding(
- `App/UI/Onboarding/OnboardingToolSteps.swift:77` — default:
- `App/UI/Onboarding/OnboardingToolSteps.swift:78` — String(localized: "Whatever the CLI does by default.")
- `App/UI/Settings/AgentSettingsPages.swift:445` — detail: settings.workingMode(for: provider).detail(for: provider)
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:171` — Toggle(isOn: Binding(
- `App/UI/Settings/NotificationSettingsPages.swift:107` — Toggle(isOn: bind(\.onlyWhenBackgrounded)) {
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:98` — try HookInstaller.install()
- `App/UI/Settings/PrivacySettingsPages.swift:382` — try HookInstaller.install()
- `App/Extensions/AgentHookupService.swift:191` — try HookInstaller.install()
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:226` — HotkeyRecorder(
- `App/UI/Settings/GeneralSettingsPage.swift:160` — HotkeyRecorder(
- `App/UI/Onboarding/OnboardingProjectSteps.swift:268` — switch TodoStarter.create(in: projectPath) {
- `App/UI/ProjectDashboardView.swift:647` — switch TodoStarter.create(in: project.rootPath) {
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:148` — let service = ExtensionAdoptionService(layout: registry.layout)
- `App/UI/ExtensionsView.swift:1357` — let service = ExtensionAdoptionService(layout: registry.layout)

**Why it matters:** Mapping: language x2 and default agent, editor, hotkey → Settings > General; accounts → Agents > Accounts; working mode → Agents > Working Mode; hooks → Uncoil > Agent Status Hooks + Agents > Installed Agents + Extensions > Agents; notification permission/toggles → Notifications > General; drivers → Uncoil > Drivers; Bumblebee → Extensions > Security; adoption → Extensions; TODO starter → project dashboard. Each is re-bound by hand, so wording, consequence text and grouping already differ: the onboarding working-mode description mislabels Codex/Cursor 'Read Only' and Grok 'Don't Ask' as the CLI default, while Settings uses the model's own detail(for:).

**Direction:** One row component per setting, reused by any surface that shows it; onboarding composes rows, it does not re-implement them.

#### [HIGH] ONB-04 — The capabilities step writes a setting that has no home anywhere else, while telling the user it lives in Settings › Uncoil › Permissions

*Category:* coupling

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:353` — You can change all of this later in Settings › Uncoil › Permissions.
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:365` — settings.setSessionCapabilityDefaults(granted)
- `App/Core/SettingsStore.swift:763` — func setSessionCapabilityDefaults(_ capabilities: Set<String>?) {
- `App/Core/ProjectStore.swift:439` — record.capabilities = Self.defaultSessionCapabilities
- `App/UI/Settings/PrivacySettingsPages.swift:83` — Text("Project, session, artifact and Agent Browser are on by default in new sessions. Computer Use stays off for every session until you turn it on.")
- `App/UI/Settings/PrivacySettingsPages.swift:261` — record.capabilities = grants.sorted()
- `App/UI/Settings/SettingsView.swift:347` — title: String(localized: "Control plane not running"),

**Why it matters:** grep shows setSessionCapabilityDefaults/effectiveSessionCapabilities are called only from onboarding and SettingsStore. The Permissions pane edits one selected session's record.capabilities, hardcodes the default sentence regardless of the onboarding override, and disappears when the control plane is off. The same keys are grouped three ways: 8 onboarding cards (OnboardingPlatformSteps.swift:234-305), 4 Settings access groups (PrivacySettingsPages.swift:17-69), CapabilityCatalog domains in the advanced section — string literals duplicated in each view with no registry. A user who enabled Computer Use on page 7 cannot turn the default off without About > Run again.

**Direction:** Give new-session defaults a single owner (a preset or a Settings row) and one group taxonomy; onboarding either shows that row or nothing.

#### [HIGH] ONB-05 — Three provider-matrix pages: 21 cards for a one-CLI user, including 'Sign in' and mode pickers for agents that are not installed

*Category:* agent-leak

- `App/UI/Onboarding/OnboardingIntroSteps.swift:121` — private let providers: [AgentProvider] = AgentProvider.agents
- `App/UI/Onboarding/OnboardingIntroSteps.swift:264` — settings.accounts.map {
- `App/Core/SettingsStore.swift:782` — for provider in AgentProvider.agents
- `App/Core/SettingsStore.swift:784` — accounts.append(AccountProfile(provider: provider, name: "Default", directoryName: nil))
- `App/UI/Onboarding/OnboardingIntroSteps.swift:304` — Button(String(localized: "Add a \(provider.displayName) profile")) {
- `App/UI/Onboarding/OnboardingToolSteps.swift:33` — ForEach(providers) { provider in
- `App/Core/Models.swift:304` — [.providerDefault]
- `App/Core/Models.swift:323` — [.providerDefault, .dangerouslySkipPermissions]
- `App/Core/Models.swift:120` — case .claude, .codex, .gemini, .opencode, .grok, .cursor, .hermes: true

**Why it matters:** CLIs (7 cards), Accounts (7 cards + 7 'Add a … profile' buttons, no install filter), Working modes (7 pickers, Gemini with a single option). The provider list is derived (cc12953), so every new provider adds three onboarding cards by construction. Per-agent choices sit in the global first-run path instead of appearing when that agent is first used.

**Direction:** Show only detected providers, and ask per-provider questions at the first launch of that provider.

#### [HIGH] ONB-06 — Prerequisite knowledge runs backwards: pages 4-8 depend on concepts introduced on pages 9-13 or never

*Category:* onboarding

- `App/UI/Onboarding/OnboardingToolSteps.swift:30` — footnote: String(localized: "Uncoil never raises a session above the mode you pick here — a child agent inherits its parent's, intersected, and cannot escalate.")
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:29` — subtitle: String(localized: "Claude Code reports its state through hooks. Without them a Claude session is just a terminal: no working / needs-input state, no notifications, no attention list."),
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:249` — detail: String(localized: "uncoil_sessions — the agent sees the other sessions in its project and can start a child agent. No raw shell is ever accepted: children come from named presets only."),
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:240` — detail: String(localized: "uncoil_projects · uncoil_artifacts — the agent reads your projects, cuts a worktree for itself, and leaves files behind that you can open."),
- `App/UI/Onboarding/OnboardingToolSteps.swift:142` — detail: String(localized: "A second opinion on every extension. Uncoil scans packages itself either way; Bumblebee adds a deeper pass.
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:279` — detail: String(localized: "Every session shows working, needs input or done. Anything waiting on you collects in the Attention Center and in the menu-bar monitor.")

**Why it matters:** To act on page 4 you need child agents and intersection (page 7); page 5 assumes session states and the attention list (page 13); page 7 assumes sessions, worktrees, artifacts, TODO.md tasks (page 10), runs, presets (Settings only), browser and Computer Use drivers (page 8); page 8's Bumblebee assumes the extension scanner (page 11). A first-time user is asked to make trust decisions about a tool model they have not seen run.

**Direction:** Order by what the user can already see; defer trust and integration questions to the moment the feature is first invoked.

#### [HIGH] ONB-07 — Three exits per page whose persisted effect is identical: Continue, 'Or skip this for now.' and Skip all mark the step done

*Category:* onboarding

- `App/UI/Onboarding/OnboardingView.swift:79` — private func advance() {
- `App/UI/Onboarding/OnboardingView.swift:86` — private func complete() {
- `App/UI/Onboarding/OnboardingView.swift:87` — settings.markOnboardingStepCompleted(step)
- `App/UI/Onboarding/OnboardingView.swift:88` — advance()
- `App/Core/SettingsStore.swift:70` — /// Onboarding steps actually completed (skipped ones stay out).
- `App/UI/Onboarding/OnboardingChrome.swift:324` — var title: String = String(localized: "Or skip this for now.")
- `App/UI/Onboarding/OnboardingChrome.swift:91` — Text("Skip")

**Why it matters:** complete() marks then calls advance() which marks again; the persisted comment 'skipped ones stay out' has been false since 8e45f41. The user is offered a distinction (skip vs continue) that the product does not keep, and the persistent corner 'Skip' next to a per-page skip link is two skips with different scope and the same label family.

**Direction:** Either one exit per page, or make skip a first-class state that later surfaces can act on.

#### [MEDIUM] ONB-08 — Inconsistent commit model: most pages write settings on every change, the project is added the moment a folder is picked, but capabilities apply only on Continue

*Category:* onboarding

- `App/UI/Onboarding/OnboardingIntroSteps.swift:150` — set: { settings.defaultProvider = $0; settings.save() }
- `App/UI/Onboarding/OnboardingProjectSteps.swift:147` — projectStore.addProject(at: url)
- `App/UI/Onboarding/OnboardingProjectSteps.swift:132` — /// The project is added to the store the moment it is chosen, so choosing
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:313` — primaryAction: apply,
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:358` — OnboardingSkipLink(action: onSkip)

**Why it matters:** A dedicated undo rule and four tests (OnboardingProjectChoiceTests) exist only because the project step commits eagerly; the capabilities step is the one page where Back or the skip link discards toggles the user already flipped. Back therefore means different things on different pages.

**Direction:** Pick one model (draft-until-Continue or live) for all pages.

#### [MEDIUM] ONB-09 — A version bump replays the whole tail of the flow, not 'the new steps only' as the code comment claims

*Category:* visibility-logic

- `App/Core/OnboardingState.swift:58` — /// A stamped version lower than this reopens the flow at the new steps only.
- `App/UI/Onboarding/OnboardingView.swift:66` — step = OnboardingFlow.resumeStep(completed: settings.onboardingCompletedSteps)
- `App/UI/Onboarding/OnboardingView.swift:81` — guard let next = OnboardingFlow.next(after: step) else { return finish() }
- `App/UI/Onboarding/OnboardingProjectSteps.swift:48` — title: String(localized: "Add your first project"),

**Why it matters:** A v2 user upgrading to v3 lands on workingModes and then walks 10 pages including 'Add your first project' with projects already present. Combined with ONB-02, every feature that adds a step costs every existing user a full tour.

**Direction:** Present only steps not yet completed, or replace the version gate with per-feature first-use prompts.

#### [MEDIUM] ONB-10 — Empty machine reads as failure: not-found CLIs, not-signed-in accounts and no-project all still get full pages with warning badges

*Category:* empty-state

- `App/UI/Onboarding/OnboardingIntroSteps.swift:178` — badge: path == nil ? String(localized: "Not found") : String(localized: "Installed"),
- `App/UI/Onboarding/OnboardingIntroSteps.swift:340` — badgeTint: isSignedIn ? Theme.ok : Theme.warn,
- `App/UI/Onboarding/OnboardingIntroSteps.swift:353` — : AnyButtonStyle(AccentButtonStyle()))
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:74` — title: String(localized: "Claude Code is not installed"),
- `TODO.md:59` — - [ ] Handle the empty cases properly — no CLI installed, no project, no

**Why it matters:** Six 'Not found' warn badges and six 'Not signed in' warn badges with accent Sign-in buttons on a Mac that has only Claude; LoginTerminalSheet runs the provider's login command in a shell whether or not the binary exists (LoginTerminalSheet.swift:81-87, inferred failure mode). N.2 names this explicitly.

**Direction:** Treat absence as the ordinary starting state: no card, or one quiet line.

#### [MEDIUM] ONB-11 — The only re-entry is Settings › About › 'Run again', which resets everything and replays all 13 pages; its description names 6 of 11 steps

*Category:* navigation

- `App/UI/Settings/AboutSettingsPage.swift:75` — detail: String(localized: "Runs the first-run flow again: CLIs, accounts, hooks, agent capabilities, tasks and extensions.")
- `App/UI/Settings/AboutSettingsPage.swift:79` — settings.resetOnboarding()
- `App/Core/SettingsStore.swift:755` — onboardingVersion = nil
- `TODO.md:57` — - [ ] Make setup re-enterable: a user who skipped a step must be able to finish

**Why it matters:** A guided setup that can only be re-run wholesale from an About page, next to Debug bundle, is not discoverable as a way to finish one thing; and re-running re-applies the window resize.

**Direction:** Per-step entry from the place the feature lives, or drop the re-run entirely once steps are contextual.

#### [MEDIUM] ONB-12 — Each setup topic has two or three names between the enum, the page title and the Settings pane

*Category:* terminology

- `App/Core/OnboardingState.swift:32` — case .hooks: String(localized: "Status tracking")
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:28` — title: String(localized: "Let Uncoil see what your agents are doing"),
- `App/UI/Settings/SettingsView.swift:148` — case .hooks: String(localized: "Agent Status Hooks")
- `App/UI/Settings/AgentsSettingsPage.swift:27` — subtitle: String(localized: "Every agent CLI Uncoil found on this Mac, and how deeply it is connected.")
- `App/Core/OnboardingState.swift:34` — case .capabilities: String(localized: "Agent capabilities")
- `App/UI/Settings/SettingsView.swift:146` — case .permissions: String(localized: "Permissions")
- `App/Core/OnboardingState.swift:35` — case .tools: String(localized: "Optional tools")
- `App/UI/Settings/SettingsView.swift:150` — case .drivers: String(localized: "Drivers")
- `App/UI/Onboarding/OnboardingIntroSteps.swift:299` — title: String(localized: "Want a second account?"),
- `App/UI/Onboarding/OnboardingIntroSteps.swift:300` — detail: String(localized: "A profile gets its own config root (CLAUDE_CONFIG_DIR / CODEX_HOME), so a work login and a personal one never mix — and each session picks the profile it runs under.")

**Why it matters:** Status tracking / hooks / connected; Agent capabilities / Permissions / Session Access; Optional tools / Drivers / Security; account / login / profile — the words a user learns on day one do not match the words they will search Settings for (the Settings search keywords at SettingsView.swift:193-213 are a symptom). The 13 enum titles themselves are dead strings: no UI reads OnboardingStep.title.

**Direction:** One name per concept, used by the step, the pane and the search index.

#### [MEDIUM] ONB-13 — Internal identifiers are the copy: env vars, file paths, hook event ids, tool ids, grant keys, driver names, JSON

*Category:* agent-leak

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:44` — detail: String(localized: "Uncoil adds its own entries to ~/.claude/settings.json and nothing else:
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:47` — Text(HookInstaller.managedEvents.joined(separator: " · "))
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:337` — > uncoil_tasks {"action":"help"}
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:340` — "requires": ["tasks.read", "tasks.write"] }
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:275` — detail: String(localized: "uncoil_browser — driven by the optional agent-browser driver over a Playwright-managed Chromium,
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:283` — detail: String(localized: "uncoil_computer — sees this Mac's screen and drives its mouse and keyboard through the optional cua-driver,
- `App/UI/Onboarding/OnboardingToolSteps.swift:203` — title: String(localized: "Cua Driver — Computer Use"),

**Why it matters:** The first-run pages are where a non-expert forms the mental model; they are written for someone who already knows what an MCP tool id, a grant key and a Playwright profile are.

**Direction:** Describe outcomes; keep identifiers behind a disclosure or in docs.

#### [MEDIUM] ONB-14 — The 'Optional tools' page mixes three interaction models (real download, external web guide, text-only pointer) for three binaries the required path does not need

*Category:* onboarding

- `App/UI/Onboarding/OnboardingToolSteps.swift:148` — : String(localized: "Download and install Bumblebee")) {
- `App/UI/Onboarding/OnboardingToolSteps.swift:213` — open("https://cua.ai/docs/how-to-guides/driver/install")
- `App/UI/Onboarding/OnboardingToolSteps.swift:236` — Text("Installed from Settings › Uncoil › Drivers, where the driver's own setup runs. It is a separate download, so it asks first.")
- `TODO.md:54` — - [ ] Move the optional installs (Bumblebee, Cua Driver, agent browser) out of

**Why it matters:** The page cannot actually set up two of its three items, and the backlog already schedules its removal (N.2, N.4).

**Direction:** Remove from setup; surface each at the first capability that needs it.

#### [MEDIUM] ONB-15 — Setup resizes and persists the main window frame as a side effect, on every presentation including 'Run again'

*Category:* coupling

- `App/UI/Onboarding/OnboardingChrome.swift:147` — static let size = NSSize(width: 1180, height: 780)
- `App/UI/Onboarding/OnboardingChrome.swift:182` — host.setFrame(frame, display: true, animate: false)
- `App/UI/Onboarding/OnboardingChrome.swift:185` — host.saveFrame(usingName: MainWindowFrame.autosaveName)

**Why it matters:** A window preference is changed by a flow whose job is configuration hand-off; it only skips when the window is already larger, so re-running setup on a deliberately small window resizes it.

**Direction:** Size the overlay content, not the user's window.

#### [MEDIUM] ONB-16 — Hooks page is hardcoded to Claude and Codex while the hookup service knows eight agents and installs Hermes hooks too

*Category:* agent-leak

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:22` — private var hasClaude: Bool { settings.binaryPath(for: .claude) != nil }
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:5` — /// The hook install, which is Claude Code's mechanism and nobody else's.
- `App/Extensions/AgentHookupService.swift:186` — case (.hermes, .installHooks), (.hermes, .completeHooks):
- `App/Extensions/AgentHookupService.swift:187` — try HermesHookInstaller.install()
- `App/Extensions/ExtensionModels.swift:13` — case amp

**Why it matters:** Provider-specific visibility logic lives in the view (hasClaude/hasCodex) and has already fallen behind the service that owns the same question (AgentIntegrationLevel across ExtensionAgentID, including Amp which is not an AgentProvider at all). Two agent enumerations (AgentProvider 7 + terminal, ExtensionAgentID 8) feed different pages.

**Direction:** One agent registry answering 'installed / connected / how to connect'; onboarding and Installed Agents both read it.

#### [MEDIUM] ONB-17 — No UI test covers onboarding; the unit suite tests the pure flow but not the gates that make the resume row and finish footnote dead

*Category:* test-coverage

- `Tests/OnboardingFlowTests.swift:129` — /// A flow that was never finished still knows what is undone — that is the
- `Tests/OnboardingFlowTests.swift:130` — /// case the resume row exists for.
- `Tests/OnboardingFlowTests.swift:135` — XCTAssertFalse(store.remainingOnboardingSteps.isEmpty)
- `App/UI/Onboarding/OnboardingView.swift:125` — if !remaining.isEmpty && !settings.shouldPresentOnboarding {

**Why it matters:** grep -i onboarding UITests/ returns nothing. The test asserts the store side of a condition whose view side can never be met, so the suite is green while the feature is unreachable.

**Direction:** Test the presentation decision (view gate) as a pure function alongside the flow.

#### [LOW] ONB-18 — Stale documentation and copy around the flow

*Category:* other

- `CLAUDE.md:126` — `liveStatus`, `capabilities`, `project`, `tasks`, `extensions`, `finish`),
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:264` — subtitle: String(localized: "Four things that make the difference on day one."),
- `App/UI/Settings/PrivacySettingsPages.swift:373` — case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
- `CHANGELOG.md:160` — Every step can be skipped and the whole flow can be left from the corner; what was skipped stays listed as "Finish setup" at the bottom of the sidebar

**Why it matters:** CLAUDE.md lists a step removed on 2026-07-27 and omits five current ones; the finish page promises four cards and shows three; the hooks Settings page (where onboarding sends users) has an untranslated Turkish string; the 0.1.0 release notes describe a resume behaviour that does not exist.

**Direction:** Regenerate the step list from the enum in docs; fix the strings when the flow is restructured.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Onboarding overlay (host) | screen | `App/UI/MainWindow.swift` | app launch (presentOnboardingIfNeeded); Settings > About > Setup guide > Run again; -route onboarding [-onboarding-step id] |
| Scaffold: top bar dots + Skip, bottom bar Back + primary | toolbar | `App/UI/Onboarding/OnboardingChrome.swift` | every step |
| Step 1/13 welcome — enum title 'Welcome', page 'Welcome to Uncoil' | screen | `App/UI/Onboarding/OnboardingIntroSteps.swift` | first page |
| Step 2/13 clis — 'Agent CLIs' / 'Choose your agent CLIs' | screen | `App/UI/Onboarding/OnboardingIntroSteps.swift` | after welcome |
| Step 3/13 accounts — 'Accounts' / 'Sign your agents in' or 'We found t | screen | `App/UI/Onboarding/OnboardingIntroSteps.swift` | after clis |
| Step 4/13 workingModes — 'Working modes' / 'How much should an agent d | screen | `App/UI/Onboarding/OnboardingToolSteps.swift` | after accounts |
| Step 5/13 hooks — 'Status tracking' / 'Let Uncoil see what your agents | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | after workingModes |
| Step 6/13 notifications — 'Notifications' / 'Be told when an agent nee | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | after hooks |
| Step 7/13 capabilities — 'Agent capabilities' / 'What your agents may  | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | after notifications |
| Step 8/13 tools — 'Optional tools' / 'Optional tools' | screen | `App/UI/Onboarding/OnboardingToolSteps.swift` | after capabilities |
| Step 9/13 project — 'First project' / 'Add your first project' | screen | `App/UI/Onboarding/OnboardingProjectSteps.swift` | after tools |
| Step 10/13 tasks — 'Tasks' / 'Tasks come from your TODO.md' | screen | `App/UI/Onboarding/OnboardingProjectSteps.swift` | after project |
| Step 11/13 extensions — 'Extensions' / 'Skills and MCP servers, with a | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | after tasks |
| Step 12/13 palette — 'Command palette' / 'One shortcut for everything' | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | after extensions |
| Step 13/13 finish — 'Ready' / 'You're set up' | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | after palette |
| Sidebar resume row 'Finish setup (N)' | row | `App/UI/Onboarding/OnboardingView.swift` | sidebar bottom |
| Settings > About > Support > Setup guide 'Run again' | row | `App/UI/Settings/AboutSettingsPage.swift` | Settings > About |

### Concepts

- `U` **Setup / first-run flow / Setup guide / Finish setup** — The 13-page overlay. Called 'setup' in the flow copy ('Skip setup' in comments, 'Finish setup' in the resume row), 'Setup guide' in About, 'first-run flow' in docs and CHANGELOG, 'onboarding' in code and launch args. *Overlaps:* Settings (every control), Extensions window, Installed Agents
- `i` **Step (OnboardingStep)** — One page of the flow; enum of 13 cases with a localized title and an isActionable flag. Titles are defined (OnboardingState.swift:26-42) but no surviving UI reads them — the top bar shows unlabeled dots and the resume row shows a count.
- `i` **Actionable step** — Every step except welcome and finish (OnboardingState.swift:46-51). Drives what the resume row would count. There is no notion of required vs recommended vs explain-only.
- `U` **Skip (three flavours)** — Per-step 'Or skip this for now.' (advance: marks the step complete, moves on), corner 'Skip' (skipAll: marks every remaining step complete, stamps the version, dismisses), and 'Start working' on the last page (also skipAll). Continue and the per-step skip have identical persisted effect (OnboardingView.swift:79-89).
- `i` **Onboarding version gate** — OnboardingFlow.currentVersion (3) vs settings.onboardingVersion; a lower stamp reopens the flow at the first uncompleted actionable step and then walks every subsequent page.
- `U!` **Account profile / login / isolated config root** — An AccountProfile per provider; the auto-created 'Default' one is the provider's own config root, additional ones get CLAUDE_CONFIG_DIR / CODEX_HOME. The page calls them 'logins', 'accounts' and 'profiles' interchangeably and names the env vars. *Overlaps:* Settings > Agents > Accounts
- `U` **Working mode** — Per-provider default approval policy (AgentWorkingMode), mapped to CLI flags. Onboarding shows it as 'Working modes'; Settings calls the pane 'Working Mode' and the section 'Default agent mode'. *Overlaps:* Session Presets permissionMode, per-session launch selection
- `U!` **Status hooks** — Entries Uncoil writes into ~/.claude/settings.json (and ~/.hermes/config.yaml via HermesHookInstaller) so the agent reports state. Onboarding: 'Status tracking'; Settings: 'Agent Status Hooks'; Installed Agents: 'how deeply it is connected' / 'Connect'. Event names (HookInstaller.managedEvents) and the file path are shown to the user. *Overlaps:* AgentIntegrationLevel (none/observed/controlPlane/hooks)
- `U!` **Capability / grant / capability group** — String keys like sessions.control_children gated by PolicyEngine; onboarding groups them into 8 cards with an 'Opt-in' badge, Settings > Permissions into 4 'Access groups', and the advanced section into CapabilityCatalog domains. Raw keys and tool ids are printed on the onboarding page. *Overlaps:* Session Presets, Permission requests (PermissionService), Blueprints capability stamping
- `i` **Session capability defaults** — settings.sessionCapabilityDefaults: the set stamped onto every new session; nil means PolicyEngine.defaultGrants. Written only by the onboarding capabilities step; no Settings pane edits it; the Permissions overview text ignores it. *Overlaps:* Session Presets grantedCapabilities, per-session record.capabilities
- `U!` **Preset (SessionPreset)** — Named session recipe child agents may ask for. Mentioned on the capabilities page ('children come from named presets only') before presets are ever shown; configured in Settings > Agents > Session Presets. *Overlaps:* working mode, capability defaults
- `U!` **Driver (agent-browser, cua-driver) / Bumblebee** — Third-party binaries: 'agent-browser driver over a Playwright-managed Chromium', 'cua-driver', and the Bumblebee scanner. Onboarding calls the page 'Optional tools'; Settings calls the browser/cua pane 'Drivers'; Bumblebee lives in Extensions > Security. Internal names are used verbatim in the copy. *Overlaps:* Capabilities browser/computer groups
- `U` **Adoption (take over external installs)** — Copying skills/MCP servers found in agents' own directories into Uncoil's store after a backup. Offered in onboarding and in the Extensions window with the same planner. *Overlaps:* Extensions window
- `U!` **Control plane / MCP server / eight tools** — Uncoil's per-session MCP server and its tool ids (uncoil_projects …). Introduced on page 7 with tool ids, grant keys and a JSON sample; welcome bullet 3 alludes to it. *Overlaps:* Permissions, Installed Agents (MCP wiring level)
- `U` **TODO.md task source / task board** — Markdown checkboxes that become the Tasks tab; onboarding scans and offers a starter file, the project dashboard offers the same.
- `U` **Attention list / Attention Center / menu-bar monitor** — Where sessions needing the user collect. Named on the hooks page (page 5) as something lost without hooks and only explained on the finish page (page 13).

### Flows

- **Fresh install, walk every page (Claude Code installed only)** (14 steps) — friction: 13 pages, ~25 controls, 21 provider cards across three pages for a one-CLI user; the only value-adding actions for first use (detect CLI, add project) are on pages 2 and 9; pages 5, 7, 8, 11 require concepts (hooks, MCP, capabilities, presets, child agents, worktrees, drivers, scanner ladder) that the app has not shown yet.
- **Skip on page one** (3 steps) — friction: Skipping is indistinguishable from finishing in persisted state; the promise on three pages ('come back through Finish setup in the sidebar') is unfulfilled; only About > Run again re-enters, replaying all 13 pages.
- **Upgrade v2 → v3 (a step was added)** (4 steps) — friction: OnboardingState.swift:58-59 says the flow reopens 'at the new steps only'; in practice it replays the whole tail. Every feature that adds a step re-runs the tour for every existing user.
- **Change a capability default after setup** (4 steps) — friction: The one setting onboarding owns exclusively is the one with no home in Settings; three different groupings of the same keys (8 / 4 / catalog domains).
- **Re-run from Settings > About** (4 steps) — friction: There is no way to open a single step; the entry is under About next to Debug bundle; its description lists 6 of 11 steps.
- **Deterministic launch for verification** (4 steps) — friction: CLAUDE.md:125-126 still lists 'liveStatus' (removed 2026-07-27) and omits workingModes, hooks, notifications, tools, palette. No UI test touches onboarding (grep UITests/ → none).

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| Interface language | global | settings.json language.interface (SettingsStore.swift:67, 119-126) | Onboarding welcome (OnboardingIntroSteps.swift:64-77); Settings > General > Language (GeneralSettingsPage.swift:47-60) | yes |
| Agent language | global | settings.json language.agent | Onboarding welcome (79-92); Settings > General (62-75) | yes |
| Default agent (defaultProvider) | global | settings.json defaultProvider (SettingsStore.swift:32) | Onboarding CLIs (OnboardingIntroSteps.swift:148-162); Settings > General > Defaults (GeneralSettingsPage.swift:12-25) | yes |
| Resolved binaries + CLI versions | global | settings.json resolvedBinaries; cliVersions in memory (SettingsStore.swift:33, 132) | Auto at launch (MainWindow.swift:888); Onboarding CLIs rescan; Settings > Agents > Installed Agents locate (agentBinaryLocations); Settings > Agents > CLI Tools | yes |
| Account profiles + default account per provider | account | settings.json accounts, defaultAccountByProvider; profiles/ directories | Onboarding accounts (OnboardingIntroSteps.swift:246-377); Settings > Agents > Accounts (AgentSettingsPages.swift:8-130) | yes |
| Working mode per provider | agent | settings.json via SettingsStore.setWorkingMode (exact field not verified) | Onboarding working modes (OnboardingToolSteps.swift:43-54); Settings > Agents > Working Mode (AgentSettingsPages.swift:434-447); overridden per session at launch (TaskDispatchSheet.swift:279, TerminalHost.swift:537) | yes |
| Claude Code status hooks (and Hermes hooks) | integration | ~/.claude/settings.json (HookInstaller); ~/.hermes/config.yaml (HermesHookInstaller) | Onboarding hooks (OnboardingPlatformSteps.swift:94-104, Claude only); Settings > Uncoil > Agent Status Hooks (PrivacySettingsPages.swift:378-392); Settings > Agents > Installed Agents connect/connect all (AgentHookupService.apply); Extensions > Agents card |  |
| macOS notification authorization | global | System (UNUserNotificationCenter) | Onboarding notifications (OnboardingPlatformSteps.swift:140-152); Settings > Notifications > General NotificationPermissionRow (NotificationSettingsPages.swift:64) |  |
| notifications.onlyWhenBackgrounded / suppressForVisibleSession | global | settings.json notifications | Onboarding notifications (171-192); Settings > Notifications > General > Delivery (107-118) | yes |
| Session capability defaults | global | settings.json sessionCapabilityDefaults → ProjectStore.defaultSessionCapabilities → SessionRecord.capabilities at creation (SettingsStore.swift:72, 763-776; ProjectStore.swift:439) | Onboarding capabilities ONLY (OnboardingPlatformSteps.swift:364-367); no Settings pane | yes |
| Bumblebee binary | integration | BumblebeeLocator.managedDirectory | Onboarding tools (OnboardingToolSteps.swift:176-196); Extensions > Security > BumblebeeSetupSection (ExtensionsView.swift:2598) |  |
| cua-driver / agent-browser | integration | External installs probed by CuaDriverAdapter / AgentBrowserAdapter; browser choice in UserDefaults (DriverSetupSections.swift:17) | Onboarding tools shows status + web guide only; Settings > Uncoil > Drivers installs (DriverSetupSections.swift) |  |
| Projects | project | ProjectStore (projects.json) | Onboarding project (OnboardingProjectSteps.swift:137-149); sidebar/MainWindow folderPicker (MainWindow.swift:279-287, 376) |  |
| Preferred editor | global | settings.json preferredEditor | Onboarding project step (102-116); Settings > General (27-43); EditorOpenControl.swift:46 | yes |
| TODO.md starter | project | <project>/TODO.md | Onboarding tasks (266-278); project dashboard hint (ProjectDashboardView.swift:641-657) |  |
| Extension adoption | integration | Extension store + registry bindings | Onboarding extensions (146-193); Extensions window adopt-all (ExtensionsView.swift:1355+) |  |
| Command palette hotkey | global | settings.json commandPaletteHotkey | Onboarding palette (226-234); Settings > General > Command Palette (GeneralSettingsPage.swift:151-168) | yes |
| onboardingVersion / onboardingCompletedSteps | global | settings.json (SettingsStore.swift:68-71, 128-130, 871-873) | OnboardingView advance/complete/skipAll/finish; About > Run again resets |  |
| Main window frame | window | NSWindow autosave (MainWindowFrame.autosaveName) | OnboardingWindowSizer on every presentation (OnboardingChrome.swift:169-186) | yes |

### Visibility gates

- `App/UI/MainWindow.swift:650-659; App/Core/OnboardingState.swift:87-90` — settings.onboardingVersion == nil || < OnboardingFlow.currentVersion (3), and not a UI-testing run unless -route onboarding → Whether the overlay opens on launch
- `App/UI/MainWindow.swift:71-82` — OnboardingPresenter.shared.isPresenting → OnboardingView mounted over mainContent; NewWindowOverlay hidden while presenting
- `App/UI/Onboarding/OnboardingView.swift:62-67` — LaunchConfig.onboardingStep parses → that step; else completedSteps non-empty → OnboardingFlow.resumeStep; else welcome → Which page the flow opens on
- `App/UI/Onboarding/OnboardingView.swift:125; App/Core/SettingsStore.swift:735-738` — !remainingOnboardingSteps.isEmpty && !shouldPresentOnboarding, where remaining is [] whenever version == currentVersion → Sidebar 'Finish setup' row — satisfiable only when stamped version > current (downgrade); dead otherwise
- `App/UI/Onboarding/OnboardingView.swift:79-112` — advance() marks the current step completed whether the user pressed Continue or 'Or skip this for now.'; skipAll marks all remaining; dismiss only via finish() → Persisted completion state — skip and complete are identical
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:287` — !settings.remainingOnboardingSteps.isEmpty at the finish page (before finish() stamps the version) → Footnote 'Anything you skipped stays listed … under Finish setup' — never true on a normal walk since every visited step is marked complete
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:22-23, 36, 79` — settings.binaryPath(for: .claude) != nil / (.codex) != nil → Which cards the hooks page shows; five other providers get no card
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:21, 40-43, 51-55, 63-68` — HookInstaller.status() == .installed; .partiallyInstalled shows missing events → Badge and the Install hooks button
- `App/UI/Onboarding/OnboardingIntroSteps.swift:278-283` — signedIn.isEmpty (any profile with a readable email) → Accounts page title/subtitle variant
- `App/UI/Onboarding/OnboardingIntroSteps.swift:356` — settings.accounts(for: provider).count > 1 → 'Make default' button on an account card
- `App/UI/Onboarding/OnboardingIntroSteps.swift:173-200, 212-228` — path == nil per provider; npmPackage non-empty; installPage per provider switch → Install command row and vendor link on a CLI card
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:119, 140-151` — authorization.status == .denied / .granted → Allow vs Open System Settings button label and style
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:231, 286, 295, 302, 322-323` — group.isOptional (hardcoded per group) → 'Opt-in' badge on 3 of 8 capability groups; toggle on-state = all keys of the group ⊂ granted (326)
- `App/UI/Onboarding/OnboardingToolSteps.swift:65-80` — settings.workingMode(for:) switch with a default branch → Consequence sentence under each mode picker — readOnly/dontAsk/onRequest fall into 'Whatever the CLI does by default.'
- `App/UI/Onboarding/OnboardingToolSteps.swift:132-141, 204-217, 230-233` — bumblebee.isEmpty; cua?.installed != true; browser?.installed → Badges and which of the three tool cards offers a button
- `App/UI/Onboarding/OnboardingProjectSteps.swift:50-51, 56-95` — addedProject == nil → Primary 'Continue' hidden; chooser vs project card
- `App/UI/Onboarding/OnboardingProjectSteps.swift:40-43, 60-66` — FileManager.fileExists(path + '/.git') → Git badge and worktree copy
- `App/UI/Onboarding/OnboardingProjectSteps.swift:10-19, 139-146` — OnboardingProjectChoice.shouldRemovePrevious(previous, new, previousHasSessions) → Whether re-choosing a folder deletes the previously added project
- `App/UI/Onboarding/OnboardingProjectSteps.swift:181-232` — projectPath == nil / scanning / found.isEmpty / else → Four task-page states
- `App/Core/OnboardingState.swift:102-116` — OnboardingAdoption.adoptable: source == .detectedExternal && not blocked by an unaccepted .blocked finding → Which packages the adopt-all button covers
- `App/UI/Onboarding/OnboardingChrome.swift:165-186` — !isFixedSizeRun (no -window-width/-height) && host.frame smaller than 1180x780 → Window resize + frame persistence
- `App/UI/Settings/SettingsView.swift:343-351` — sessionStore.permissionService != nil → Whether the Permissions pane the capabilities step points to exists at all
- `App/UI/Settings/AboutSettingsPage.swift:38` — updater.isAvailable → Software Update section on the About page where 'Run again' lives

### Open questions

- Is 'skipped' meant to be a real state the app can act on later (contextual prompts), or should the resume row and its copy be removed outright?
- Should new-session capability defaults survive as a global setting at all, or fold into Session Presets / a single Permissions row — and which of the three groupings (8 / 4 / catalog) is canonical?
- Which agents are meant to get a hooks offer during setup — Claude only (page copy), Claude+Hermes (hookup service), or none until first launch?
- Is the intended required path really 'detect CLIs, pick one project, start' (TODO N.2:52)? If so, do language, default agent and editor stay in setup or become inferred defaults?
- Should per-provider questions (account, working mode) move to the first launch of that provider, and if so where is that moment in the session-creation flow?
- Where should 'set this up again' live once About > Run again goes — per feature, in a Settings overview, or nowhere?
- Does the window-frame side effect need to survive a redesign of the overlay?
- The exact settings.json field that setWorkingMode writes was not verified in this pass (inferred: providerBehaviors or a sibling); confirm before mapping config points into a registry.

---

## Global Settings window (App/UI/Settings/*, App/Core/SettingsStore.swift and the pref model/service files it fronts)

Settings is a separate window (⌘, / sidebar gear / palette "Settings: <pane>") built as a NavigationSplitView with 6 categories and 24 panes (23 + About; `SettingsView.Pane.allCases`, App/UI/Settings/SettingsView.swift:73-101). From the user's seat it is three different things wearing one chrome: (1) real preferences (General, Keyboard and Input, Notifications ×5, Theme, Menu Bar, Quick Launch, Data and Transcripts); (2) agent setup and maintenance, most of it a provider×setting matrix that repeats the same 7 agent rows on six panes (Installed Agents, Accounts, CLI Tools, Run Parameters, Working Mode, Shift+Enter in Input, Per Agent in Uncoil MCP); and (3) integration/status pages with few or no stored settings (Uncoil MCP is pure status, Agent Status Hooks and Drivers install things, GitHub is a login, Permissions is a live approval queue plus per-session grant editing). The category named "Uncoil" — inside an app called Uncoil — holds the six panes that did not fit elsewhere, and the file admits the tree was reshaped to satisfy a "no category of one page" rule enforced by a unit test. Several concepts appear under internal names (Session Presets with "Identity"/"Grants"/capability keys, "Control plane", "Helper binary", "Drivers", "Live events"), two different agent identity enums feed different panes (Amp exists only in Installed Agents), the same action (install Claude hooks) is reachable from four surfaces, and the defaults for what new sessions may do are editable only by re-running onboarding from About. Storage is scattered across settings.json, theme.json, UserDefaults, Keychain, ~/.claude/settings.json, ~/.hermes/config.yaml, sessions.json, permissions.json and a blueprints folder, and Backup/Uninstall services exist with no UI at all.

### Findings

#### [CRITICAL] S1 — Seven 'Agents' panes are per-provider matrices that grow by construction with every new provider

*Category:* concept-overload

- `App/UI/Settings/SettingsView.swift:108` — case .installedAgents, .accounts, .cliTools, .launchArgs, .agentBehavior, .presets, .blueprints: .agents
- `App/Core/Models.swift:40` — static let agents: [AgentProvider] = allCases.filter(\.isAgent)
- `App/UI/Settings/AgentSettingsPages.swift:20` — ForEach(providers) { provider in
- `App/UI/Settings/AgentSettingsPages.swift:396` — ForEach(providers) { provider in
- `App/UI/Settings/AgentSettingsPages.swift:434` — ForEach(providers) { provider in
- `App/UI/Settings/AgentSettingsPages.swift:491` — ForEach(providers) { provider in
- `App/UI/Settings/McpSettingsPage.swift:522` — ForEach(AgentProvider.agents) { provider in
- `App/Core/SettingsStore.swift:781` — for provider in AgentProvider.agents         where !accounts.contains(where: { $0.provider == provider && $0.directoryName == nil }) {

**Why it matters:** Accounts (7 sections, each with a forced 'Default' row), CLI Tools (7 rows), Run Parameters (7 fields), Working Mode (7 pickers), Keyboard › Shift+Enter (7 toggles) and Uncoil MCP › Per Agent (7 rows) all iterate `AgentProvider.agents`; Installed Agents iterates the 8 `ExtensionAgentID`s. A user with one CLI installed sees ~50 agent rows across the window, and the eighth provider will add a row to every one of them automatically. The setting is organised by setting-kind, so the question 'what is configured for Claude' has no single answer.

**Direction:** Pivot to one page per installed agent (or one agent-detail sheet) that owns location, hooks, account, mode, parameters and shortcuts for that agent; keep uninstalled agents out of matrices.

#### [CRITICAL] S2 — Two agent identity enums feed different panes; Amp exists only in Installed Agents

*Category:* duplicate-concept

- `App/Extensions/ExtensionModels.swift:8` — enum ExtensionAgentID: String, Codable, CaseIterable, Identifiable, Sendable {     case claudeCode     case codex     case geminiCLI     case cursor     case amp
- `App/Extensions/ExtensionModels.swift:43` — case .amp: nil
- `App/Core/Models.swift:20` — enum AgentProvider: String, Codable, CaseIterable, Identifiable {     case claude     case codex     case gemini     case opencode     case grok     case hermes     case cursor     case terminal
- `App/UI/Settings/AgentsSettingsPage.swift:112` — ?? state.agent.provider.flatMap { settings.cliVersions[$0.rawValue] }

**Why it matters:** Installed Agents shows 'Claude Code', 'Gemini CLI', 'Grok CLI', 'Amp'; the next pane over (Accounts) shows 'Claude', 'Gemini', 'Grok' and no Amp. The version on an Installed Agents row is stitched from the other enum's cache. A user cannot form one list of 'my agents'.

**Direction:** One agent registry with one display name per agent; ExtensionAgentID and AgentProvider should be one type or one derived from the other.

#### [CRITICAL] S3 — Claude hook install has four surfaces and two services; the dedicated Hooks pane is a Claude-only subset of Installed Agents

*Category:* duplicate-concept

- `App/UI/Settings/PrivacySettingsPages.swift:341` — @State private var status = HookInstaller.status()
- `App/UI/Settings/PrivacySettingsPages.swift:375` — case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
- `App/Extensions/AgentHookupService.swift:186` — case (.hermes, .installHooks), (.hermes, .completeHooks):                 try HermesHookInstaller.install()
- `App/UI/Settings/AgentsSettingsPage.swift:40` — action: { Task { await hookup.apply(to: state.agent) } },
- `App/UI/AgentHookupCard.swift:38` — await hookup.apply(to: state.agent)
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:98` — try HookInstaller.install()
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:75` — come back through “Finish setup” in the sidebar — or Settings › Uncoil › Agent Status Hooks.

**Why it matters:** The same act is 'Install' on Uncoil › Agent Status Hooks, 'Connect' on Agents › Installed Agents, 'Connect' on Extensions › Agents, and 'Install hooks' in onboarding. The Hooks pane does not know about Hermes hooks and does not repair stale paths, and it leaks a Turkish label into the English UI. Onboarding points users at the weakest of the four.

**Direction:** Delete the Hooks pane; keep hook state as a property of the agent row; route onboarding and Extensions to that one row.

#### [CRITICAL] S4 — Permissions pane fuses two systems (capability grants vs. runtime permission requests) and cannot edit the one default users are told it can

*Category:* coupling

- `App/UI/Settings/PrivacySettingsPages.swift:96` — if !service.pending().isEmpty {                 Section("Awaiting Approval") {
- `App/UI/Settings/PrivacySettingsPages.swift:150` — Picker(selection: $selectedSessionID) {                         ForEach(projectStore.sessions) { session in
- `App/UI/Settings/PrivacySettingsPages.swift:198` — Section(isExpanded: $showAdvanced) {                 if let record = selectedSession {                     ForEach(CapabilityCatalog.grouped(), id: \.domain.id) { group in
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:353` — You can change all of this later in Settings › Uncoil › Permissions.
- `App/Core/SettingsStore.swift:763` — func setSessionCapabilityDefaults(_ capabilities: Set<String>?) {
- `App/UI/Settings/SettingsView.swift:344` — if let service = sessionStore.permissionService {                 PermissionsSettingsPage(service: service)             } else {                 SettingsUnavailablePage(

**Why it matters:** 'Permissions' here means (a) a live queue of once/permanent/deny decisions, (b) per-session capability toggles reached through a picker over every session of every project, and (c) a timeout — but not the default grant set for new sessions, which only onboarding writes (`setSessionCapabilityDefaults` has one UI caller, OnboardingPlatformSteps.swift:365). The whole pane vanishes when the control plane is off, taking the timeout with it. The notification's 'Open' action goes to the session, where there is no approval UI.

**Direction:** Split: a global 'what new sessions may do' preference; per-session grants beside the session; the approval queue in the Attention Center or the session, not Settings.

#### [HIGH] S5 — 'Uncoil' as a category inside Uncoil, and a tree shaped by a 'no category of one' rule rather than a mental model

*Category:* navigation

- `App/UI/Settings/SettingsView.swift:58` — case .uncoil: "Uncoil"
- `App/UI/Settings/SettingsView.swift:117` — "Security and Data" and "Integrations" were dissolved into this             // rather than left beside it. Splitting them three ways would have             // put Permissions and the control plane that enforces them unde
- `Tests/MenuBarPrefsTests.swift:132` — func testNoCategoryIsAHeadingOverASinglePage() {         for category in SettingsView.Category.allCases where category != .about {             XCTAssertGreaterThan(                 category.panes.count, 1,
- `Tests/MenuBarPrefsTests.swift:152` — for pane: SettingsView.Pane in [.permissions, .mcp, .hooks, .drivers, .github, .privacyData] {             XCTAssertEqual(pane.category, .uncoil, pane.rawValue)

**Why it matters:** The category name carries no information to the user (everything in the window is Uncoil). Its six panes are four integration/setup pages (MCP status, Hooks, Drivers, GitHub), one runtime queue (Permissions) and one preference (Data). The unit test freezes this grouping, so the next restructuring has to fight the test suite as well as the code.

**Direction:** Name categories by user intent (e.g. Agents / Notifications / Appearance / Connections / Privacy) and drop the 'no single-page category' rule from tests.

#### [HIGH] S6 — Panes filed by implementation home rather than by where users look: Blueprints under Agents, Quick Launch and Sidebar pulse under Appearance, Per Project notifications in global Settings, Session Presets beside Accounts

*Category:* navigation

- `App/UI/Settings/SettingsView.swift:113` — case .theme, .menuBar, .launcher: .appearance
- `App/UI/Settings/BlueprintsSettingsPage.swift:4` — /// Settings → Agents → Blueprints: the saved prompts a project can be set up /// from
- `App/UI/Settings/AppearanceSettingsPage.swift:34` — Section("Attention") {                 Picker(selection: Binding(                     get: { settings.attentionEmphasis },
- `App/UI/Settings/NotificationSettingsPages.swift:436` — ForEach(projectStore.projects) { project in                 Section(project.name) {                     ProjectNotificationRows(project: project)
- `Tests/MenuBarPrefsTests.swift:145` — XCTAssertEqual(SettingsView.Pane.launcher.category, .appearance)

**Why it matters:** A blueprint is about starting a project; a preset is about child agents spawned over MCP; the pulse is about being notified; per-project overrides belong to the project. Each lives where the code that implements it happened to be. `rg ProjectSettings` finds no project-side settings surface at all, so a per-project preference is only reachable from the global window.

**Direction:** Move project-scoped and session-scoped settings beside their objects; group the rest by what the user is trying to change.

#### [HIGH] S7 — Preferences, integration setup and status pages share one chrome; Uncoil MCP stores nothing, CLI Tools is an updater, GitHub is a login

*Category:* other

- `App/UI/Settings/McpSettingsPage.swift:465` — /// There is nothing to install here, and that is the first thing the page has /// to say.
- `App/UI/Settings/McpSettingsPage.swift:551` — Button(String(localized: "Capabilities…")) {                         SettingsRoute.shared.requestedPane = SettingsView.Pane.permissions.rawValue
- `App/UI/Settings/AgentSettingsPages.swift:269` — Button("Update") { Task { await settings.updateCLI(provider) } }
- `App/Core/SettingsStore.swift:621` — let result = await Task.detached(priority: .userInitiated) {             CLIToolService.runUpdate(command: command)         }.value
- `App/UI/Settings/IntegrationsSettingsPages.swift:428` — KeychainStore.save(key: "github-token", value: token)

**Why it matters:** Of 24 panes, 8 are setup/status (Installed Agents, CLI Tools, Accounts, Hooks, Drivers, GitHub, Uncoil MCP, About), 1 is a runtime queue (Permissions) and 15 are preferences. The user learns nothing from the sidebar about which is which; 'Uncoil MCP' has a single button that jumps to another pane.

**Direction:** Separate 'Connections/Setup' (status + actions) from 'Preferences' (stored choices), or fold status into the agent/feature it describes.

#### [HIGH] S8 — Notifications: five panes, three-level inheritance, and the same controls twice

*Category:* settings-sprawl

- `App/UI/Settings/NotificationSettingsPages.swift:209` — if event.supportsReminder {                             Toggle(isOn: Binding(                                 get: { prefs.prefs(for: event).remind ?? true },
- `App/UI/Settings/NotificationSettingsPages.swift:294` — ForEach(remindableEvents) { event in                     Toggle(isOn: Binding(                         get: { settings.notifications.prefs(for: event).remind ?? true },
- `App/UI/Settings/NotificationSettingsPages.swift:129` — Button("Send a Test Notification") {                     Task { await NotificationAuthorization.shared.sendTestNotification() }
- `App/UI/Settings/NotificationPermissionRow.swift:548` — Button("Send a Test Notification") {                 run { await authorization.sendTestNotification() }
- `App/Core/NotificationPrefs.swift:211` — /// Priority for an event in a project: event override → project override →     /// global. The event wins because it is the most specific thing the user set.

**Why it matters:** The per-event Remind toggle is on Events and again on Reminders; 'Send a Test Notification' is on the General page twice (inside the permission row and as its own section). Priority/sound can be set globally, per event and per project with 'Default (X)' inherit entries, which the user must mentally resolve.

**Direction:** Collapse to one Notifications page with an events table; put project overrides on the project.

#### [HIGH] S9 — Working Mode and Run Parameters expose raw CLI vocabulary per provider; working mode is set in five places

*Category:* agent-leak

- `App/Core/Models.swift:336` — case .dangerouslySkipPermissions: "Dangerously Skip Permissions"         case .askForApproval: "Ask for Approval"         case .approveForMe: "Approve for Me"         case .fullAccess: "Full Access"         case .dontAsk
- `App/Core/Models.swift:304` — case .gemini:             [.providerDefault]
- `App/UI/Settings/AgentSettingsPages.swift:399` — prompt: provider == .claude ? String(localized: "e.g. --model opus") : String(localized: "e.g. --full-auto"),
- `App/Tasks/AgentLaunchOptions.swift:6` — struct AgentLaunchSelection: Equatable, Codable {     var model: String?     var effort: String?     var workingMode: AgentWorkingMode?
- `App/UI/TaskDispatchSheet.swift:468` — if let mode = AgentWorkingMode(rawValue: preset.permissionMode),
- `App/UI/TaskOrchestratorSheet.swift:214` — get: { launch.workingMode }, set: { launch.workingMode = $0 }
- `App/Terminal/TerminalHost.swift:158` — let providerArguments = settings.extraArguments[AgentProvider.codex.rawValue]?             .trimmingCharacters(in: .whitespacesAndNewlines)         return providerArguments?.isEmpty != false && (record.extraArguments?.is

**Why it matters:** The pane titled 'Working Mode' offers 'Dangerously Skip Permissions' for Claude and 'Full Access' for Codex — each CLI's flag names, not one Uncoil vocabulary — and a one-option picker for Gemini. Run Parameters suggests `--model opus` although model is a per-launch picker elsewhere; and typing anything into Codex's field silently switches off the Codex app-server integration. Mode is editable in Settings, onboarding, task dispatch, orchestrator and (as free text) in presets.

**Direction:** One Uncoil-level 'autonomy' scale mapped per CLI, chosen at launch with a remembered default; hide raw flags behind an 'Advanced' escape hatch.

#### [HIGH] S10 — Internal names shown to users: Session Presets ('Identity', 'Grants', raw keys), 'Permission mode' free text, 'Control plane', 'Helper binary', 'Drivers', 'Live events'; Turkish labels in the capability catalog; 'Retention' as the off option

*Category:* terminology

- `App/UI/Settings/AgentSettingsPages.swift:639` — title: String(localized: "Identity"),                         detail: String(localized: "Cannot be changed; child agents ask for the preset by this name."),
- `App/UI/Settings/AgentSettingsPages.swift:695` — SettingsLabel(title: capability.label, detail: capability.key)
- `App/UI/Settings/AgentSettingsPages.swift:658` — title: String(localized: "Permission mode"),                         prompt: "standard",
- `App/Core/SessionPreset.swift:20` — /// Permission mode label; reserved for future provider-specific mapping.     var permissionMode: String
- `App/ControlPlane/CapabilityCatalog.swift:57` — label: "Projeleri oku",
- `App/ControlPlane/CapabilityCatalog.swift:22` — case .computer: "Bilgisayar"
- `App/ControlPlane/CapabilityCatalog.swift:125` — label: "Arka planda kontrol",
- `App/UI/Settings/McpSettingsPage.swift:503` — title: String(localized: "Helper binary"),
- `App/Core/SessionTranscriptStore.swift:13` — case .disabled: String(localized: "Retention")
- `App/Extensions/AgentIntegration.swift:29` — case .controlPlane: "Control plane"         case .hooks: "Live events"

**Why it matters:** A preset editor asks for an 'Identity' slug and a 'Permission mode' string whose only consumer parses it as an `AgentWorkingMode` raw value (TaskDispatchSheet.swift:468) — 'standard' is not one. The Permissions › Advanced list and the preset Grants list mix English and Turkish labels ('Projeleri oku', 'Artifact yaz', 'Bilgisayar'). The Retention picker's off state is called 'Retention'. These are the words the user has to build a mental model from.

**Direction:** Audit every user string against a user-vocabulary list; make permissionMode a typed picker or remove it; fix catalog labels.

#### [MEDIUM] S11 — Search is a hand-written bilingual keyword string per pane, pinned by tests and copied in the Extensions window — a symptom of no settings registry

*Category:* discoverability

- `App/UI/Settings/SettingsView.swift:185` — /// Search terms (Turkish + English) matched by the filter box. They name         /// the *settings inside* the page, not the page — searching "sessiz"         /// should find the sound picker even though no page is call
- `App/UI/Settings/SettingsView.swift:193` — case .installedAgents: "agent ajan bağla connect hook kanca algıla detect tara scan claude codex gemini cursor amp opencode grok hermes seviye level konum location bul locate yol path import içe aktar kurulum install bul
- `App/UI/Settings/SettingsView.swift:237` — return Pane.allCases.filter { $0.searchText.contains(query) }
- `App/UI/ExtensionsView.swift:58` — case .overview: ["general", "genel", "status", "durum", "summary", "özet", "health"]
- `Tests/MenuBarPrefsTests.swift:182` — XCTAssertTrue(search("hatırlatma").contains(.reminders))

**Why it matters:** Results are panes, not settings, so 'sessiz' lands you on Quiet Hours and you still have to find the control. Every new control needs someone to add words in two languages by hand; the CapabilityCatalog's Turkish labels and the 'Eksik:' string show the same bilingual drift in the UI itself. There is no per-setting metadata (title, scope, default, storage) anywhere to search over.

**Direction:** Introduce a settings registry (id, title, scope, storage, pane) and derive search, deep links and tests from it.

#### [MEDIUM] S12 — Dead or hidden settings machinery: Backup, Uninstall and Crash-reporting services with no UI; MenuBar clickAction persisted but unexposed; Metal only via defaults write; presets.json referenced but never written

*Category:* settings-sprawl

- `App/Core/BackupService.swift:275` — struct BackupService {
- `App/Core/UninstallService.swift:37` — struct UninstallService {
- `App/Core/UninstallService.swift:148` — struct CrashReportingPolicy: Equatable, Codable {
- `App/UI/Settings/SettingsView.swift:214` — case .about: "hakkında about sürüm version veri klasörü data folder debug bundle kaldır uninstall"
- `App/Core/MenuBarPrefs.swift:98` — var clickAction: ClickAction = .openMenu
- `App/Terminal/TerminalKeyHandling.swift:125` — /// `defaults write com.gokhantopbas.uncoil TerminalMetalEnabled -bool YES`.
- `App/Core/UninstallService.swift:53` — "presets.json", "permissions.json", "audit.jsonl", "task-patches.jsonl"] {
- `App/Core/SettingsStore.swift:852` — presets: configuredPresets,

**Why it matters:** `rg 'UninstallService|BackupService|CrashReportingPolicy' App` excluding their own files returns nothing: three whole subsystems the user can never reach, while the About keyword string advertises 'uninstall'. A persisted menu-bar option has no control and no reader. Backup/Uninstall list a `presets.json` that does not exist. This is settings surface that has drifted from the product.

**Direction:** Decide per item: ship with UI, or delete; do not keep Codable fields the UI does not own.

#### [MEDIUM] S13 — Settings that could be inferred or defaulted are exposed as choices

*Category:* other

- `App/Core/LauncherPrefs.swift:211` — guard !prefs.order.isEmpty else {             let detected = AgentProvider.sessionKinds.filter {                 !$0.isAgent || installed.contains($0)             }
- `App/Core/Models.swift:253` — var defaultShiftEnterNewline: Bool {         switch self {         case .claude, .codex: true
- `App/UI/Settings/GeneralSettingsPage.swift:110` — // A short list rather than a slider: the number only has                         // to be roughly right, and a slider invites fiddling                         // with a threshold whose exact value nobody can reason     
- `App/UI/Settings/GeneralSettingsPage.swift:32` — Text(editor.isInstalled                              ? editor.displayName                              : "\(editor.displayName) (not installed)")
- `App/Core/ImagePasteMode.swift:8` — Claude Code's does not always, and there /// is nothing Uncoil can do about that from the outside except offer the route /// that never fails

**Why it matters:** Quick Launch already resolves to installed agents when unset; Shift+Enter has a per-CLI default; the usage threshold is admitted to be un-reasonable-about; the editor picker lists uninstalled apps; the image-paste mode exists for one agent's bug. Each is a control the user must understand to leave alone. `save()` already elides defaults (SettingsStore.swift:854-875), so the store treats them as overrides — the UI does not.

**Direction:** Hide inferred defaults behind 'Advanced' or remove; show only what the machine cannot decide.

#### [MEDIUM] S14 — One window, nine storage locations: settings.json, theme.json, UserDefaults, Sparkle prefs, Keychain, agent config files, sessions.json, permissions.json, blueprint files

*Category:* coupling

- `App/Theme/ThemeStore.swift:193` — ProjectStore.defaultDirectory().appendingPathComponent("theme.json")
- `App/UI/Settings/DriverSetupSections.swift:17` — @AppStorage(AgentBrowserAdapter.executablePreferenceKey)     private var executablePath = ""
- `App/Core/UpdaterService.swift:313` — /// Mirrors Sparkle's own preference rather than storing a second copy of it;
- `App/UI/Settings/PrivacySettingsPages.swift:258` — projectStore.updateSession(sessionID) { record in             var grants = PolicyEngine.grants(for: record)
- `App/Hooks/HookInstaller.swift:3` — /// Installs Uncoil's event hooks into `~/.claude/settings.json`.
- `App/UI/Settings/BlueprintsSettingsPage.swift:44` — Blueprints are markdown files in ~/.uncoil/blueprints.
- `App/Core/SettingsStore.swift:835` — static func applyInterfaceLanguage(_ interface: InterfaceLanguage) {         if let identifier = interface.localeIdentifier {             UserDefaults.standard.set([identifier], forKey: "AppleLanguages")

**Why it matters:** The Settings window edits values with at least five different persistence models and three different owners (Uncoil, macOS, the agent CLIs). BackupService covers only settings.json/projects/sessions/presets/permissions/extensions, so a 'backup' would miss the theme, the browser choice, blueprints and hooks. There is no notion of scope (global/project/session/agent/machine) in the store: `Persisted` is a flat struct of 24 optionals.

**Direction:** Give every setting an explicit scope and owner in one registry; keep machine caches (resolvedBinaries) out of the user preferences file.

#### [MEDIUM] S15 — Onboarding re-implements eight Settings panes and is the sole editor of one setting

*Category:* onboarding

- `App/Core/OnboardingState.swift:9` — enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {     case welcome     case clis     case accounts     case workingModes     case hooks     case notifications     case capabilities     case tools     ca
- `App/UI/Onboarding/OnboardingToolSteps.swift:44` — get: { settings.workingMode(for: provider) },                             set: { settings.setWorkingMode($0, for: provider) }
- `App/UI/Onboarding/OnboardingToolSteps.swift:110` — title: String(localized: "Optional tools"),             subtitle: String(localized: "Three things Uncoil can use but does not ship.
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:365` — settings.setSessionCapabilityDefaults(granted)
- `App/UI/Settings/AboutSettingsPage.swift:468` — detail: String(localized: "Runs the first-run flow again: CLIs, accounts, hooks, agent capabilities, tasks and extensions.")

**Why it matters:** Thirteen steps configure default agent, accounts, working modes, hooks, two notification toggles, capability defaults, drivers plus Bumblebee (which has no Settings pane), editor and palette hotkey — with their own card UI rather than the Settings pages. The capability-defaults step is the only writer of `sessionCapabilityDefaults`, so a first-run choice becomes permanent unless the whole flow is re-run from About.

**Direction:** Onboarding should open the real settings surfaces (or a subset of them), and every value it writes must have a Settings home.

#### [MEDIUM] S16 — Provider-specific hard-coding surfaces as uneven UI: only Claude/Codex colours, only Claude/Codex sign-in detection, Claude-only placeholder branch, Gemini with no login and one working mode

*Category:* agent-leak

- `App/UI/Settings/AppearanceSettingsPage.swift:64` — Section("Providers") {                 colorRow(String(localized: "Claude colour"), \.claude)                 colorRow(String(localized: "Codex colour"), \.codex)
- `App/Theme/ThemeStore.swift:59` — var gemini: UInt32? = nil
- `App/Core/SettingsStore.swift:443` — case .gemini, .opencode, .grok, .cursor, .hermes, .terminal:             return nil
- `App/Core/Models.swift:96` — case .gemini: nil
- `App/UI/Settings/AgentSettingsPages.swift:95` — Text(email ?? "not signed in — starting a session opens the provider's login flow")

**Why it matters:** An Accounts row for OpenCode/Grok/Cursor/Hermes can never say 'signed in' because `loggedInEmail` only reads Claude and Codex files, so five of seven providers permanently display 'not signed in'. The theme page lets you recolour two agents of eight. These asymmetries are visible in the matrices S1 creates and will widen with each provider.

**Direction:** Per-agent capability descriptors (canDetectLogin, hasLogin, hasModes, hasColour) drive which rows/controls appear, instead of ForEach over all providers.

#### [MEDIUM] S17 — Settings pages perform work in other windows and on the machine, not just store preferences

*Category:* coupling

- `App/UI/Settings/BlueprintsSettingsPage.swift:153` — MainRoute.shared.request(.session(launched.id))         SessionPromptDelivery.deliver(
- `App/UI/Settings/AgentSettingsPages.swift:307` — private func restartRunningSessions() {         for id in restartTargets {             TerminalRegistry.shared.closeTerminal(for: id)
- `App/UI/Settings/AboutSettingsPage.swift:471` — Button("Run again") {                         settings.resetOnboarding()                         OnboardingPresenter.shared.present()
- `App/UI/Settings/DriverSetupSections.swift:97` — return ProcessRunner.run(                     executable: invocation.executable,                     arguments: invocation.arguments,

**Why it matters:** Blueprints launches an agent session in the main window; CLI Tools kills and restarts terminals; Drivers runs a 900-second Playwright install; About tears down onboarding state and opens another window. These are actions with consequences that a user does not expect from a Settings window, and they make Settings depend on ProjectStore, SessionStore, TerminalRegistry and MainRoute.

**Direction:** Keep actions with the feature (agent detail, session, Extensions) and let Settings hold choices.

#### [MEDIUM] S18 — Extensions › Agents duplicates Installed Agents and adds a third meaning of 'profile'

*Category:* duplicate-concept

- `App/UI/AgentHookupCard.swift:12` — /// Settings › Agents is where agents are managed; this card mirrors it rather /// than competing with it
- `App/UI/ExtensionsView.swift:1014` — /// The preset Uncoil would launch this agent with. "Profile" is that preset     /// plus the permission mode it carries.     private func activeProfile(_ agent: ExtensionAgentID) -> String {
- `App/UI/Settings/AgentSettingsPages.swift:29` — detail: String(localized: "A separate profile is created, with its own config folder."),
- `App/UI/Settings/PrivacySettingsPages.swift:182` — Text(record.capabilities == nil                              ? "Using the default profile"                              : "Customised for this session")

**Why it matters:** The same rows, buttons and service appear in two windows. 'Profile' means an account config directory on Accounts, a preset on Extensions › Agents, and the default grant set on Permissions.

**Direction:** One agent surface; retire 'profile' or give it one meaning.

#### [LOW] S19 — Feature-visibility decisions are scattered across views with no capability registry

*Category:* visibility-logic

- `App/UI/Settings/SettingsView.swift:344` — if let service = sessionStore.permissionService {
- `App/UI/Settings/AboutSettingsPage.swift:431` — if updater.isAvailable {
- `App/UI/Settings/McpSettingsPage.swift:526` — detail: provider.wiresControlPlane
- `App/UI/Settings/AgentSettingsPages.swift:102` — if profile.provider.loginCommand != nil, email == nil {
- `App/UI/Settings/AgentsSettingsPage.swift:41` — disconnect: state.active == .hooks
- `App/UI/Settings/DriverSetupSections.swift:51` — if status?.installed == true {                 Button("Start and Verify") { startAndVerify() }

**Why it matters:** Each pane asks its own question of a different object (SessionStore, UpdaterService, AgentProvider, AgentHookupService, adapter probes). Nothing central answers 'is feature X available on this machine for this agent', so the same fact (e.g. 'Gemini cannot be wired') is re-derived in MCP, Installed Agents and Working Mode with different wording.

**Direction:** A per-agent/per-feature capability descriptor consumed by all panes.

#### [LOW] S20 — Legacy structure leaks through identifiers and resolvers

*Category:* navigation

- `App/UI/Settings/DriverSetupSections.swift:39` — .settingsID("permissions.browser.choice")
- `App/UI/Settings/IntegrationsSettingsPages.swift:457` — .settingsID("permissions.drivers")
- `App/UI/Settings/GeneralSettingsPage.swift:146` — .settingsID("agentBehavior.quit")
- `App/UI/Settings/AgentSettingsPages.swift:498` — .settingsID("agentBehavior.shiftEnter.\(provider.rawValue)")
- `App/UI/Settings/SettingsView.swift:221` — static func resolve(_ raw: String) -> Pane? {         if let exact = Pane(rawValue: raw) { return exact }         switch raw {         case "defaults": return .general         case "notificationSounds": return .notificat

**Why it matters:** Drivers still identify as 'permissions.*', quit behaviour and Shift+Enter as 'agentBehavior.*'; seven legacy raw values are kept alive. Each reorganisation so far has left its residue, which is what the next one will inherit.

**Direction:** Derive identifiers and deep links from the registry so they move with the setting.

#### [LOW] S21 — Empty and unavailable states either hide controls or leave dead matrices on screen

*Category:* empty-state

- `App/UI/Settings/PrivacySettingsPages.swift:147` — Text("There is no session to grant anything to yet.")
- `App/UI/Settings/SettingsView.swift:349` — title: String(localized: "Control plane not running"),                     detail: String(localized: "No permission request arrives while the MCP control plane is off.")
- `App/UI/Settings/AgentSettingsPages.swift:221` — ?? (path == nil ? "not installed" : "reading the version…"))
- `App/Core/SettingsStore.swift:783` — accounts.append(AccountProfile(provider: provider, name: "Default", directoryName: nil))

**Why it matters:** With one CLI installed, CLI Tools shows six 'not installed' rows, Accounts shows seven sections each with a forced 'Default' row, Working Mode and Run Parameters show seven controls for agents that cannot launch — while the one pane that needs a service simply disappears with its timeout setting.

**Direction:** Filter matrices to installed agents; keep global preferences visible even when a service is down.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Settings window shell | window | `App/UI/Settings/SettingsView.swift` | ⌘, menu (App/UncoilApp.swift:203-208); Sidebar gear RailButton with pending-CLI-update badge (App/UI/SidebarView.swift:147-160); Command palette 'Settings' and 'Settings: <pane>' items (App/Core/Palet |
| General | screen | `App/UI/Settings/GeneralSettingsPage.swift` | default pane on open (:24 `pane = .general`); legacy deep link 'defaults' (SettingsView.swift:224) |
| Keyboard and Input | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar General › Keyboard and Input; legacy links 'keyboard','shiftEnter','imagePaste','optionAsMeta' (SettingsView.swift:228) |
| Installed Agents | screen | `App/UI/Settings/AgentsSettingsPage.swift` | sidebar Agents › Installed Agents; mirrored by Extensions › Agents › AgentHookupCard (App/UI/AgentHookupCard.swift:12-15) |
| Accounts | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar Agents › Accounts |
| CLI Tools | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar Agents › CLI Tools; sidebar gear badge counts `pendingCLIUpdates` (SidebarView.swift:150-158) |
| Run Parameters | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar Agents › Run Parameters |
| Working Mode | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar Agents › Working Mode; onboarding step .workingModes writes the same values (App/UI/Onboarding/OnboardingToolSteps.swift:43-55) |
| Session Presets | screen | `App/UI/Settings/AgentSettingsPages.swift` | sidebar Agents › Session Presets; UI smoke test settings.pane.presets (UITests/SmokeTests.swift:125) |
| Blueprints | screen | `App/UI/Settings/BlueprintsSettingsPage.swift` | sidebar Agents › Blueprints; agents save drafts via uncoil_projects save_blueprint (:190-192) |
| Notifications › General | screen | `App/UI/Settings/NotificationSettingsPages.swift` | sidebar Notifications › General; legacy link 'notificationSounds' (SettingsView.swift:225) |
| Notifications › Events | screen | `App/UI/Settings/NotificationSettingsPages.swift` | sidebar Notifications › Events |
| Notifications › Reminders | screen | `App/UI/Settings/NotificationSettingsPages.swift` | sidebar Notifications › Reminders |
| Notifications › Quiet Hours | screen | `App/UI/Settings/NotificationSettingsPages.swift` | sidebar Notifications › Quiet Hours |
| Notifications › Per Project | screen | `App/UI/Settings/NotificationSettingsPages.swift` | sidebar Notifications › Per Project |
| Theme and Colours | screen | `App/UI/Settings/AppearanceSettingsPage.swift` | sidebar Appearance › Theme and Colours |
| Menu Bar | screen | `App/UI/Settings/MenuBarSettingsPage.swift` | sidebar Appearance › Menu Bar |
| Quick Launch | screen | `App/UI/Settings/LauncherSettingsPage.swift` | sidebar Appearance › Quick Launch |
| Permissions | screen | `App/UI/Settings/PrivacySettingsPages.swift` | sidebar Uncoil › Permissions; Uncoil MCP 'Capabilities…' (McpSettingsPage.swift:552); onboarding capabilities copy (OnboardingPlatformSteps.swift:353) |
| Uncoil MCP | status | `App/UI/Settings/McpSettingsPage.swift` | sidebar Uncoil › Uncoil MCP |
| Agent Status Hooks | screen | `App/UI/Settings/PrivacySettingsPages.swift` | sidebar Uncoil › Agent Status Hooks; onboarding copy (OnboardingPlatformSteps.swift:75) |
| Drivers | screen | `App/UI/Settings/DriverSetupSections.swift` | sidebar Uncoil › Drivers; onboarding .tools step re-implements the same probes with its own cards (OnboardingToolSteps.swift:91-128) |
| GitHub | screen | `App/UI/Settings/IntegrationsSettingsPages.swift` | sidebar Uncoil › GitHub |
| Data and Transcripts | screen | `App/UI/Settings/PrivacySettingsPages.swift` | sidebar Uncoil › Data and Transcripts; legacy link 'transcripts' (SettingsView.swift:226); UI smoke test settings.pane.privacyData |
| About | screen | `App/UI/Settings/AboutSettingsPage.swift` | sidebar About |
| Settings unavailable placeholder | empty-state | `App/UI/Settings/SettingsView.swift` | Permissions pane while `sessionStore.permissionService == nil` |
| Extensions › Agents card (duplicate of Installed Agents) | panel | `App/UI/AgentHookupCard.swift` | Extensions window › Agents section |

### Concepts

- `U!` **Agent / Provider (AgentProvider)** — The CLI Uncoil launches in a session: claude, codex, gemini, opencode, grok, hermes, cursor, plus terminal. `AgentProvider.agents` (App/Core/Models.swift:40) is the row source for Accounts, CLI Tools, Run Parameters, Working Mode, Shift+Enter, Uncoil MCP › Per Agent and the Default agent picker. *Overlaps:* ExtensionAgentID, Account
- `U` **Agent (ExtensionAgentID)** — A second agent identity used by the Extensions subsystem: claudeCode, codex, geminiCLI, cursor, amp, opencode, grok, hermes, with display names 'Claude Code', 'Gemini CLI', 'Grok CLI', 'Amp' (App/Extensions/ExtensionModels.swift:8-31). Installed Agents lists by this enum (8 rows) while every other Agents pane lists by AgentProvider (7 rows named 'Claude', 'Gemini', 'Grok'). Amp has no AgentProvider (`provider: nil`, :43). *Overlaps:* AgentProvider
- `U!` **Account (AccountProfile) / 'profile'** — A named, isolated config directory per provider (CLAUDE_CONFIG_DIR / CODEX_HOME), plus a non-deletable 'Default' profile per provider created automatically (SettingsStore.swift:780-786). Called 'account' in the pane title and 'profile' in its copy ('A separate profile is created', AgentSettingsPages.swift:29). 'Profile' also means the preset in Extensions (ExtensionsView.swift:1014-1021) and the default grant set in Permissions ('Using the default profile', PrivacySettingsPages.swift:183). *Overlaps:* Session Preset, Capability default set
- `U` **Working Mode (AgentWorkingMode)** — Uncoil's umbrella for each CLI's approval/sandbox flags; 12 cases, per-provider subsets, mapped to raw flags at launch (Models.swift:273-476). Stored per provider in `providerBehaviors[provider].workingMode`. Also chosen per launch (TaskDispatchSheet.swift:279, TaskOrchestratorSheet.swift:214, `record.launchSelection` TerminalHost.swift:537) and carried by `SessionPreset.permissionMode` parsed as a raw value (TaskDispatchSheet.swift:468). *Overlaps:* Run Parameters, Session Preset permissionMode, Capability grants
- `U` **Run Parameters (extraArguments)** — Free-text CLI flags appended to the launch command, one string per provider (SettingsStore.swift:90, TerminalHost.swift:434). The Claude placeholder suggests '--model opus' although a per-launch Model picker exists in `AgentLaunchSelection` (App/Tasks/AgentLaunchOptions.swift:6-9). A non-empty Codex value silently disables the Codex app-server path (TerminalHost.swift:154-161). *Overlaps:* Working Mode, AgentLaunchSelection model/effort, Session Preset extraArguments
- `U!` **Session Preset** — Template for child sessions spawned via MCP `create_child` (App/Core/SessionPreset.swift:3-8): id slug, name, provider, extra arguments, opening prompt, `grantedCapabilities`, `permissionMode` ('reserved for future provider-specific mapping', :20). Built-ins: claude-worker, codex-reviewer, task-orchestrator. Exposed under the internal name with 'Identity' and 'Grants' sections and raw capability keys as row details. *Overlaps:* Blueprint, Capability grant, Working Mode, Account
- `U!` **Capability / Grant** — Control-plane permission keys such as 'projects.read', 'computer.foreground_control' (App/ControlPlane/PolicyEngine.swift:29-59; catalog App/ControlPlane/CapabilityCatalog.swift:55-147 with several Turkish labels). Three scopes exist: default set for new sessions (`sessionCapabilityDefaults`, onboarding only), per-session `SessionRecord.capabilities` (Permissions pane), per-preset `grantedCapabilities` (Preset editor). *Overlaps:* Permission request, Working Mode
- `U` **Permission request (PermissionRequest / scope once|persistent)** — A runtime ask from one session to use a grant on another, answered Once / Permanent / Deny, with a timeout (`permissionTimeoutMinutes`). Lives in `PermissionService` (permissions.json). Surfaced only on the Permissions pane and as a macOS notification whose default action opens the session, not Settings (App/Core/PermissionNotifications.swift:193-212). *Overlaps:* Capability grant
- `U!` **Hooks / 'Status tracking' / 'Live events' / 'Connect'** — Claude Code (and Hermes) lifecycle hooks Uncoil writes into the agent's own config so session state is reported. One mechanism named four ways: pane 'Agent Status Hooks', onboarding step 'Status tracking', Installed Agents level label 'Live events' and button 'Connect', Extensions card 'Connected agents'. *Overlaps:* Integration level, Uncoil MCP
- `U!` **Integration level (AgentIntegrationLevel)** — Ordered ladder none/observed/controlPlane/hooks shown as 'Detected only' / 'Terminal only' / 'Control plane' / 'Live events' (AgentIntegration.swift:10-32). *Overlaps:* Hooks, Uncoil MCP wired/not wired
- `U!` **Control plane / Uncoil MCP / Helper binary** — The app-side MCP server and its bundled stdio helper. Pane 'Uncoil MCP' exposes 'Control plane serving', 'Helper binary bundled', per-agent 'wired'. Architecture vocabulary used as UI labels. *Overlaps:* Integration level
- `U!` **Driver (Agent Browser / Cua Driver)** — Optional external binaries behind `uncoil_browser` and `uncoil_computer`; adapter names surfaced as the pane title 'Drivers' and rows 'Agent Browser CLI', 'Cua Driver'. Browser choice stored in UserDefaults, not settings.json (DriverSetupSections.swift:17-18). *Overlaps:* Capability grant (browser.*, computer.*)
- `U` **Blueprint** — A saved markdown prompt handed to an agent when a project is created; stored as files in ~/.uncoil/blueprints, may be a 'draft' written by an agent. Filed under Agents although it is about starting projects. *Overlaps:* Session Preset opening prompt
- `U` **Quick Launch strip / launcher** — Ordered provider buttons on the project screen, resolved to installed agents when unconfigured (App/Core/LauncherPrefs.swift:208-224). Filed under Appearance. *Overlaps:* Installed agents (installedProviders)
- `U` **Attention / Sidebar pulse (AttentionEmphasis)** — Animation strength for rows needing input (off/subtle/full). A SettingsStore value mirrored into `AttentionMotion.shared` (App/Core/AttentionEmphasis.swift:266-286) but placed on the Theme page. *Overlaps:* Notifications (same 'needs you' events)
- `U` **Notification priority / event / reminder / quiet hours / per-project override** — Five-pane model with three-level inheritance event → project → global (NotificationPrefs.swift:211-223); priority maps to UNNotificationInterruptionLevel; 'Remind' per event is editable on two panes. *Overlaps:* Menu-bar counters, Attention
- `U` **Menu-bar monitor** — Status item with icon style, counters, drop-down sections (MenuBarPrefs.swift). `clickAction` is defined and persisted (:35-47, :98) but has no control and no consumer. *Overlaps:* Quick Launch, Notifications
- `U` **Transcript retention** — Whether/how long terminal output is written to disk (disabled/7/30/forever); the disabled case is titled 'Retention' (SessionTranscriptStore.swift:13). *Overlaps:* Debug bundle (excludes transcripts), Backup (opt-in transcripts, no UI)
- `U` **Onboarding / 'Setup guide'** — 13-step first-run flow (App/Core/OnboardingState.swift:9-22) that writes default agent, accounts, working modes, hooks, two notification toggles, capability defaults, palette hotkey and editor — the same values as 8 Settings panes — and is the only editor for `sessionCapabilityDefaults`. *Overlaps:* General, Accounts, Working Mode, Hooks, Notifications, Permissions, Drivers panes
- `i` **Backup / Uninstall / Crash reporting (unsurfaced)** — `BackupService`/`UncoilBackup` (11 content kinds), `UninstallService`/`UninstallPlan`, `CrashReportingPolicy` exist in App/Core with no UI caller anywhere in App/ (rg over App excluding their own files returns nothing). *Overlaps:* About › Debug bundle, Data and Transcripts
- `i` **Hidden defaults (TerminalMetalEnabled, codexAppServerEnabled, presets.json)** — `TerminalMetalEnabled` is read from UserDefaults with a comment telling users to `defaults write` it (App/Terminal/TerminalKeyHandling.swift:125-129); `LaunchConfig.codexAppServerEnabled` gates a launch path (TerminalHost.swift:156); Uninstall/Backup/SchemaRegistry reference a `presets.json` that the store never writes (presets live inside settings.json, SettingsStore.swift:852). *Overlaps:* Session Presets

### Flows

- **Get one new agent CLI fully set up from Settings** (9 steps) — friction: Nine visits across three categories for one agent; every pane is a matrix keyed by a different agent list (8 ExtensionAgentIDs vs 7 AgentProviders), and the hooks step is duplicated.
- **Answer an agent's permission request** (4 steps) — friction: A live, per-session decision queue lives in global Settings; the notification's 'Open' does not lead to the queue.
- **Change what new sessions are allowed to do** (4 steps) — friction: The promised setting does not exist on the promised pane; the default set is editable only via a re-run of first-run setup.
- **Install Claude Code status hooks** (4 steps) — friction: Four surfaces, two services, two different status readers (`HookInstaller.status()` vs `HookInstaller.inspect()`), and one of them leaks a Turkish label ('Eksik:').
- **Tune notifications** (5 steps) — friction: Five panes for one feature; three-level inheritance the user has to reason about; Remind and Test Notification appear twice; project overrides live in Settings, not in the project.
- **Write a blueprint with an agent** (4 steps) — friction: A Settings pane launches agent work in another window; the concept is about starting projects but is filed under Agents.
- **Find a setting by search** (4 steps) — friction: Search quality depends on someone remembering to add words; there is no registry of settings to search.
- **Switch interface language** (3 steps) — friction: Minor; but a second 'Agent language' picker next to it introduces a concept (prompt language) most users will not expect in General.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| Default agent | global | settings.json defaultProvider (SettingsStore.swift:83) | General (GeneralSettingsPage.swift:12-25); Onboarding intro (OnboardingIntroSteps.swift:150) | yes |
| Editor | global | settings.json preferredEditor | General (:27-43); Onboarding project step (OnboardingProjectSteps.swift:104) | yes |
| Interface language | global | settings.json language.interface + UserDefaults AppleLanguages | General (:47-60) | yes |
| Agent language | global | settings.json language.agent | General (:62-77) | yes |
| Warn before an account runs out | global | settings.json usageWarningsEnabled | General › Provider Limits (:92-103) |  |
| Warn at (%) | global | settings.json usageWarningThreshold | General (:106-126), hidden unless warnings enabled | yes |
| Sessions on quit | global | settings.json sessionQuitBehavior → ApplicationLifecycle | General (:135-148); accessibility id still 'agentBehavior.quit' |  |
| Command palette shortcut | global | settings.json commandPaletteHotkey | General (:152-167); Onboarding palette step (OnboardingExtensionsSteps.swift:228) |  |
| Use Option as Meta | global | settings.json optionAsMetaKey → live terminals | Keyboard and Input (AgentSettingsPages.swift:475-487) |  |
| Shift+Enter for a newline | per-provider (7) | settings.json providerBehaviors[provider].shiftEnterNewline | Keyboard and Input (:490-506); accessibility id 'agentBehavior.shiftEnter.*' | yes |
| Pasting an image | global | settings.json imagePasteMode | Keyboard and Input (:508-529) | yes |
| Agent binary location | per-agent (ExtensionAgentID, keyed by command name) | settings.json agentBinaryLocations → BinarySearchPath | Installed Agents Locate…/Change…/Clear (AgentsSettingsPage.swift:188-193); Extensions › Agents card |  |
| Agent hooks (Claude / Hermes) | per-agent (integration) | ~/.claude/settings.json, ~/.hermes/config.yaml (external), backups under <data>/config-backups | Installed Agents Connect/Disconnect; Agent Status Hooks Install/Remove (Claude only); Extensions › Agents; Onboarding hooks step |  |
| Accounts per provider | per-provider / per-account | settings.json accounts[], defaultAccountByProvider; directories <data>/profiles/<provider>/<slug> | Accounts (AgentSettingsPages.swift:20-59, 100-117); Onboarding accounts step (OnboardingIntroSteps.swift:358-373) |  |
| CLI update / check | per-provider | not stored; runs brew/npm/self-updater (SettingsStore.swift:569-635) | CLI Tools |  |
| Run Parameters | per-provider (7) | settings.json extraArguments[provider] | Run Parameters (:395-409) |  |
| Working Mode | per-provider default; per-session override; per-preset | settings.json providerBehaviors[provider].workingMode; SessionRecord.launchSelection; SessionPreset.permissionMode | Working Mode (:433-454); Onboarding (OnboardingToolSteps.swift:43-55); TaskDispatchSheet.swift:279; TaskOrchestratorSheet.swift:214; Preset editor free text (:657-662) |  |
| Session presets | global list | settings.json presets (nil ⇒ built-ins) | Session Presets pane + editor sheet |  |
| Blueprints | global list | ~/.uncoil/blueprints/*.md via BlueprintStore | Blueprints pane + editor sheet; agents via MCP save_blueprint |  |
| macOS notification permission | account (system) | macOS | Notifications › General row (NotificationPermissionRow.swift) |  |
| Notifications master, priority, sound, delivery ×3 | global | settings.json notifications.{enabled,priority,sound,onlyWhenBackgrounded,suppressForVisibleSession,groupByProject} | Notifications › General (:68-125); Onboarding writes onlyWhenBackgrounded/suppressForVisibleSession (OnboardingPlatformSteps.swift:173,184) |  |
| Per-event enabled / priority / sound / remind | global per event (7) | settings.json notifications.events[event] | Events (:166-228); Remind also on Reminders (:294-309) |  |
| Reminders on / interval / max | global | settings.json notifications.reminders | Reminders (:254-291) |  |
| Quiet hours on / start / end / allow high | global | settings.json notifications.quietHours | Quiet Hours (:357-380) | yes |
| Per-project notification override | project | settings.json notifications.perProject[uuid] | Notifications › Per Project (:436-480) |  |
| Appearance (system/light/dark) | global | theme.json via ThemeStore (ThemeStore.swift:190-193) | Theme and Colours (:12-23) | yes |
| Sidebar pulse | global | settings.json attentionEmphasis → AttentionMotion.shared | Theme and Colours › Attention (:35-53) | yes |
| Interface / provider / terminal colours (9 pickers) | global | theme.json palette fields | Theme and Colours (:57-71) |  |
| Menu-bar monitor enabled / icon style / monochrome / hide idle / 4 counters / 3 menu sections | global | settings.json menuBar (migrated from UserDefaults menuBarMonitorEnabled, SettingsStore.swift:813-820) | Menu Bar (:272-368) |  |
| Quick Launch order | global | settings.json launcher.order (nil ⇒ installed providers) | Quick Launch (:112-135) | yes |
| Permission timeout | global | settings.json permissionTimeoutMinutes → PermissionService.pendingTTL | Permissions (:126-143); unreachable while control plane is off |  |
| Per-session capability grants | session | sessions.json SessionRecord.capabilities | Permissions › Session Access + Advanced (:150-224) |  |
| Default capability set for new sessions | global | settings.json sessionCapabilityDefaults → ProjectStore.defaultSessionCapabilities | Onboarding capabilities step only (OnboardingPlatformSteps.swift:365) |  |
| Permission requests (once / permanent / deny / revoke) | session pair | permissions.json via PermissionService | Permissions › Awaiting Approval / Timed Out / Advanced; macOS notification actions |  |
| Agent Browser executable | global | UserDefaults 'agentBrowserExecutablePath' (@AppStorage, DriverSetupSections.swift:17) | Drivers › Browser picker | yes |
| Driver install / verify / permissions | integration | external binaries and macOS TCC | Drivers; Onboarding 'Optional tools' (which also covers Bumblebee, absent from Settings) |  |
| GitHub token | account | Keychain 'github-token' | GitHub pane |  |
| Transcript retention | global | settings.json transcriptRetentionPolicy | Data and Transcripts (:292-302) |  |
| Check for updates automatically | global | Sparkle's own UserDefaults key via SPUUpdater (UpdaterService.swift:316-322) | About (:439-444) |  |
| Onboarding version / completed steps | global | settings.json onboardingVersion, onboardingCompletedSteps | About › Run again (resets); onboarding itself |  |
| Resolved binaries cache / cliVersions | global (machine) | settings.json resolvedBinaries (cache) + in-memory cliVersions | not user-edited; refreshed by CLI Tools / Installed Agents scans | yes |
| sidebarVisible / sidebarWidth / TerminalMetalEnabled | window / global | UserDefaults (UncoilApp.swift:22, MainWindow.swift:35-36, TerminalKeyHandling.swift:129) | not in Settings (Metal only via `defaults write`) | yes |

### Visibility gates

- `App/UI/Settings/SettingsView.swift:343-352` — sessionStore.permissionService != nil → Whole Permissions pane, including the Permission Timeout picker; otherwise 'Control plane not running' placeholder
- `App/UI/Settings/GeneralSettingsPage.swift:105` — settings.usageWarningsEnabled → 'Warn at' segmented picker and its note
- `App/UI/Settings/GeneralSettingsPage.swift:79` — settings.language.needsRelaunch() → 'Restart Uncoil' row
- `App/UI/Settings/GeneralSettingsPage.swift:32-34` — editor.isInstalled → '(not installed)' suffix on Editor picker entries (entries stay selectable)
- `App/UI/Settings/AgentSettingsPages.swift:102` — profile.provider.loginCommand != nil && email == nil → 'Sign In' button on an account row (never for Gemini; email only ever read for Claude/Codex)
- `App/UI/Settings/AgentSettingsPages.swift:109` — profile.directoryName != nil → Delete button (the forced 'Default' profile cannot be removed)
- `App/UI/Settings/AgentSettingsPages.swift:265-288` — AgentUpdateAvailability case → Which control a CLI Tools row shows: Update / Check & Update / up to date / no updater / checking… / not installed
- `App/UI/Settings/AgentSettingsPages.swift:298-303` — AgentProcessRestart.offer(count:provider:) != nil → 'Restart running sessions' button
- `App/UI/Settings/AgentSettingsPages.swift:399` — provider == .claude → Run Parameters placeholder text ('--model opus' vs '--full-auto')
- `App/Core/Models.swift:289-327` — AgentWorkingMode.options(for: provider) → Working Mode picker contents per provider (Gemini: single option)
- `App/UI/Settings/AgentsSettingsPage.swift:41-43, 164-193` — state.isInstalled / state.pendingAction / state.active == .hooks / chosenLocation != nil → Installed Agents row controls: pending action button, Disconnect, Locate vs Change, Clear
- `App/UI/Settings/AgentsSettingsPage.swift:56` — !hookup.actionable.isEmpty → 'Connect all (N)' button
- `App/UI/Settings/BlueprintsSettingsPage.swift:23, :98` — store.blueprints.isEmpty / blueprint.needsReview → Blueprints empty note; 'draft' badge and review copy
- `App/UI/Settings/NotificationSettingsPages.swift:104,126,230,319,382,442` — !prefs.enabled (notifications master) → Every other notification section and all four sub-panes are disabled (still visible)
- `App/UI/Settings/NotificationSettingsPages.swift:183, :209` — prefs.isEnabled(event) / event.supportsReminder → Per-event Priority/Sound pickers; Remind toggle only for permission, input, loginRequired, mergeReady
- `App/UI/Settings/NotificationSettingsPages.swift:291,317,380` — reminders.enabled / quiet.enabled → Frequency, Which events, and Quiet Hours detail sections disabled
- `App/UI/Settings/NotificationSettingsPages.swift:429` — projectStore.projects.isEmpty → 'No projects yet.' on Per Project
- `App/UI/Settings/NotificationPermissionRow.swift:534-546, 565-578` — authorization.status (granted/provisional/denied/notRequested/unknown) → Request Permission vs Open System Settings button; explanation copy
- `App/UI/Settings/AppearanceSettingsPage.swift:28-30` — theme.appearance == .system → Footer wording under Built-in Themes
- `App/UI/Settings/MenuBarSettingsPage.swift:293,308,326,355,368` — prefs.enabled (menu bar) / prefs.iconStyle == .logo → Preview/Icon/Counters/Menu Contents disabled; 'Single colour' toggle only for logo style
- `App/UI/Settings/LauncherSettingsPage.swift:127, :147, :163` — !available.isEmpty / provider.isAgent && !settings.installedProviders.contains(provider) / LauncherPrefs.canRemove → 'Not in the strip' section; 'Not installed — hidden' warning; × button enabled
- `App/UI/Settings/PrivacySettingsPages.swift:96, :111` — !service.pending().isEmpty / !service.expired().isEmpty → Awaiting Approval and Timed Out sections
- `App/UI/Settings/PrivacySettingsPages.swift:146, :188, :198` — projectStore.sessions.isEmpty / record.capabilities != nil / showAdvanced → Session Access empty state; 'Back to Default'; Advanced disclosure content
- `App/UI/Settings/McpSettingsPage.swift:493-536` — status.isServing / helperPath == nil / provider.wiresControlPlane → Status colours and 'wired'/'not wired' rows (all read-only)
- `App/UI/Settings/PrivacySettingsPages.swift:356-360` — HookInstaller.status() == .installed → Install vs Remove on Agent Status Hooks
- `App/UI/Settings/DriverSetupSections.swift:51-63, 179-190` — status?.installed / status?.path != nil → Which driver button is primary: Start and Verify / Install Chromium / Open the Setup Guide; Set Permissions
- `App/UI/Settings/DriverSetupSections.swift:29` — AgentBrowserAdapter.installedBrowserChoices() → Browser picker entries
- `App/UI/Settings/IntegrationsSettingsPages.swift:274, 305-322` — KeychainStore.read('github-token') != nil / phase → GitHub signed-in row vs start/requesting/code rows
- `App/UI/Settings/AboutSettingsPage.swift:431` — updater.isAvailable (nil under UI tests) → Software Update section
- `App/Core/PaletteModel.swift:280` — !query.isEmpty → 'Settings: <pane>' items appear in the command palette only while searching
- `App/UI/Settings/SettingsView.swift:244-246, 263` — pane == .theme ? palette.isLight : palette → Detail view identity/rebuild on theme changes (Theme pane exempt so colour pickers survive drags)

### Open questions

- Is Amp intended to be a launchable provider? It is the only agent that exists in Installed Agents (ExtensionAgentID) and nowhere else in Settings.
- Is 'Uncoil MCP' meant as a settings page at all, or a diagnostic that belongs in a troubleshooting/status view? It stores nothing and its only control is a deep link.
- Should per-session capability grants and the approval queue move to the session (header/inspector/Attention Center)? No session-side editor exists today (`rg 'grant(id:'` in App/UI outside Settings returns nothing).
- `SessionPreset.permissionMode` is documented as 'reserved' but exposed as free text and parsed as an `AgentWorkingMode` raw value in TaskDispatchSheet.swift:468 — is it a working mode, or should it be removed from the editor?
- Are BackupService, UninstallService and CrashReportingPolicy planned features or abandoned code? They shape what 'Data' and 'About' could hold.
- The brief counted 23 panes; `Pane.allCases` has 24 (23 + About). Which count does the plan use?
- Per-project notification overrides are edited only in global Settings; is there a project-side settings surface planned (the recent commit ae89c13 added project-level MCP/skill selection via ProjectExtensionPicker in the main window, not in Settings)?
- Bumblebee appears in onboarding 'Optional tools' but has no Settings pane; is it meant to sit beside Drivers?
- Should `resolvedBinaries` (a machine cache) and `onboardingCompletedSteps` (flow state) live in the same file as user preferences, given BackupService exports that file?

---

## Extensions window (MCP servers, skills, catalogs, security, updates) and per-project extension scoping

From the user's chair, "Extensions" is a second application that lives inside Uncoil: its own window (Cmd+Shift+E), its own 196pt sidebar with 11 sections, its own "Search everywhere" box, its own menu-bar menu with 14 items, its own notice/toast system, its own keyboard shortcuts, and its own copy of the agent list. It exists to answer two everyday questions — "which MCP servers and skills do my agents have?" and "which of them should this project's sessions load?" — but it wraps those in a package-manager vocabulary (package, source, mirror, tracking mode, revision, adoption, binding, assignment, transaction, quarantine, drift, finding, Bumblebee) that a Homebrew maintainer would recognise and a normal user will not. A large share of that vocabulary is exposed for machinery that is not reachable end-to-end today: nothing in the app ever computes an update candidate, materialises a git mirror, writes the launcher manifest, or stores a secret value, so the Updates and Sources sections, the pin/branch sheets, the revision-rollback buttons, four detail rows on every MCP card, the Logs/Restart buttons and the "Secret required" hint are permanently inert in production while still occupying the navigation. The per-project scoping that users actually need is small and well-designed (a picker with an All-agents tab plus per-agent exceptions, "everything on until you turn it off", applied at launch through each CLI's own flags), but it has three writers of the same records (New Project sheet, Customise sheet, Extensions › Assignments) and two readers that interpret them in opposite directions, and it sits behind a store that is instantiated four times with last-save-wins semantics.

### Findings

#### [CRITICAL] EXT-01 — The Extensions window is a second application: 11 sections, its own sidebar, search, menu, shortcuts, toasts and roster

*Category:* concept-overload

- `App/UI/ExtensionsView.swift:5` — enum Section: String, CaseIterable, Identifiable { case overview, agents, skills, mcpServers, mcpCatalog, skillCatalog, assignments, sources, security, updates, activity
- `App/UI/ExtensionsCommands.swift:43` — CommandMenu("Extensions") { Button("Open Extensions") … ForEach(ExtensionsView.Section.allCases) … Button("Rescan") … Button("Run Health Check") … Button("Run Bumblebee Scan")
- `App/UI/ExtensionsView.swift:238` — TextField("Search everywhere", text: $query)
- `App/UI/ExtensionNotices.swift:10` — final class ExtensionNoticeCenter: ObservableObject
- `App/UncoilApp.swift:122` — Window("Uncoil Extensions", id: "extensions")

**Why it matters:** A user who wants 'add the GitHub MCP server to my agents' meets a navigator with Sources, Updates, Security, Assignments and Activity before they find MCP Catalog; the window carries roughly 35 distinct nouns (package, source, mirror, tracking, revision, adoption, binding, assignment, transaction, quarantine, drift, finding, Bumblebee, profile, adapter…). Every new extension capability will land as a twelfth section because the structure invites it.

**Direction:** Record which sections a normal user touches in a month (Skills, MCP Servers, the two catalogs, per-project scoping) versus power/security-team sections (Sources, Updates, Security, Assignments, Activity, Agents' config surgery) and treat the latter as an advanced/inspector mode rather than peers in the navigator.

#### [CRITICAL] EXT-02 — Updates, Sources, tracking modes and revision rollback are unreachable end-to-end: no production code computes an update candidate or materialises a mirror

*Category:* other

- `App/Extensions/ExtensionUpdateEngine.swift:77` — func checkForUpdate(   // grep across App/, ExtensionHelper/, RuntimeHelper/, Shared/: no caller
- `App/Extensions/ExtensionRegistry.swift:409` — func setUpdateCandidates(_ candidates: [UpdateCandidate])   // no caller outside Tests
- `App/Extensions/ExtensionMirror.swift:31` — func ensureMirror(repository: String, remote: String) throws -> URL   // no caller outside Tests
- `App/Extensions/ExtensionSourcePolicy.swift:139` — func linkedToRepository(…) -> ExtensionSource? { … return .managedGitHub(repository: repository, subpath: subpath, tracking: tracking) }
- `App/UI/ExtensionsView.swift:2572` — return "No mirror for \(repository); one appears when an extension is installed."
- `App/UI/ExtensionsView.swift:2427` — message = String(localized: "\(value) was added as a source. Adding an extension needs discovery.")
- `App/Extensions/Catalog/CatalogInstallService.swift:446` — package.source = .adopted(path: layout.revision(plan.revisionID).path)

**Why it matters:** Two of eleven sidebar sections (Sources, Updates), the Updates badge, the 'Update pending' tile, the 'update' marker, 'Update'/'Rollback'/'Rollback History' buttons, 'Pin Commit…', 'Switch Branch/Tag…', 'Fetch Now', the RepositoryLinkSheet and the 11-row UpdateReview card all exist for a `.managedGitHub` source that nothing installs; catalog installs are recorded as `.adopted` and their update detection is a separate name-and-hash comparison (CatalogStore.installedState). The user sees a full package-manager UI whose central promise never fires.

**Direction:** Either wire one real update path (catalog reinstall already exists) and delete the parallel git-mirror UI, or hide Sources/Updates until a managedGitHub package exists.

#### [CRITICAL] EXT-03 — Launcher, manifest, secret server and process health are not wired: four rows and two buttons on every MCP card are permanently inert and secrets have no entry UI

*Category:* other

- `App/Extensions/ExtensionLauncherService.swift:50` — func writeManifest(   // no caller outside Tests
- `App/Extensions/ExtensionRegistry.swift:624` — let records = launcher.runRecords()         guard !records.isEmpty else { return }
- `App/UI/ExtensionsView.swift:1695` — KeyValueRow(key: "Tool listesi", value: toolSummary)   // reportedTools is never written anywhere
- `App/UI/ExtensionsView.swift:1697` — KeyValueRow(key: "Prompt/resource listesi", value: promptResourceSummary)   // reportedCapabilities written only by record(probe:), which has no caller
- `App/UI/ExtensionsView.swift:1700` — key: "Last health check" … ?? "never run"
- `App/UI/ExtensionsView.swift:1840` — return "Secret required: \(server.environmentKeys.joined(separator: ", "))"
- `App/UI/CatalogDetailSheet.swift:364` — Text("Secret values are never written into config; they are provided per server after install and stored in the Keychain.")
- `App/Extensions/ExtensionSecretStore.swift:30` — func save(extensionID: String, key: String, value: String)   // grep App/: no caller
- `App/UI/MainWindow.swift:1025` — return .failure("bilinmeyen extension: \(extensionID)")

**Why it matters:** On every MCP server card the user reads 'Tool listesi: No handshake', 'the server did not report it', 'Last health check: never run', 'Last error: —', and finds Logs (never shown) and Restart ('There was no running process'). A server that needs a token is installed with a promise that the value can be supplied later, and there is nowhere to supply it. The MainWindow secret server starts on every launch to answer requests that can only fail (manifest absent) with Turkish error strings.

**Direction:** Remove the process-health/launcher rows and the secret promise from the user-facing card until the launcher path is actually used, or ship the launcher path with a secret entry field on the card.

#### [CRITICAL] EXT-04 — Four live ExtensionRegistry instances write the same registry.json with last-save-wins; the code comment admits data loss and leaves it

*Category:* coupling

- `App/Extensions/ExtensionRegistry.swift:69` — /// `save()` serialises the whole document from memory, so two live     /// instances mean the second one to save silently discards what the first     /// wrote — a project's extension selection would survive right up un
- `App/UI/ExtensionsView.swift:121` — let registry = ExtensionRegistry()
- `App/UI/ProjectCustomizeSheet.swift:28` — @ObservedObject private var registry = ExtensionRegistry.shared
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:12` — @StateObject private var registry = ExtensionRegistry()
- `App/UI/MainWindow.swift:150` — let scans = BumblebeeScanCoordinator(registry: ExtensionRegistry())

**Why it matters:** Toggle an agent binding in the Extensions window, then Save a project's 'MCP & Skills' tab: whichever instance saves second erases the other's change. The daily Bumblebee scan in MainWindow records into a fifth snapshot. This is the sort of bug that surfaces as 'my selection disappeared' and cannot be reasoned about by the user.

**Direction:** One store, injected; the Extensions window's skillLockHome and scan coordinator configuration can be set on the shared instance.

#### [HIGH] EXT-05 — Two agent enums with different rosters and display names leak into different screens

*Category:* duplicate-concept

- `App/Core/Models.swift:20` — enum AgentProvider … case claude, codex, gemini, opencode, grok, hermes, cursor, terminal … "Claude" … "Gemini" … "Grok"
- `App/Extensions/ExtensionModels.swift:8` — enum ExtensionAgentID … case claudeCode, codex, geminiCLI, cursor, amp, opencode, grok, hermes … "Claude Code" … "Gemini CLI" … "Grok CLI"
- `App/UI/Settings/McpSettingsPage.swift:63` — ForEach(AgentProvider.agents) { provider in
- `App/UI/Settings/AgentsSettingsPage.swift:30` — ForEach(hookup.states) { state in   // states = ExtensionAgentID.allCases
- `App/Extensions/ExtensionModels.swift:89` — static var supported: [ExtensionAgentID] { [.claudeCode, .codex, .geminiCLI, .cursor, .amp, .opencode, .grok, .hermes] }   // == allCases

**Why it matters:** Settings › Installed Agents lists 8 agents including Amp; Settings › Uncoil MCP › Per Agent lists 7 without Amp; the sidebar says 'Claude' while the project picker tab says 'Claude Code'. `ExtensionAgentID.supported` equals `allCases`, so the 'supported vs listed' distinction its comment describes no longer exists, and `AgentAdapterRegistry.unmanagedAgents` is always empty (the 'Agents not managed yet' card at ExtensionsView.swift:970 is dead).

**Direction:** One agent identity with a `launchable`/`managesConfig` capability flags; one display name per agent app-wide.

#### [HIGH] EXT-06 — ProjectBinding is written by three surfaces and read by two readers with opposite semantics (allow-list vs deny-list)

*Category:* duplicate-concept

- `App/Extensions/ProjectExtensionScope.swift:116` — /// This reads `ProjectBinding` records as a **deny**-list … `SkillAssignment.isActive` reads the very same records as an **allow**-list
- `App/Extensions/SkillAssignment.swift:47` — // Only other projects are named, so this one is out of scope. This is         // an *allow*-list
- `App/UI/ExtensionsView.swift:2214` — detail: String(localized: "With no record an extension is global; the project record, being the most specific, wins.")
- `App/UI/ProjectCustomizeSheet.swift:43` — "What a session in this project may load. Everything is on until you turn it off."
- `App/UI/ExtensionsView.swift:2228` — registry.setProjectBinding(ProjectBinding(extensionID: package.id, projectID: project.id, isEnabled: !(binding?.isEnabled ?? true)))
- `docs/current/extensions/PROJECT_SCOPE.md:52` — ### Two readings of the same records

**Why it matters:** The Customise sheet says a project record is a refusal; the Assignments screen says naming a project is how an extension 'belongs' to it. A user who clicks a project chip in Assignments creates a deny record (first click flips true→false) under an allow-list description. The docs call this deliberate, but the product exposes both readings to the same person.

**Direction:** One reader, one writer surface for project scope; drop the Assignments 'Extension → project' card or make it the same picker.

#### [HIGH] EXT-07 — Extension → agent assignment can be made in four places with two different behaviours (record-only vs record+link)

*Category:* duplicate-concept

- `App/Extensions/ExtensionRegistry.swift:243` — func setAgentBinding(_ isEnabled: Bool, packageID: String, agent: ExtensionAgentID) { agentBindings = SkillAssignment.setting(…); save(); record(…) }   // no symlink created
- `App/UI/ExtensionsView.swift:1860` — ForEach(registry.installedAgents) { agent in … Button(isOn ? "\(agent.displayName): on" : "\(agent.displayName): off")
- `App/UI/ExtensionsView.swift:2166` — registry.setAgentBinding(!isOn, packageID: package.id, agent: agent)   // Assignments matrix
- `App/UI/SkillCreateSheet.swift:132` — registry.setAgentBinding(true, packageID: package.id, agent: installation.agent)                 if service.link(name: package.name, into: installation)
- `App/UI/ExtensionsView.swift:1187` — private func repairLinks(_ installation: AgentInstallation) -> String

**Why it matters:** The matrix and the on/off buttons only write a record; the skill sheet and catalog also create the symlink. The health check then reports the record-only case as a broken link and offers 'Repair'. The user cannot know which door does what.

**Direction:** One assignment operation that both records and links (or unlinks), used by every surface.

#### [HIGH] EXT-08 — Agent 'connect' (hooks) lives in four surfaces; the Settings › Agent Status Hooks pane is Claude-only and disagrees with the shared service

*Category:* duplicate-concept

- `App/UI/AgentHookupCard.swift:12` — /// Settings › Agents is where agents are managed; this card mirrors it rather /// than competing with it
- `App/UI/Settings/AgentsSettingsPage.swift:7` — /// The Extensions window's card is a summary of the /// same service; this page is where the user is sent to act.
- `App/UI/Settings/PrivacySettingsPages.swift:382` — try HookInstaller.install()
- `App/Extensions/AgentHookupService.swift:107` — case .hermes: … HermesHookInstaller
- `App/Core/OnboardingState.swift:32` — case .hooks: String(localized: "Status tracking")

**Why it matters:** Same act with four names (Connect / Install / Complete setup / Status tracking). The Hooks pane knows nothing about Hermes and prints a Turkish partial state ('Eksik: …', :375).

**Direction:** Keep Settings › Installed Agents as the one home; the Extensions card and the Hooks pane become links.

#### [HIGH] EXT-09 — There is no way to add your own MCP server; the only doors are the catalog, adoption of something already in an agent config, or importing a JSON export

*Category:* empty-state

- `App/UI/ExtensionsView.swift:1330` — private var toolbar: some View { … if kind == .skill { Button("New Skill…") … Button("Add from Folder…") } Button("Adopt All (\(adoptable.count))")
- `App/UI/ExtensionsView.swift:1291` — String(localized: "No MCP server is defined in the agent configs.")
- `App/UI/ExtensionsView.swift:1043` — private func importSetup(_ installation: AgentInstallation) { let picker = NSOpenPanel(); picker.allowedContentTypes = [.json]

**Why it matters:** The most common everyday task (a local stdio server, a company HTTP endpoint) has no form, while 11 sections and ~9 per-package actions exist. The user must edit ~/.claude.json by hand and press Rescan.

**Direction:** A single 'Add MCP server' form (name, command or URL, env names) that goes through the existing plan → apply transaction.

#### [HIGH] EXT-10 — The security story promised by onboarding is not what adoption does: the pre-adopt scan is fire-and-forget and Uncoil's own scanner never runs on discovered packages

*Category:* other

- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:48` — "Every package is read before it is installed or adopted: risky shell constructs, executables, its source and its licence."
- `App/UI/ExtensionsView.swift:1548` — // A quick scan before anything is copied in. … Task { let outcome = await BumblebeeScanCoordinator(registry: registry).scanBeforeInstall(path: plan.externalPath) … }         let service = ExtensionAdoptionService(layout
- `App/Extensions/Catalog/CatalogInstallService.swift:346` — let scan = ExtensionSecurityScanner.scan(   // the only production call on install
- `App/Extensions/ExtensionRegistry.swift:389` — func setFindings(   // only caller: CatalogInstallService.installSkill
- `App/UI/ExtensionsView.swift:1727` — ? "No findings (scan reach was limited)"

**Why it matters:** The adoption sheet's findings list is always empty for external packages, the adopt proceeds regardless of the async Bumblebee outcome, and onboarding's adopt-all runs no scan. The UI's severity ladder, 'Blocked' gate and 'Security status' row therefore describe catalog installs only, while being shown for everything.

**Direction:** Either run the scanner in discover()/adoption plan and await the pre-adopt scan, or stop showing the security ladder and Security status on packages it never touched.

#### [HIGH] EXT-11 — Internal names shown to users: preset+grants as 'Active profile', 'no adapter', adapter capability flags, 'plan → apply', 'bare mirror', commit SHAs, revision ids

*Category:* terminology

- `App/UI/ExtensionsView.swift:1021` — return "\(preset.name) · \(preset.grantedCapabilities.count) grants"
- `App/UI/ExtensionsView.swift:812` — KeyValueRow(key: "Active profile", value: activeProfile(installation.agent))
- `App/UI/ExtensionsView.swift:1171` — return "no adapter"
- `App/UI/ExtensionsView.swift:1174` — if capabilities.supportsPerSkillSymlinks { parts.append("one symlink per skill") } … "STDIO MCP" … "HTTP MCP" … "per-project MCP" … "reads its config live"
- `App/UI/ExtensionsView.swift:733` — detail: String(localized: "Uncoil changes these files only through plan → apply.")
- `App/UI/ExtensionsView.swift:2372` — detail: String(localized: "Several extensions from the same repo share a single bare mirror.")
- `App/UI/CatalogDetailSheet.swift:137` — case .installed: String(localized: "Reinstall…")

**Why it matters:** 'Profile' becomes a third word for the preset/grant concept that Settings calls 'Session Presets' and 'Permissions'. Adapter, symlink, mirror and SHA are implementation vocabulary that every card header repeats.

**Direction:** Translate each internal noun once into a user noun and reuse the Settings names (preset, permission) instead of coining 'profile'/'grants'.

#### [MEDIUM] EXT-12 — Overview has nine tiles; one is permanently zero, two are only meaningful with Bumblebee, and labels are inconsistently singular

*Category:* concept-overload

- `App/UI/ExtensionsView.swift:674` — StatTile(label: "Installed agents") … "Managed skill" … "Unmanaged skill" … "MCP server" … "Update pending" … "Broken extensions" … "Security finding" … "Config drift" … "Last Bumblebee scan"
- `App/Extensions/ExtensionRegistry.swift:921` — pendingUpdates: updateCandidates.count,   // never populated

**Why it matters:** A dashboard whose tiles are not clickable and whose headline numbers mostly read 0/— teaches the user that this screen is not for them.

**Direction:** Two or three tiles that answer 'what do my agents have' and 'is anything wrong', each a link.

#### [MEDIUM] EXT-13 — Three different 'undo' concepts (revision Rollback, Back to the Previous Config, Activity Undo) plus a 'Rollback History' button that only posts a sentence

*Category:* duplicate-concept

- `App/Extensions/ConfigurationTransactionService.swift:5` — /// Two rollbacks exist in this system and they are deliberately separate
- `App/UI/ExtensionsView.swift:949` — Button("Back to the Previous Config")
- `App/UI/ExtensionsView.swift:2925` — Button("Rollback History") { message = rollbackHistory(package) }
- `App/UI/ExtensionsView.swift:3067` — return "\(package.name)'s previous revision: \(previous.commitSHA ?? previous.id)"
- `App/UI/ExtensionsView.swift:3120` — Button("Undo") { message = registry.undo(event) ?? "This cannot be undone." }

**Why it matters:** The user has to know which of three layers a mistake happened in to find the right undo.

**Direction:** One 'Undo' on the Activity timeline that dispatches to the right mechanism.

#### [MEDIUM] EXT-14 — Quarantine is offered on every package with a default reason 'you asked for it', and the two restore paths behave differently

*Category:* visibility-logic

- `App/UI/ExtensionsView.swift:1895` — Button("Quarantine") { let outcome = registry.quarantine(packageID: package.id, reason: findings.first?.rule ?? String(localized: "you asked for it")
- `App/UI/ExtensionsView.swift:1888` — Button("Release from Quarantine") { message = registry.restoreFromQuarantine(packageID: package.id)
- `App/UI/ExtensionsView.swift:2751` — Button("Restore") { registry.setState(.active, packageID: package.id)
- `App/Extensions/ExtensionRegistry.swift:325` — func restoreFromQuarantine(packageID: String) -> Bool { … store.activate … store.link … setState(.active

**Why it matters:** Security's 'Restore' re-enables state without relinking; the card's 'Release' relinks. Same word-family, different outcome; and a security-team verb is a first-class button on every everyday card.

**Direction:** One restore path; quarantine only as a consequence of a finding or via the Security screen.

#### [MEDIUM] EXT-15 — The per-project picker's agent tabs depend on the Appearance › Quick Launch preference

*Category:* coupling

- `App/UI/ProjectExtensionPicker.swift:323` — static func tabAgents(for settings: SettingsStore) -> [ExtensionAgentID] { settings.launcherProviders.filter { $0 != .terminal }.compactMap(\.extensionAgent) }
- `App/Core/SettingsStore.swift:282` — var launcherProviders: [AgentProvider] { LauncherPrefs.resolved(launcher, installed: installedProviders) }

**Why it matters:** Removing Codex from the quick-launch strip silently removes the ability to record a Codex-specific exception in every project, and any existing Codex exceptions stay in the store invisible.

**Direction:** Tabs from installed agents that can be scoped (extensionScoping != .none), not from a UI-ordering preference.

#### [MEDIUM] EXT-16 — Dead or unreferenced model and engine surface kept alongside the live path

*Category:* other

- `App/Extensions/ExtensionModels.swift:129` — struct AgentProfile: Identifiable, Equatable, Codable   // grep App/: no user
- `App/Extensions/ExtensionDiscovery.swift:4` — enum ExtensionDiscoverySource … case curatedRegistry … struct CuratedRegistryEntry   // no UI user
- `App/Extensions/Catalog/SkillsShProvider.swift:1` — (dormant provider; CATALOG.md: 'not reachable from the default runtime path')
- `App/Extensions/RemoteMCPProbe.swift:1` — (no caller outside Tests)
- `App/Extensions/ThreatCatalog.swift:38` — struct ThreatCatalogStore   // no caller outside Tests
- `App/UI/ExtensionsView.swift:970` — let unmanagedAgents = AgentAdapterRegistry().unmanagedAgents             if !unmanagedAgents.isEmpty {   // always empty

**Why it matters:** Roughly 1,900 lines of App/Extensions (mirror, update engine, update review, probe, supervisor, launcher, secret store/server, threat catalog, discovery sources, skills.sh) are tested but not reachable, and their concepts still shape the UI. Every future reader has to learn them to change the live 40%.

**Direction:** Mark or move built-ahead engines out of the UI's vocabulary until they have a caller.

#### [MEDIUM] EXT-17 — Bumblebee, a third-party optional scanner, is threaded through the everyday surfaces; optional binaries have two homes (Extensions › Security vs Settings › Drivers)

*Category:* agent-leak

- `App/UI/ExtensionsView.swift:702` — StatTile(label: String(localized: "Last Bumblebee scan")
- `App/UI/ExtensionsView.swift:1616` — if let coverage = BumblebeeCoverage.label(for: package) { StatusBadge(text: coverage, level: .neutral) }   // 'Not covered by Bumblebee' on every skill
- `App/UI/ExtensionsCommands.swift:60` — Button("Run Bumblebee Scan") { open(.security, action: .bumblebeeScan) }
- `App/UI/BumblebeeSetupSection.swift:78` — Button(isInstalling ? "Downloading…" : (isInstalled ? "Download again" : "Download and install")) … "Choose the Binary…" … "Open the Folder" … "Open the Repo" … "Re-audit" … "Verify the version"
- `App/UI/Settings/IntegrationsSettingsPages.swift:180` — title: String(localized: "Drivers"), subtitle: "Set up and verify the Agent Browser and Computer Use links. Installation always starts with your approval."
- `TODO.md:54` — Move the optional installs (Bumblebee, Cua Driver, agent browser) out of the required path

**Why it matters:** A normal user sees a product name they do not know on the Overview, on every skill card, in the menu bar and in onboarding. Coverage gaps ('Bumblebee does not read Codex's TOML MCP config') are security-team detail shown by default.

**Direction:** Bumblebee setup beside the other optional drivers in Settings; findings surface only when it is installed.

#### [MEDIUM] EXT-18 — Onboarding describes an install-from-git flow that does not exist as described

*Category:* onboarding

- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:105` — title: String(localized: "Install a skill from a git repository") … Text("Extensions window · “Connect to a GitHub Source…”")
- `App/UI/ExtensionsView.swift:1881` — if package.source.capabilities.canLinkToRepository { Button("Connect to a GitHub Source…")
- `App/Extensions/ExtensionSourcePolicy.swift:80` — case .local: … canLinkToRepository: true … case .adopted: … canLinkToRepository: true

**Why it matters:** The button only appears on a skill that already exists locally and only relabels its source; the promised 'pinned to a tag or tracking a branch… staged, scanned, smoke-tested' update path never runs (EXT-02). A first-run user is taught a flow they cannot perform.

**Direction:** Onboarding should describe the catalog and the per-project picker only.

#### [MEDIUM] EXT-19 — Turkish strings in the English UI and in helper stderr

*Category:* terminology

- `App/UI/ExtensionsView.swift:225` — return "Tarama bitti: \(registry.installations.count) agent · "
- `App/UI/ExtensionsView.swift:1388` — parts.append("\(adopted.count) paket sahiplenildi: …")
- `App/UI/ExtensionsView.swift:1670` — ?? (package.activeRevision == nil ? "—" : "yerel kopya")
- `App/UI/ExtensionsView.swift:1719` — KeyValueRow(key: "Dependency listesi", …) … KeyValueRow(key: "Trigger test sonucu", …)
- `App/UI/ExtensionsView.swift:1844` — return "Secret gerekmiyor"
- `App/UI/ExtensionsView.swift:2906` — key: "Breaking-change ihtimali", value: review?.breakingChangeRisk.label ?? "incelenmedi"
- `App/UI/ExtensionSearchResults.swift:120` — ("Etkinlik", Array(events)),
- `App/UI/ExtensionAdoptionSheet.swift:134` — case .added: "eklenecek" … case .removed: "geride kalacak"
- `App/UI/Settings/PrivacySettingsPages.swift:375` — case .partiallyInstalled(let missing): "Eksik: …"
- `ExtensionHelper/main.swift:54` — fail("bilinmeyen extension: \(extensionID)")

**Why it matters:** Violates the repo's own 'UI strings are English' rule and makes the notice classifier depend on bilingual keyword lists (ExtensionNotices.swift:83-104).

**Direction:** Sweep; then let screens pass an explicit notice level instead of inferring it from words.

#### [MEDIUM] EXT-20 — Skills have four acquisition doors plus a Sources screen; MCP servers have three; none is labelled as the primary one

*Category:* navigation

- `App/UI/ExtensionsView.swift:1332` — Button("New Skill…") … Button("Add from Folder…") … Button("Adopt All (…)")
- `App/UI/ExtensionsView.swift:26` — case .skillCatalog: String(localized: "Skill Catalog")
- `App/UI/ExtensionsView.swift:2374` — TextField("owner/repo", text: $newSource) … Button("Add", action: add)

**Why it matters:** Catalog, folder, authoring, adoption and sources are five answers to 'how do I get a skill', spread over three sections.

**Direction:** One 'Add' menu on the Skills/MCP screen with the catalog as default.

#### [MEDIUM] EXT-21 — Extensions › Agents duplicates Settings › Installed Agents almost row for row, then adds a config-surgery card per agent

*Category:* duplicate-concept

- `App/UI/ExtensionsView.swift:786` — AgentHookupCard(hookup: hookup, message: $message)
- `App/UI/ExtensionsView.swift:800` — KeyValueRow(key: "Install path") … "Binary version" … "Active profile" … "Update status" … "Login status" … "Config directory" … "MCP config" … "Skills directory" … "Last verified" … "Declared MCP" … "Visible skill"
- `App/UI/ExtensionsView.swift:863` — Button("Validate") … Button("Repair") … Button("Export Setup") … Button("Import Setup") … Button("Show Config")

**Why it matters:** Two 'Agents' pages in two windows with the same rows and buttons, plus Settings › Agents' seven other panes (Accounts, CLI Tools, Run Parameters, Working Mode, Session Presets, Blueprints, Quick Launch) — 'agent' has no single home.

**Direction:** Settings › Installed Agents owns identity/connection; Extensions keeps only what an agent declares (its MCP servers and skills).

#### [MEDIUM] EXT-23 — discover() runs synchronously on the main thread every time the project Customise sheet's MCP tab or the New Project sheet opens

*Category:* other

- `App/UI/ProjectCustomizeSheet.swift:71` — .task(id: tab) { if tab == .extensions { registry.discover() } }
- `App/UI/NewProjectSheet.swift:62` — .task { registry.discover() … }
- `App/UI/ExtensionsView.swift:199` — // Yielding first so the button shows its running state before the             // synchronous discovery pass takes the main thread.

**Why it matters:** discover() detects binaries, reads and validates every agent config, computes link statuses, rewrites lock files and saves registry.json; the everyday sheet pays the whole inspector's cost.

**Direction:** Scope reads from the cached document; discovery on a background actor.

#### [LOW] EXT-22 — Three search boxes and three 'scan' verbs inside one window

*Category:* navigation

- `App/UI/ExtensionsView.swift:238` — TextField("Search everywhere", text: $query)
- `App/UI/ExtensionsView.swift:2268` — TextField("Search this page…", text: $query)   // Assignments
- `App/UI/CatalogScreen.swift:62` — TextField(catalog.kind == .skill ? "Search skills" : "Search MCP servers", text: $catalog.searchText)
- `App/UI/ExtensionsCommands.swift:56` — Button("Rescan") … Button("Run Health Check") … Button("Run Bumblebee Scan")

**Why it matters:** Search-everywhere does not search the catalogs; the catalog search does not search installed items; Assignments has its own. 'Rescan' (discover), hookup 'Rescan' (hooks), 'Run Health Check' and Security's Manual/Project/Deep are six scan buttons.

**Direction:** One search that spans installed + catalog; one rescan.

#### [LOW] EXT-24 — Enable/disable of a declared MCP server is labelled 'Open'/'Close'; counts say 'records'; section descriptions are unlocalised literals

*Category:* terminology

- `App/UI/ExtensionsView.swift:911` — Button(server.isEnabled ? "Close" : "Open")
- `App/UI/ExtensionsView.swift:1350` — Text("\(packages.count) records")
- `App/UI/ExtensionsView.swift:82` — var description: String { switch self { case .overview: "The overall state of the agent extension system"

**Why it matters:** Small, but each is a word the user has to translate.

**Direction:** Enable/Disable; items; localize.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Extensions window (container) | window | `App/UI/ExtensionsView.swift` | Extensions menu › Open Extensions (Cmd+Shift+E) — App/UI/ExtensionsCommands.swift:45; Extensions menu › one item per section (11) — ExtensionsCommands.swift:50-52; Extensions menu › Rescan (Cmd+Shift+ |
| Overview | screen | `App/UI/ExtensionsView.swift` | Default section on open; Run Health Check jumps here (line 199) |
| Agents | screen | `App/UI/ExtensionsView.swift` | Sidebar › Agents; Extensions menu › Agents; Settings › Installed Agents doc-comment says 'The same list opens the Extensions window's Agents screen' (CHANGELOG.md:33) — inferred there is no actual lin |
| Skills | screen | `App/UI/ExtensionsView.swift` | Sidebar › Skills; Search result rows |
| MCP Servers | screen | `App/UI/ExtensionsView.swift` | Sidebar › MCP Servers |
| PackageCard (expanded detail + actions) | row | `App/UI/ExtensionsView.swift` | Skills / MCP Servers screens; -extensions-expand <id> |
| MCP Catalog / Skill Catalog | screen | `App/UI/CatalogScreen.swift` | Sidebar › MCP Catalog / Skill Catalog |
| CatalogDetailSheet | sheet | `App/UI/CatalogDetailSheet.swift` | CatalogCard tap |
| Assignments | screen | `App/UI/ExtensionsView.swift` | Sidebar › Assignments |
| Sources | screen | `App/UI/ExtensionsView.swift` | Sidebar › Sources |
| Security | screen | `App/UI/ExtensionsView.swift` | Sidebar › Security; Extensions menu › Run Bumblebee Scan; badge on sidebar row |
| Updates | screen | `App/UI/ExtensionsView.swift` | Sidebar › Updates (badge) |
| Activity | screen | `App/UI/ExtensionsView.swift` | Sidebar › Activity |
| Search results | screen | `App/UI/ExtensionSearchResults.swift` | Sidebar search field; -extensions-query |
| Notice stack | banner | `App/UI/ExtensionNotices.swift` | any action result |
| ExtensionAdoptionSheet | sheet | `App/UI/ExtensionAdoptionSheet.swift` | PackageCard › Adopt into Uncoil… |
| RepositoryLinkSheet | sheet | `App/UI/ExtensionAdoptionSheet.swift` | PackageCard › Connect to a GitHub Source… |
| ConfigPlanSheet | sheet | `App/UI/ConfigPlanSheet.swift` | Agents screen Open/Close/Remove/Import Setup |
| SkillCreateSheet | sheet | `App/UI/SkillCreateSheet.swift` | Skills › New Skill… |
| ProjectExtensionPicker | panel | `App/UI/ProjectExtensionPicker.swift` | NewProjectSheet › 'MCP servers & skills' row → extensions page (App/UI/NewProjectSheet.swift:141); Sidebar project context menu › Customise… (App/UI/AppKit/SidebarOutline.swift:765) → ProjectCustomize |
| Settings › Agents › Installed Agents | screen | `App/UI/Settings/AgentsSettingsPage.swift` | Settings › Agents › Installed Agents |
| Settings › Uncoil › Agent Status Hooks | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings › Uncoil › Agent Status Hooks |
| Settings › Uncoil › Uncoil MCP | screen | `App/UI/Settings/McpSettingsPage.swift` | Settings › Uncoil › Uncoil MCP |
| Onboarding › Extensions step | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | First run, step 11 of 13 (App/Core/OnboardingState.swift:10-22) |

### Concepts

- `U!` **Extension / Package** — ExtensionPackage: one skill or MCP server with id, kind, source, state, active/previous revision, hasLocalModification. UI says 'Extension' in headings and 'package'/'records' in counts ('N records' ExtensionsView.swift:1350, 'Package not found' :2994). *Overlaps:* Skill, MCP Server
- `U` **Skill** — A folder with SKILL.md. Four acquisition paths: New Skill…, Add from Folder…, Skill Catalog, Adopt; plus 'Connect to a GitHub Source…' afterwards. *Overlaps:* Package
- `U` **MCP Server** — MCPServerDefinition as an agent's config declares it (transport, command/url, environmentKeys). Discovered from agent configs as detectedExternal or remoteMCP; installed from catalog as adopted/remoteMCP. *Overlaps:* Package, Uncoil MCP control plane
- `U` **Agent (two identities)** — AgentProvider (App/Core/Models.swift:20: claude, codex, gemini, opencode, grok, hermes, cursor, terminal; display 'Claude','Gemini','Grok') vs ExtensionAgentID (ExtensionModels.swift:8: claudeCode, codex, geminiCLI, cursor, amp, opencode, grok, hermes; display 'Claude Code','Gemini CLI','Grok CLI'). Mapped by .provider / .extensionAgent. Amp exists only on the Extensions side; Terminal only on the provider side. *Overlaps:* Installed Agents, Uncoil MCP › Per Agent
- `U!` **Source (ExtensionSource)** — Where a package came from: managedGitHub(repo, subpath, tracking) / bundled / local / adopted / detectedExternal / remoteMCP. Labels shown verbatim: 'Unmanaged (local)', 'Unmanaged (installed outside)', 'Adopted · in Uncoil's store', 'Shipped with Uncoil' (ExtensionModels.swift:236-251). Drives ExtensionSourceCapabilities. *Overlaps:* Managed/Unmanaged, Adoption, Sources (GitHub repos)
- `U!` **Sources (GitHub repositories) / Mirror** — registry.sources strings plus repos of managedGitHub packages (effectiveSources). Card subtitle exposes the implementation: 'share a single bare mirror' (ExtensionsView.swift:2372). ExtensionMirror.ensureMirror/materializeRevision have no production caller. *Overlaps:* Source (enum), Tracking mode
- `U!` **Tracking mode** — ExtensionSource.TrackingMode pinnedCommit/tag/branch; UI 'Pin Commit…', 'Switch Branch/Tag…' (2494-2498) and RepositoryLinkSheet Branch/Tag/Commit picker. *Overlaps:* Revision
- `U!` **Revision** — InstalledRevision: immutable checkout keyed by commit SHA or content hash under ~/.uncoil/extensions/revisions. UI shows 'Installed commit', 'Available commit', 'previous: <sha>', revision ids like 'catalog/<slug>@<pin12>'. *Overlaps:* Update candidate, Rollback
- `U` **Managed / Unmanaged** — source.isOwnedByUncoil (managedGitHub, bundled, adopted). Overview tiles 'Managed skill'/'Unmanaged skill'; 'Management' row 'Managed by Uncoil'/'Unmanaged'. *Overlaps:* Source, Adoption
- `U!` **Adoption** — ExtensionAdoptionService.Plan: copy an external skill's files (or an MCP definition) into Uncoil's store, back up, replace agent folders with symlinks. Shown as 'Adopt into Uncoil…', 'Adopt All', onboarding 'Let Uncoil manage these'. *Overlaps:* Managed, Source
- `U` **Assignment / Binding** — AgentBinding (extension ↔ agent, isEnabled, linkPath) and ProjectBinding (extension ↔ project?, agent?, isEnabled). UI says 'assignment' ('Agent assignments', 'Project assignments', 'Clashing assignments', 'Assign All to X'); code says 'binding'. *Overlaps:* Project scope, Install into
- `U` **Project scope (per-project selection)** — ProjectExtensionSelection (UI) → ProjectBinding records → ProjectScopeService/ProjectExtensionScope at launch → --mcp-config/--strict-mcp-config, -c mcp_servers.X.enabled=false, -c skills.config, OPENCODE_CONFIG_CONTENT (App/Terminal/TerminalHost.swift:404, 557, 995-1020). Deny-list reading. *Overlaps:* Assignment (allow-list reading of the same records)
- `U!` **Configuration transaction / plan → apply** — ConfigurationTransaction (diff, baseHash, backupPath, status planned/applied/rolledBack/staleConfig/failed). Shown as 'Config change plan', 'plan → apply' (Overview :733), 'Back to the Previous Config'. *Overlaps:* Rollback (revision), Undo (audit)
- `U!` **Rollback (three kinds)** — (1) ExtensionUpdateEngine.rollback to previousRevision — 'Rollback' buttons, 'Rollback history'; (2) ConfigurationTransactionService.rollback of an agent config file — 'Back to the Previous Config'; (3) ExtensionRegistry.undo(event) — Activity 'Undo'. Code comment ConfigurationTransactionService.swift:5-8 notes the first two are deliberately separate.
- `U` **Update candidate / Update review** — UpdateCandidate (available SHA, commit count, changed files) and UpdateReview (security diff, added permissions/tools, breaking-change risk). Populated only by ExtensionUpdateEngine.checkForUpdate, which has no caller outside Tests. *Overlaps:* Catalog 'Update' badge (computed separately by content hash, CatalogStore.swift:190-212)
- `U` **Security finding / severity ladder** — SecurityFinding with origin uncoil|bumblebee and severity info/low/needsReview/high/blocked ('Information', 'Low Risk', 'Needs Review', 'High Risk', 'Blocked'); Accept per finding. Uncoil's scanner runs only in CatalogInstallService.stageSkill (:346) and in the dead UpdateReview path. *Overlaps:* Bumblebee findings, Quarantine
- `U!` **Bumblebee** — Third-party scanner binary (download/verify/self-test/threat catalog, 8 BumblebeeScanKinds, coverage gaps). Owns an Overview tile, the top of Security, a menu item, a quick action, a per-package badge 'Not covered by Bumblebee', a Coverage card, and a background daily scan scheduled from MainWindow.swift:147-160. *Overlaps:* Settings › Drivers (the other optional-binary installer), Uncoil findings
- `U!` **Quarantine** — registry.quarantine: disable all agent bindings, unlink, refuse in launcher, keep files. Offered on every non-quarantined package with default reason 'you asked for it' (ExtensionsView.swift:1895-1898). Two restore paths: PackageCard 'Release from Quarantine' → restoreFromQuarantine (relinks); Security 'Restore' → setState(.active) only (:2751-2752). *Overlaps:* Disabled state, Uninstall
- `U!` **Config drift / Broken** — configDriftCount = packages with hasLocalModification + config issues of severity error (ExtensionRegistry.swift:783-786); brokenPackages = state .broken or link needsRepair. Shown as tiles and health rows. *Overlaps:* Modified Locally badge, Repair
- `U` **Health check** — registry.healthChecks(): 4-5 fixed checks. Triggered from sidebar button, Extensions menu, and on every discover(). *Overlaps:* Rescan / Rediscover, AgentHookupService.scan (a different 'Rescan')
- `U!` **Profile / Preset / Grants** — Agents screen row 'Active profile' renders the SessionPreset for the provider as '<preset.name> · N grants' (ExtensionsView.swift:1016-1023). 'Profile' is a third name for preset+capability grants; AgentProfile struct in ExtensionModels.swift:129-160 is unused anywhere. *Overlaps:* Settings › Session Presets, Settings › Permissions
- `U!` **Adapter / Capabilities** — AgentAdapter protocol per agent; AgentProviderCapabilities flags rendered as the card subtitle 'one symlink per skill · STDIO MCP · HTTP MCP · per-project MCP · reads its config live · reports the login state' (1169-1185); fallback text 'no adapter' (:977, :1171). *Overlaps:* Integration level (Detected only / Terminal only / Control plane / Live events), ExtensionScopingSupport
- `U` **Integration level** — AgentIntegrationLevel none/observed/controlPlane/hooks with labels 'Detected only', 'Terminal only', 'Control plane', 'Live events' (App/Extensions/AgentIntegration.swift:25-31). *Overlaps:* Settings › Agent Status Hooks, Settings › Uncoil MCP › Per Agent
- `U` **Secret** — environmentKeys names in config; values meant to live in Keychain (ExtensionSecretStore) and be served to uncoil-extension over a socket. No UI ever calls ExtensionSecretStore.save; PackageCard shows 'Secret required: KEY' (:1840) and CatalogDetailSheet promises entry 'after install' (:364).
- `U` **Catalog** — CatalogItem from McpRegistryProvider / GitHubSkillProvider (SkillsShProvider dormant). Views Featured/Popular/Trending/Updated/New; badges Official/Curated/Deprecated/Reviewed/Audit failed; 'Installation method' choices npx/uvx/docker/remote. *Overlaps:* Sources, Add from Folder
- `U` **Trigger Tester** — SkillTriggerTester heuristics: which skill a prompt would trigger, verdicts single/noMatch/conflict/tooBroad, optional persisted history.
- `U` **Activity / audit** — AuditEvent kinds (12) with Undo where undoToken exists; search group labelled 'Etkinlik'. *Overlaps:* Rollback
- `i` **Launcher / manifest / process health (internal, not wired)** — ExtensionLauncherService writes a manifest so agent configs point at 'uncoil-extension run <id>'; MCPProcessSupervisor/run records feed 'Last health check', 'Last error', Logs, Restart. writeManifest and launchCommand have no production caller; refreshProcessHealth returns early on empty run records.
- `U` **Uncoil MCP control plane (out of scope but adjacent)** — Uncoil's own 'uncoil' MCP server, registered per session; excluded from project scope by ControlPlaneMCPName; hidden from the picker (ProjectExtensionPicker.swift:150) but visible as a package on the MCP Servers screen (discover() does not exclude it; inferred). *Overlaps:* MCP Server

### Flows

- **Install an MCP server from the catalog and give it to a project** (9 steps) — friction: Two windows and two mental models for one intent (install ≈ package manager vocabulary; scope ≈ project sheet). Secrets dead-end. The project picker is deny-only ('everything is on until you turn it off'), so 'give it to project X only' means visiting every other project's Customise sheet, or using Extensions › Assignments › Extension → project chips, which write the same ProjectBinding records but are described with allow-list wording.
- **Adopt a skill the user already installed by hand** (5 steps) — friction: The onboarding ladder promises 'Every package is read before it is installed or adopted' (OnboardingExtensionsSteps.swift:48) but adoption neither waits for Bumblebee nor runs Uncoil's own scanner; onboarding adoptAll (:146-191) runs no scan at all. 'Adopt' is an unfamiliar verb for 'let Uncoil manage this'.
- **Scope MCP servers and skills per project (the everyday flow)** (4 steps) — friction: Well-designed core, but: the tab set depends on an Appearance › Quick Launch preference; the picker says 'Skills are not scoped for Claude Code' on every project; the same ProjectBinding records are also editable as chips in Extensions › Assignments with different wording; the Customise sheet writes through ExtensionRegistry.shared while the Extensions window writes through its own instance (last save wins).
- **Give an extension to an agent (four doors)** (5 steps) — friction: Four surfaces, two behaviours (record-only vs record+link). A matrix tick on Assignments produces a binding that health then reports as a broken link until Repair is pressed (inferred from discover() computing linkStatuses for active bindings, ExtensionRegistry.swift:513-522).
- **Connect an agent (hooks) — four surfaces** (4 steps) — friction: Same act in four places; the Hooks pane knows nothing of Hermes hooks that AgentHookupService handles (AgentHookupService.swift:107-114), so the two Settings panes can disagree.
- **Update an extension / pin a source (dead end)** (5 steps) — friction: Two of eleven sections, two sheets, a badge, a tile and ~6 buttons are inert.
- **Health / rescan** (3 steps) — friction: Three 'scan' verbs (Rescan, Run Health Check, Bumblebee scan) plus Security's Manual/Project/Deep — six scan buttons in one window.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| registry.json (packages, agentBindings, projectBindings, findings, updateCandidates, sources, configTransactions, Bumblebee state) | global | ~/.uncoil/extensions/locks/registry.json (ExtensionRegistry.documentURL, ExtensionRegistry.swift:87) | Every Extensions screen; ProjectCustomizeSheet; NewProjectSheet; Onboarding; CatalogInstallService |  |
| audit.jsonl | global | ~/.uncoil/extensions/audit/audit.jsonl | append-only from registry.record | yes |
| AgentBinding (extension ↔ agent) | agent | registry.json | Assignments matrix; PackageCard on/off; SkillCreateSheet; Catalog 'Install into'; adoption | yes |
| ProjectBinding (extension ↔ project ↔ agent?) | project | registry.json | NewProjectSheet page; ProjectCustomizeSheet 'MCP & Skills'; Extensions › Assignments 'Extension → project' |  |
| Agent config files (~/.claude.json, ~/.codex/config.toml, ~/.gemini/settings.json, ~/.cursor/mcp.json, ~/.config/amp/…, ~/.config/opencode/…, ~/.grok/…, ~/.hermes/config.yaml) | agent | user home, per agent | Agents screen Open/Close/Remove/Import Setup; Catalog MCP install; hook installers |  |
| Skill lock files | global | ~/.agents/.skill-lock.json and store (registry.writeLockFiles, skillLockHome) | every discover() | yes |
| Launcher manifest (locks/launcher-manifest) | global | ~/.uncoil/extensions/locks/<ExtensionLaunchManifest.fileName> | never in production (writeManifest has no caller) | yes |
| Extension secrets | global | Keychain service com.gokhantopbas.uncoil.extensions.v1 (ExtensionSecretStore.swift:12) | nowhere (no UI calls save) |  |
| Catalog cache | global | ~/.uncoil/extensions/catalog-cache/ (CATALOG.md) | automatic | yes |
| GitHub token for skill catalog | account | Keychain key github-token (CatalogScreen.swift:44) | CatalogScreen embedded GitHubLoginView; Settings › GitHub |  |
| Bumblebee binary location | global | app bundle / BumblebeeLocator.managedDirectory / PATH | Extensions › Security › BumblebeeSetupSection (Download, Choose the Binary…) | yes |
| Threat catalog | global | catalog.json / catalog-previous.json (ThreatCatalogStore) | never (no caller) | yes |
| Agent binary location override | agent | SettingsStore.agentBinaryLocation(forCommand:) | Extensions › Agents hookup card Locate…; Settings › Installed Agents Locate… | yes |
| Quick Launch provider order (decides picker tabs) | global | SettingsStore.launcher / launcherProviders (SettingsStore.swift:282) | Settings › Appearance › Quick Launch | yes |
| Skill trigger test history + 'Keep test history' toggle | global | SkillTriggerHistory (persisted; file not inspected) | Skills › Trigger Tester | yes |
| Extensions window frame | global | NSWindow autosave 'UncoilExtensionsWindow' (ExtensionsView.swift:3139-3150) | automatic | yes |
| Accepted findings | global | registry.json findings[].isAccepted | Security › Accept |  |

### Visibility gates

- `App/UI/ExtensionsView.swift:312-320` — visibleSections: sidebar rows filtered by query against title + bilingual keywords; empty match shows all → which of 11 sections are listed
- `App/UI/ExtensionsView.swift:322-331` — badge(for:) shows counts only for .updates (updateCandidates non-empty — never in prod) and .security (openFindings) → sidebar badges
- `App/UI/ExtensionsView.swift:384-398` — isSearching → ExtensionSearchResults replaces sectionScreen → whole content column
- `App/UI/ExtensionsView.swift:1278-1281, 1332-1348` — kind == .skill → toolbar shows New Skill…/Add from Folder…, TriggerTesterCard; .mcpServer → Adopt All is the accent button → Skills vs MCP Servers toolbars
- `App/UI/ExtensionsView.swift:1265-1273` — adoptable = detectedExternal && (mcp ? definition exists : path exists) → Adopt All count/enabled
- `App/UI/ExtensionsView.swift:1856-1958` — package.source.capabilities.canAssign / canAdopt / canLinkToRepository / canUpdate (ExtensionSourceCapabilities.of), package.state == .quarantined, activeRevision != nil, kind == .mcpServer, logURL != nil, source.isOwnedByUncoil → which of ~11 action buttons appear on a PackageCard
- `App/Extensions/ExtensionRegistry.swift:795-798` — registry.installedAgents = ExtensionAgentID.supported ∩ detected installations → agent toggles on PackageCard, Assignments columns, SkillCreateSheet checkboxes
- `App/UI/CatalogDetailSheet.swift:488-492` — ExtensionAgentID.supported.filter{installed} plus service.incompatibilityReason per agent/choice → 'Install into' rows and their disabled state
- `App/UI/ExtensionsView.swift:970-981; App/Extensions/AgentAdapterRegistry.swift:11-14, 26-29` — AgentAdapterRegistry().unmanagedAgents.isEmpty — always true (adapters cover all 8 cases) → 'Agents not managed yet' card (dead)
- `App/UI/ExtensionsView.swift:937` — registry.rollbackCandidate(for:) != nil → 'Back to the Previous Config' row
- `App/Extensions/Bumblebee.swift:420-431` — BumblebeeCoverage.isCovered(package): remoteMCP → false; everything else → kind == .mcpServer → 'Not covered by Bumblebee' badge on every skill card
- `App/UI/ExtensionsView.swift:2604-2610` — scans.isInstalled toggles Scan card subtitle; installationToken bumps re-read → Security copy
- `App/UI/ExtensionsView.swift:2740` — quarantined.isEmpty hides the Quarantine card → Security › Quarantine
- `App/UI/ExtensionsView.swift:2830-2838` — registry.updateCandidates.isEmpty → 'No update' card; managedPackages.isEmpty chooses the wording → Updates screen body
- `App/UI/ProjectExtensionPicker.swift:167-170, 270-273` — tab == nil → disagreements shown as 'on for X'/'off for X'; skillBlindAgents computed from provider.extensionScoping == .mcpOnly && != .opencode → picker footnotes and row subtitles
- `App/UI/ProjectExtensionPicker.swift:323-327` — ProjectExtensionPicker.tabAgents = settings.launcherProviders minus .terminal mapped to extensionAgent → which per-agent tabs exist in both project sheets
- `App/UI/ProjectExtensionPicker.swift:150` — mcpServers excludes name == ControlPlaneMCPName → 'uncoil' hidden from picker only
- `App/UI/NewProjectSheet.swift:~192-196` — excludedCount == 0 ? 'Everything this project's agents already have' : 'N turned off for this project' → row subtitle in New Project
- `App/UI/CatalogScreen.swift:21-27, 145-170` — catalog.kind == .skill && !gitHubConnected → gitHubConnectCard; catalog.isShowingStaleCache → banner; catalog.phase drives skeleton/error/empty/grid → catalog page states
- `App/Core/Models.swift:159-206` — provider.extensionScoping / wiresControlPlane per AgentProvider case → what launch actually enforces; Settings › Uncoil MCP per-agent wired/not wired
- `App/UI/ExtensionNotices.swift:83-104` — ExtensionNoticeCenter.level(of:) keyword lists (EN+TR) classify plain-string messages → whether a toast auto-dismisses
- `App/UI/ExtensionsView.swift:129-160` — LaunchConfig -extensions-section/-query/-expand/-action seed state on .task → deterministic UI-test entry

### Open questions

- Is the git-mirror update path (ExtensionMirror/UpdateEngine) intended to ship, or has the catalog reinstall superseded it? The answer decides whether Sources/Updates are hidden or wired.
- Is the `uncoil-extension` launcher (manifest, secret socket, process health) still planned? If not, ExtensionHelper, ExtensionSecretServer and MainWindow.startExtensionSecretServer can go, along with four card rows.
- Does the 'uncoil' control-plane server appear as a package on the MCP Servers screen? discover() does not filter ControlPlaneMCPName (inferred yes); the picker hides it, the list may not.
- Are there users for the Assignments 'Extension → project' chips beyond what the Customise sheet does? If not, deleting them removes the allow-vs-deny reading conflict entirely.
- Should Bumblebee be visible at all before it is installed? Today it owns a tile, a badge on every skill, a menu item and the top of Security regardless.
- What is the intended home for agent identity: Settings › Installed Agents (8 ExtensionAgentIDs) or the AgentProvider list used by Uncoil MCP, CLI Tools and Quick Launch (7)? Amp only exists in one of them.
- Is `ExtensionAgentID.supported` meant to diverge from `allCases` again (an agent detected but without an adapter)? If not, the 'not managed yet' card and `unmanagedAgents` can be removed.

---

## Agent/provider abstraction (AgentProvider, ExtensionAgentID, AgentWorkingMode, adapters, hooks, CLI install/update, Codex app-server, launch options)

From the user's chair, Uncoil "knows" a set of AI coding agents (Claude, Codex, Gemini, OpenCode, Grok, Hermes, Cursor, plus Amp and a plain Terminal) and, for each one, a long tail of per-agent facts: is it installed and where, how it updates, which accounts it has, what working mode it starts in, whether Shift+Enter inserts a newline, whether Uncoil can see its status (hooks), whether it loads Uncoil's MCP tools (control plane), whether a project can restrict its MCP servers/skills, whether it can be resumed/hibernated, which models and effort levels can be picked, whether usage can be read, and whether a handover can be produced. Internally these facts are not held in one registry: they are split between two parallel identity enums (AgentProvider with a `.terminal` case, ExtensionAgentID with an `.amp` case) joined by a hand-written bidirectional map, eleven computed booleans on AgentProvider, an AgentProviderCapabilities struct per adapter, a prose "integration ceiling" table in AgentIntegration.swift, a 12-case AgentWorkingMode enum that mixes Claude, Codex, Grok and Cursor vocabulary, and roughly 21 `switch provider` plus 45 `provider == .x` sites across ~30 files. The same per-agent rows are then rendered as matrices on five Settings pages, two onboarding steps, the Extensions window's Agents screen, and several sheets, so a user meets "the agent list" in at least three different lengths (7, 8-with-Amp, 8-with-Terminal) and meets internal vocabulary (adapter, grants, permission mode, STDIO MCP, symlink per skill, preset id) as if it were product language. Codex additionally has a private structured-session subsystem (App/Codex) hidden behind a launch flag whose concepts nonetheless leak into shared session, notification and terminal code.

### Findings

#### [CRITICAL] AP-01 — Two parallel agent identity enums (AgentProvider vs ExtensionAgentID) with a hand-maintained bidirectional map, so 'the agent list' has three different lengths across the UI

*Category:* duplicate-concept

- `App/Core/Models.swift:20` — enum AgentProvider: String, Codable, CaseIterable, Identifiable { case claude case codex case gemini case opencode case grok case hermes case cursor case terminal
- `App/Extensions/ExtensionModels.swift:8` — enum ExtensionAgentID: String, Codable, CaseIterable, Identifiable, Sendable { case claudeCode case codex case geminiCLI case cursor case amp case opencode case grok case hermes
- `App/Extensions/ExtensionModels.swift:33` — var provider: AgentProvider? { switch self { case .claudeCode: .claude … case .amp: nil } }
- `App/Extensions/ExtensionModels.swift:175` — var extensionAgent: ExtensionAgentID? { ExtensionAgentID.allCases.first { $0.provider == self } }
- `App/Extensions/ExtensionModels.swift:22` — case .claudeCode: "Claude Code" … case .geminiCLI: "Gemini CLI" … case .grok: "Grok CLI"
- `App/Core/Models.swift:47` — case .claude: "Claude" … case .gemini: "Gemini" … case .grok: "Grok"
- `App/UI/Settings/AgentsSettingsPage.swift:32` — ForEach(hookup.states) { state in  AgentControlRow(state: state, … chosenLocation: settings.agentBinaryLocation(forCommand: state.agent.cliBinaryName)
- `App/UI/Settings/AgentSettingsPages.swift:13` — private let providers: [AgentProvider] = AgentProvider.agents
- `App/Core/PaletteModel.swift:342` — for provider in AgentProvider.sessionKinds {

**Why it matters:** Settings > Agents > Installed Agents and Extensions > Agents list 8 agents including Amp; Accounts, CLI Tools, Run Parameters, Working Mode, Shift+Enter and Onboarding list 7 (no Amp); Quick Launch, the palette and the menu bar list 8 including Terminal. The same product is called 'Claude' on one page and 'Claude Code' on the next, 'Grok' vs 'Grok CLI'. Every view that needs a fact from the other enum hops the map (ProjectExtensionPicker.swift:134 `$0.provider?.extensionScoping`, AgentsSettingsPage.swift:120 `state.agent.provider.flatMap { settings.cliVersions[$0.rawValue] }`), and the two `displayName`s, two colour switches (Models.swift:59 vs ProviderGlyph.swift:30) and two mark switches (ProviderGlyph.swift:70 vs 105) must be kept in step by hand. A user cannot form one mental model of 'an agent' when the app itself has two.

**Direction:** One agent descriptor with optional 'launchable' and optional 'config-managed' facets, and one display name.

#### [CRITICAL] AP-02 — No capability registry: per-provider facts are spread over ~21 `switch provider` sites and 45 `provider == .x` checks in ~30 files, with the same fact re-stated in 3-4 places

*Category:* coupling

- `App/Core/Models.swift:131` — var reportsStatusThroughHooks: Bool { switch self { case .claude: true … case .codex, .gemini, .opencode, .grok, .cursor, .hermes, .terminal: false
- `App/Extensions/AgentIntegration.swift:63` — /// The table mirrors what the rest of the app actually does — notably `AgentProvider.wiresControlPlane`, which is why Codex reaches `.controlPlane` on its own and Gemini does not. static func forAgent(_ agent: Extension
- `App/Extensions/AgentHookupService.swift:100` — switch agent { case .claudeCode: return .forHookCapableAgent( … case .hermes: … case .codex, .geminiCLI, .cursor, .amp, .opencode, .grok: return .forHooklessAgent(
- `App/Terminal/TerminalHost.swift:968` — if record.provider == .claude, let sid = resumeID { command += " --resume \(shellQuote(sid))" } if record.provider == .codex, let sid = resumeID { command += " resume \(shellQuote(sid))" } if record.provider == .opencode
- `App/Core/Models.swift:241` — var resumesConversation: Bool { switch self { case .claude, .codex, .opencode, .grok, .cursor, .hermes: true case .gemini, .terminal: false
- `App/Terminal/TerminalHost.swift:368` — switch record.provider { case .claude: ClaudeSessionStore.state( … case .codex: CodexSessionStore.state( … default: .unknown
- `App/Core/AgentCLIInstall.swift:255` — switch provider { case .claude: return .run("claude update") case .hermes: return .run("hermes update") case .cursor: return .run("cursor-agent update") case .grok: return .run("grok update") case .opencode: return .run(
- `App/Core/Models.swift:221` — var hasBuiltInUpdater: Bool { switch self { case .claude, .cursor, .grok, .opencode, .hermes: true case .codex, .gemini, .terminal: false
- `App/Usage/HandoffProducer.swift:40` — static func canProduce(_ provider: AgentProvider) -> Bool { provider == .claude || provider == .codex }
- `App/Usage/UsageStore.swift:60` — let resolved = providers ?? [ CodexUsageProvider(), ClaudeUsageProvider(probeDirectory: Self.defaultProbeDirectory()), GeminiUsageProvider(), ]
- `App/Core/Models.swift:33` — /// This list was written out by hand in twenty-two places — some with the terminal, some without, and the difference between the two was never stated.

**Why it matters:** 'Can this agent resume?' is answered by resumesConversation (Models), by the if-chain that emits the flag (TerminalHost:968-990), and by the store switch that verifies it (TerminalHost:368-382). 'Does it report through hooks?' is answered by reportsStatusThroughHooks, by AgentIntegrationSupport.forAgent's ceiling, and by AgentHookupService's switch. 'Does it self-update?' by hasBuiltInUpdater, by AgentCLIInstall.source's path sniffing, and by updatePlan's native switch. The code's own comments (Models.swift:33-36, 110-114) record that this already produced bugs (an MCP badge on a terminal, a Gemini row announcing Claude events). Every new feature that touches an agent will add another partial copy, and there is nothing a designer can point to as 'what Uncoil can do with agent X'.

**Direction:** A single AgentDescriptor/capability record per agent consumed by both launch and Extensions code, with UI reading capability flags rather than `== .x`.

#### [HIGH] AP-03 — The two sources of truth for 'reports through hooks' disagree about Hermes: AgentProvider says no, AgentIntegration/HookupService/HermesHookInstaller say yes

*Category:* correctness

- `App/Core/Models.swift:134` — // Hermes has a hook system of the same shape … but Uncoil's hook bridge speaks Claude Code's wire format only. Until it speaks Hermes' too, claiming this would bind sessions to events that never arrive. case .codex, .ge
- `App/Extensions/AgentIntegration.swift:137` — case .hermes: // The one agent besides Claude Code with a real hook system … So the ceiling is `.hooks` and saying anything lower would understate the agent. … Self( ceiling: .hooks, isAutomatic: true, ceilingReason: nil
- `App/Hooks/HookEvent.swift:8` — Hermes writes a differently-shaped object and names the event only by which config key the command sits under, so the helper stamps the name (and the working directory, which Hermes does not send) before forwarding. Both
- `App/Core/ProjectStore.swift:929` — let live = notClosed.filter { status(of: $0.id).isKnownLive && $0.provider.reportsStatusThroughHooks }

**Why it matters:** The Installed Agents row tells the user Hermes is at 'Live events', while the session-binding code excludes Hermes sessions from the pool that unattributed hook events may land on (ProjectStore:929-931). Whether this is a real user-visible bug depends on Hermes always sending session_id on the first event (inferred: on_session_start carries it, so most events bind by id); regardless, it demonstrates that the capability booleans are not the source of truth the rest of the code believes they are.

**Direction:** One flag, one consumer path; derive the integration ceiling from the same record the launch code reads.

#### [HIGH] AP-04 — AgentWorkingMode is a 12-case global enum that mixes Claude, Codex, Grok, Cursor and Hermes vocabulary; users see per-provider subsets under shared labels whose meaning changes per provider

*Category:* concept-overload

- `App/Core/Models.swift:273` — enum AgentWorkingMode: String, Codable, CaseIterable, Identifiable { case providerDefault case auto case plan case manual case acceptEdits case dangerouslySkipPermissions case askForApproval case approveForMe case fullAc
- `App/Core/Models.swift:290` — case .claude: [.providerDefault, .manual, .acceptEdits, .plan, .auto, .dangerouslySkipPermissions] … case .codex: [.providerDefault, .readOnly, .askForApproval, .approveForMe, .fullAccess] … case .gemini: [.providerDefau
- `App/Core/Models.swift:404` — case (.claude, .auto): ["--permission-mode", "auto"] … case (.opencode, .auto): ["--auto"] … case (.cursor, .auto): ["--auto-review"] … case (.cursor, .dangerouslySkipPermissions): ["--force"] … case (.hermes, .dangerous
- `App/Core/Models.swift:466` — case (.claude, .dontAsk): .manual case (.codex, .onRequest): .askForApproval case (.codex, .auto): .approveForMe
- `App/Core/Models.swift:370` — case (.hermes, .dangerouslySkipPermissions): "Hermes runs without asking to approve dangerous commands." default: "The CLI starts with its own default behaviour."
- `App/UI/Onboarding/OnboardingToolSteps.swift:65` — private func modeDetail(for provider: AgentProvider) -> String { switch settings.workingMode(for: provider) { case .manual, .askForApproval: … case .auto, .approveForMe: … case .fullAccess, .dangerouslySkipPermissions:

**Why it matters:** 'Auto' is --permission-mode auto for Claude and Grok, --auto for OpenCode, --auto-review for Cursor (a different feature), and silently becomes 'Approve for Me' for Codex. 'Dangerously Skip Permissions' is --force for Cursor and --yolo for Hermes. For Grok, Cursor and OpenCode every non-default mode shows the detail 'The CLI starts with its own default behaviour.' because detail(for:) only covers Claude/Codex/Hermes. Onboarding has to re-group the 12 cases into 5 families to explain them (OnboardingToolSteps:65-82). `onRequest` is never offered anywhere. A user is asked to choose from an enum whose semantics are defined by two 2-D switches they cannot see.

**Direction:** Model working mode as a small ordered 'autonomy level' owned by the descriptor, with provider-specific flags and copy attached to the level rather than a shared enum.

#### [HIGH] AP-05 — Settings > Agents is seven pages, five of which are per-provider matrices that iterate AgentProvider.agents; Installed Agents and CLI Tools duplicate the Extensions Agents screen and the onboarding CLI step

*Category:* settings-sprawl

- `App/UI/Settings/SettingsView.swift:108` — case .installedAgents, .accounts, .cliTools, .launchArgs, .agentBehavior, .presets, .blueprints: .agents
- `App/UI/Settings/AgentSettingsPages.swift:13` — private let providers: [AgentProvider] = AgentProvider.agents  // AccountsSettingsPage
- `App/UI/Settings/AgentSettingsPages.swift:138` — private let providers: [AgentProvider] = AgentProvider.agents  // CLIToolsSettingsPage
- `App/UI/Settings/AgentSettingsPages.swift:388` — private let providers: [AgentProvider] = AgentProvider.agents  // LaunchArgumentsSettingsPage 'Run Parameters'
- `App/UI/Settings/AgentSettingsPages.swift:426` — private let providers: [AgentProvider] = AgentProvider.agents  // AgentBehaviorSettingsPage 'Working Mode'
- `App/UI/Settings/AgentSettingsPages.swift:465` — private let providers: [AgentProvider] = AgentProvider.agents  // InputSettingsPage Shift+Enter (under General)
- `App/UI/AgentHookupCard.swift:12` — Settings › Agents is where agents are managed; this card mirrors it rather than competing with it
- `App/UI/ExtensionsView.swift:803` — KeyValueRow(key: "Install path", value: installation.binaryPath) … KeyValueRow(key: "Binary version", value: installation.version ?? versions[installation.agent] ?? "not asked")
- `App/UI/Onboarding/OnboardingIntroSteps.swift:179` — detail: path.map { installedDetail(path: $0, version: version, provider: provider) } ?? String(localized: "No binary on this Mac's PATH. Install it, then rescan.")

**Why it matters:** Adding one provider adds a row to Accounts, CLI Tools, Run Parameters, Working Mode, Shift+Enter, Uncoil MCP 'Per Agent', Installed Agents, Extensions 'Connected agents', Onboarding CLIs, Onboarding Working modes, Quick Launch, the palette, and three context menus. The install path/version of an agent is shown on four surfaces (CLI Tools, Installed Agents version, Extensions card, Onboarding card) fed by two different detection paths (settings.resolvedBinaries via login shell vs AgentAdapterRegistry.detectInstallations). All matrices show every provider whether installed or not.

**Direction:** One 'per agent' page (or per-agent sheet) that groups an agent's install, account, mode, arguments and integration; global pages hold only global choices.

#### [HIGH] AP-06 — Claude hooks can be installed from four surfaces; two of them are Claude-only and unaware that Hermes has hooks, and the settings tree files 'Agent Status Hooks' under Uncoil while 'Installed Agents' under Agents performs the same action

*Category:* navigation

- `App/UI/Settings/PrivacySettingsPages.swift:346` — title: String(localized: "Agent Status Hooks"), subtitle: String(localized: "Claude Code's hooks are what make session states stream into Uncoil live.")
- `App/UI/Settings/SettingsView.swift:122` — case .permissions, .mcp, .hooks, .drivers, .github, .privacyData: .uncoil
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:4` — /// The hook install, which is Claude Code's mechanism and nobody else's.
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:76` — If you add Claude Code later, come back through “Finish setup” in the sidebar — or Settings › Uncoil › Agent Status Hooks.
- `App/UI/Settings/AgentsSettingsPage.swift:41` — action: { Task { await hookup.apply(to: state.agent) } }, disconnect: state.active == .hooks ? { Task { await hookup.disconnect(state.agent) } } : nil
- `App/Extensions/AgentHookupService.swift:178` — case (.hermes, .installHooks), (.hermes, .completeHooks): try HermesHookInstaller.install() … case (_, .installHooks), (_, .completeHooks): try HookInstaller.install()
- `App/UI/Settings/PrivacySettingsPages.swift:374` — case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"

**Why it matters:** A user who connects Hermes on Installed Agents and then opens Agent Status Hooks sees a page that only knows Claude. Onboarding tells Hermes users nothing and Codex users 'nothing to install' while the same step's title promises 'Let Uncoil see what your agents are doing'. The hooks page also leaks an untranslated Turkish string ('Eksik:') and raw event names.

**Direction:** Collapse to one 'connection' concept per agent surfaced in one place; drop the Claude-only page and make onboarding iterate agents that have a pending connect action.

#### [HIGH] AP-07 — Codex has a private structured-session subsystem hidden behind a launch flag, yet its concepts (approval requests, session-id discovery, second mode mapping) are wired into shared session, terminal and notification code

*Category:* agent-leak

- `App/Core/LaunchConfig.swift:80` — // The protocol client stays behind this flag rather than being deleted: it is what structured approvals and turn state are built on … codexAppServerEnabled = arguments.contains("-codex-app-server")
- `App/Terminal/TerminalHost.swift:154` — private func shouldUseCodexAppServer(record: SessionRecord, settings: SettingsStore) -> Bool { guard record.provider == .codex, LaunchConfig.shared.codexAppServerEnabled, settings.binaryPath(for: .codex) != nil else { re
- `App/Terminal/TerminalHost.swift:130` — if LaunchConfig.shared.codexApprovalFixture, record.provider == .codex { sessionStore?.setCodexApproval( CodexApprovalRequest(
- `App/Terminal/TerminalHost.swift:171` — guard record.provider == .codex, record.providerSessionID == nil || rediscovers else { return } … CodexSessionLocator.candidates(
- `App/Core/PermissionNotifications.swift:116` — title: String(localized: "Codex is waiting for approval"),
- `App/Tasks/AgentLaunchOptions.swift:191` — static func codexApproval( mode: AgentWorkingMode, config: String? ) -> (approvalPolicy: String, sandbox: String)
- `App/Extensions/CodexAdapter.swift:109` — message: String(localized: "Codex's TOML MCP config is outside the Bumblebee scan's reach.")

**Why it matters:** TerminalHost carries 14 `record.provider == .codex/.claude/...` checks; App/Codex is ~1,500 lines reachable only by a CLI flag; SessionStore has setCodexApproval, ProjectStore has claimProviderSessionID for Codex polling, PermissionNotifications posts a Codex-specific banner. The product surface is 'every agent is a terminal' but the code carries a half-shipped second runtime for one agent that shapes shared types (SessionRecord.providerSessionID discovery, CodexApprovalRequest in session status).

**Direction:** Either promote structured sessions to a declared per-agent capability with a UI switch, or quarantine the Codex runtime behind an adapter boundary so shared session/notification code does not name Codex.

#### [MEDIUM] AP-08 — Internal names shown to users: 'adapter', 'grants', preset id slug, 'Permission mode' free text, 'STDIO MCP', 'one symlink per skill', raw capability keys, raw hook event names

*Category:* terminology

- `App/UI/ExtensionsView.swift:972` — title: String(localized: "Agents not managed yet"), detail: String(localized: "Uncoil detects these but does not manage their configuration; each moves up once an adapter for its config format lands.") … KeyValueRow(key:
- `App/UI/ExtensionsView.swift:1173` — if capabilities.supportsPerSkillSymlinks { parts.append("one symlink per skill") } if capabilities.supportsStdioMCP { parts.append("STDIO MCP") } if capabilities.supportsHTTPMCP { parts.append("HTTP MCP") } if capabiliti
- `App/UI/Settings/AgentSettingsPages.swift:556` — Text("\(preset.id) · \(preset.provider.displayName) · \(preset.grantedCapabilities.count) grants")
- `App/UI/Settings/AgentSettingsPages.swift:658` — SettingsTextField( title: String(localized: "Permission mode"), prompt: "standard", text: $permissionMode, monospaced: true )
- `App/Core/SessionPreset.swift:20` — /// Permission mode label; reserved for future provider-specific mapping. var permissionMode: String
- `App/UI/Settings/AgentSettingsPages.swift:694` — SettingsLabel(title: capability.label, detail: capability.key)
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:47` — Text(HookInstaller.managedEvents.joined(separator: " · "))

**Why it matters:** The preset editor asks for a 'Permission mode' string that the model itself calls reserved; the dispatch sheet then tries to parse it as an AgentWorkingMode rawValue (TaskDispatchSheet.swift:468). 'Grants' and capability keys ('sessions.read') are the MCP policy engine's vocabulary. 'no adapter' and 'symlink' are implementation facts. These words define how users think about agents even though none map to a task they perform.

**Direction:** Rename or hide: presets as 'roles', grants as plain-language permissions, drop 'Permission mode' until it does something, replace capability summary with what the user can do here.

#### [MEDIUM] AP-09 — 'Profile' means three different things (AccountProfile, the unused AgentProfile struct, and the SessionPreset shown as 'Active profile'), and 'Default' account rows are auto-created for every provider

*Category:* duplicate-concept

- `App/Core/Models.swift:493` — struct AccountProfile: Identifiable, Codable, Equatable { let id: UUID var provider: AgentProvider var name: String var directoryName: String?
- `App/Extensions/ExtensionModels.swift:120` — struct AgentProfile: Identifiable, Equatable, Codable { let id: UUID var agent: ExtensionAgentID var name: String var configDirectory: String? var model: String? var workingMode: AgentWorkingMode? var isDefault: Bool
- `App/UI/ExtensionsView.swift:1014` — /// The preset Uncoil would launch this agent with. "Profile" is that preset plus the permission mode it carries. private func activeProfile(_ agent: ExtensionAgentID) -> String { … return "\(preset.name) · \(preset.gran
- `App/UI/TaskDispatchSheet.swift:226` — pickerRow(String(localized: "Profile")) { Picker("", selection: Binding( get: { request.accountID }
- `App/Core/SettingsStore.swift:781` — for provider in AgentProvider.agents where !accounts.contains(where: { $0.provider == provider && $0.directoryName == nil }) { accounts.append(AccountProfile(provider: provider, name: "Default", directoryName: nil)) }

**Why it matters:** In the dispatch sheet 'Profile' is an account; in the Extensions agent card 'Active profile' is a preset; AgentProfile has model/workingMode fields that nothing reads (grep finds no use outside its definition). The Accounts page always shows seven 'Default' rows even for agents the machine does not have.

**Direction:** Delete AgentProfile; pick one word for account and one for role/preset; only materialise a Default account for installed agents.

#### [MEDIUM] AP-10 — Accounts page offers 'Add an account' for Gemini and OpenCode although neither can be isolated; the directory is created and the session silently shares the default login

*Category:* visibility-logic

- `App/Core/Models.swift:524` — case .gemini: nil // No verified variable for an isolated Gemini config root, so Uncoil does not claim to isolate one: profiles for it would share the CLI's own home and quietly overwrite each other.
- `App/Core/Models.swift:529` — case .opencode: nil // `OPENCODE_CONFIG_DIR` looks like the variable for this and is not
- `App/UI/Settings/AgentSettingsPages.swift:46` — Button { addingFor = provider newAccountName = "" } label: { Label("Add an account", systemImage: "plus")
- `App/Core/SettingsStore.swift:359` — let profile = AccountProfile(provider: provider, name: name, directoryName: directoryName) if let dir = profile.configDirectory(profilesRoot: profilesRoot) { try? FileManager.default.createDirectory(
- `App/Terminal/TerminalHost.swift:225` — if let account, let key = account.isolationEnvironmentKey, let dir = account.configDirectory(profilesRoot: settings.profilesRootURL) { env.append("\(key)=\(dir.path)") }

**Why it matters:** The model knows the capability (isolationEnvironmentKey == nil) but no view reads it; the user gets a working-looking 'Work' Gemini account that is the same login as 'Personal'. This is exactly the kind of per-agent capability that a registry would let the Accounts UI gate on.

**Direction:** Gate the add-account affordance on the isolation capability and say why it is unavailable.

#### [MEDIUM] AP-11 — Model/effort/working-mode pickers appear only when hard-coded per-provider detection finds something; four of seven agents get no Model picker with no explanation, and the trio is copied into three sheets

*Category:* discoverability

- `App/Tasks/AgentLaunchOptions.swift:56` — case .claude: if helpText?.contains("--model") ?? false { result.models = [ Option(id: "fable", label: "Fable"), Option(id: "opus", label: "Opus"), Option(id: "sonnet", label: "Sonnet"), Option(id: "haiku", label: "Haiku
- `App/Tasks/AgentLaunchOptions.swift:88` — case .gemini: // Only what the installed build documents. No model list is hard-coded … break case .opencode: … break case .grok: … break case .cursor: … break
- `App/UI/TaskDispatchSheet.swift:240` — if !capabilities.models.isEmpty { pickerRow(String(localized: "Model")) {
- `App/UI/TaskOrchestratorSheet.swift:185` — if !capabilities.models.isEmpty {
- `App/UI/SessionHeaderBar.swift:345` — .task(id: record.provider) { guard record.provider.isAgent else { return } capabilities = await AgentLaunchCatalog.detect(

**Why it matters:** The presence or absence of a picker is the only signal the user gets; the reasons (documented at length in code comments) never reach the UI. Run Parameters becomes the workaround, but it is a global per-provider string, not per dispatch.

**Direction:** Expose 'model selection: not offered for X because …' from the same descriptor, and render the picker trio from one component.

#### [MEDIUM] AP-12 — Onboarding configures per-provider Working Mode and lists CLI cards for all seven providers regardless of what is installed, and asks about hooks only for Claude

*Category:* onboarding

- `App/UI/Onboarding/OnboardingToolSteps.swift:19` — private let providers: [AgentProvider] = AgentProvider.agents
- `App/UI/Onboarding/OnboardingToolSteps.swift:36` — ForEach(providers) { provider in OnboardingCard( leading: { ProviderMark(provider: provider, size: 18) }, title: provider.displayName, detail: modeDetail(for: provider)
- `App/UI/Onboarding/OnboardingIntroSteps.swift:121` — private let providers: [AgentProvider] = AgentProvider.agents
- `App/Core/OnboardingState.swift:11` — case clis case accounts case workingModes case hooks case notifications case capabilities case tools case project case tasks case extensions case palette case finish
- `App/Core/SettingsStore.swift:287` — var installedProviders: Set<AgentProvider> { Set(AgentProvider.agents.filter { resolvedBinaries[$0.rawValue] != nil }) }

**Why it matters:** A user with only Claude installed is asked to pick a working mode for Gemini, OpenCode, Grok, Hermes and Cursor (six of seven cards are irrelevant), while `installedProviders` already exists and is used by the launcher strip. Four of the twelve onboarding steps (clis, accounts, workingModes, hooks) are per-agent matrices.

**Direction:** Onboard per detected agent; move per-agent choices to the moment an agent is first launched.

#### [MEDIUM] AP-13 — Feature-visibility logic is scattered in views as direct provider comparisons and capability reads (isAgent ×5 in SessionHeaderBar, provider == .claude placeholder, extensionScoping special-case for OpenCode, loginCommand gating Sign In)

*Category:* visibility-logic

- `App/UI/SessionHeaderBar.swift:129` — if record.provider.isAgent, !accountChoices.isEmpty {
- `App/UI/SessionHeaderBar.swift:237` — if record.provider.isAgent { HStack(spacing: 7) { StatusOrb(status: status, size: 13)
- `App/UI/Settings/AgentSettingsPages.swift:397` — prompt: provider == .claude ? String(localized: "e.g. --model opus") : String(localized: "e.g. --full-auto"),
- `App/UI/ProjectExtensionPicker.swift:134` — return scope.filter { $0.provider?.extensionScoping == .mcpOnly && $0 != .opencode }
- `App/UI/Settings/AgentSettingsPages.swift:96` — if profile.provider.loginCommand != nil, email == nil { Button("Sign In") { showLogin = true }
- `App/UI/Settings/McpSettingsPage.swift:67` — detail: provider.wiresControlPlane ? String(localized: "Registered for every session Uncoil starts.") : String(localized: "No verified way to register a server per session yet, so Uncoil does not claim one
- `App/Terminal/RuntimeClient.swift:722` — if provider == .claude, String(decoding: buffer, as: UTF8.self).contains("manual mode on") {

**Why it matters:** Each view decides for itself what an agent can do; the OpenCode exception in the extension picker exists because `.mcpOnly` conflates 'has skills but cannot scope them' (Claude) with 'reads no skills' (OpenCode), so the view patches the model. The Run Parameters placeholder shows a Codex flag to Gemini/Grok/Hermes users.

**Direction:** Views should ask a descriptor 'can X?' with a reason, never compare against a case.

#### [MEDIUM] AP-14 — Claude-specific assumptions sit in shared infrastructure: hook wire format and event names, `~/.claude/local` in the global binary search path, 'permission' banner colour, and the CLIToolService doc comment

*Category:* agent-leak

- `App/Hooks/HookEvent.swift:14` — enum Kind: String { case sessionStart = "SessionStart" case userPromptSubmit = "UserPromptSubmit" case preToolUse = "PreToolUse" case postToolUse = "PostToolUse" case notification = "Notification" case stop = "Stop" case
- `App/Hooks/HermesHookInstaller.swift:30` — static let managedEvents: [(hermes: String, uncoil: String)] = [ ("on_session_start", "SessionStart"), ("pre_llm_call", "UserPromptSubmit"),
- `App/Core/BinarySearchPath.swift:33` — "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin",
- `App/Core/AttentionCenter.swift:81` — case .permission: Theme.claude
- `App/Core/CLIToolService.swift:3` — /// Version checks and updates for the agent CLIs (claude, codex).
- `App/Core/AgentCLIInstall.swift:266` — // Claude's own updater works wherever it was installed from. if provider == .claude { return .run("claude update") }

**Why it matters:** Uncoil's neutral 'session event' vocabulary is literally Claude Code's; every other agent is translated into it (HermesHookInstaller documents a mapping that would have been a bug if matched by name). The 'permission' attention colour is Claude orange for every provider. These are the seams where a second first-class agent will keep snagging.

**Direction:** Define Uncoil's own event kinds and treat Claude as one translation among several.

#### [MEDIUM] AP-15 — Usage chip and handoff are offered for all agents but work for three (usage) and two (handoff); the failure is discovered after the fact

*Category:* empty-state

- `App/Usage/UsageStore.swift:90` — func isSupported(_ provider: AgentProvider) -> Bool { providers[provider] != nil }
- `App/Usage/UsageStore.swift:127` — guard let provider = providers[key.provider] else { … reason: .providerUnsupported,
- `App/UI/SessionHeaderBar.swift:173` — if record.provider.isAgent { UsageChip( provider: record.provider,
- `App/Usage/HandoffProducer.swift:95` — guard canProduce(provider) else { return Result(failure: String(localized: "Uncoil cannot ask \(provider.displayName) for a handover.")) }
- `App/UI/HandoffSheet.swift:59` — installedProviders: Set(AgentProvider.agents.filter { provider in settings.binaryPath(for: provider) != nil

**Why it matters:** `isSupported` has no callers in the UI (grep), so a Grok or Hermes session header shows a usage chip whose only content is an 'unsupported' reason. Handoff destinations are computed from installed providers, not from providers that can produce/receive a handover.

**Direction:** Gate these affordances on a declared per-agent capability with a one-line reason.

#### [MEDIUM] AP-16 — Adding a 9th provider touches ~35 sites in ~25 files; roughly half are compile-enforced exhaustive switches, the rest are silent defaults, lists and if-chains that will simply omit the new agent

*Category:* other

- `App/Core/Models.swift:45` — 11 exhaustive switches on AgentProvider (displayName 45, color 59, launchCommand 73, loginCommand 87, isAgent 115, reportsStatusThroughHooks 131, wiresControlPlane 160, extensionScoping 194, hasBuiltInUpdater 221, resume
- `App/Extensions/ExtensionModels.swift:20` — 4 exhaustive switches on ExtensionAgentID (displayName 20, provider 33, cliBinaryName 51, defaultConfigDirectory 67) + supported list 89
- `App/Theme/ProviderGlyph.swift:30` — brandColor 30, AgentMark.mark 70 ('a new case added without one fails this switch to compile'), ProviderMark.mark 105
- `App/Core/AgentCLIInstall.swift:52` — brewFormula 52, npmPackage 68, native updater 255 (exhaustive); source() path sniffing 145-171 (silent)
- `App/Tasks/AgentLaunchOptions.swift:56` — capabilities(for:) 56-123 and launchArguments 226-258 (exhaustive)
- `App/Terminal/TerminalHost.swift:968` — resume flag if-chain 968-990 (silent), resumeDecision default .unknown 368-382 (silent), environment() OpenCode branch 241 (silent)
- `App/Theme/ThemeStore.swift:56` — palette field 56-66, default palettes 108-123, swatches 400-414 (silent) + Assets.xcassets ProviderMark* imageset
- `App/Extensions/AgentAdapterRegistry.swift:12` — self.adapters = adapters ?? [ClaudeCodeAdapter(), CodexAdapter()] + JSONMCPConfigLayout.all.map { JSONMCPAdapter(layout: $0) } + [OpenCodeAdapter(), GrokAdapter(), HermesAdapter()]
- `App/UI/Settings/SettingsView.swift:193` — case .installedAgents: "agent ajan bağla connect hook kanca algıla detect tara scan claude codex gemini cursor amp opencode grok hermes …"
- `App/Core/Models.swift:329` — AgentWorkingMode.label 329 / detail 346 / launchArguments 400 / normalized 466 fall to `default` (silent)

**Why it matters:** Full list a 9th provider must visit: Models.swift (14 switches), ExtensionModels.swift (5), AgentLaunchOptions.swift (2), AgentCLIInstall.swift (3 + path sniffing), AgentUpdateAvailability.swift versionSource special cases, ProviderGlyph.swift (3), Theme.swift + ThemeStore.swift (palette field/defaults/swatches), Assets.xcassets (mark), AppearanceSettingsPage.swift (colour row), AgentAdapterRegistry.swift + a new adapter or JSONMCPConfigLayout entry, AgentIntegration.swift forAgent, AgentHookupService.swift performScan switch (+ a hook installer if it has hooks), TerminalHost.swift (resume flags, resume store, env, MCP flags), AgentResume.swift (store), HandoffProducer.swift canProduce/switch, UsageStore.swift + a *UsageProvider + UsageSource cases, SettingsStore.swift loggedInEmail, OnboardingIntroSteps.swift installPage, SettingsView.swift keywords, ProjectExtensionPicker.swift special-case, HookEvent.swift if its payload differs, docs/current/extensions/PROJECT_SCOPE.md matrix, and the tests that pin each boolean (e.g. Tests/GrokAdapterTests.swift:104). Nothing tells a contributor which of these are mandatory.

**Direction:** A single registration point (descriptor + adapter) from which colour, marks, launch, update, scoping, hooks and usage are all derived or explicitly declared absent.

#### [LOW] AP-17 — Session titles and accessibility values use provider.rawValue ('claude: new session', 'codex: past task') while every other surface uses displayName

*Category:* terminology

- `App/UI/MainWindow.swift:492` — title: provider == .terminal ? "terminal" : String(localized: "\(provider.rawValue): new session")
- `App/UI/SidebarView.swift:739` — : String(localized: "\(provider.rawValue): new session"),
- `App/UI/ProjectTasksView.swift:1270` — title: String(localized: "\(request.provider.rawValue): \(task.displayText)"),
- `App/UI/BlueprintCards.swift:29` — title: String(localized: "\(provider.rawValue): \(blueprint.name)")
- `App/Core/LaunchConfig.swift:205` — title: "codex: past task"

**Why it matters:** Internal identifiers become the user's session names; renaming a case would rename every session title.

**Direction:** Title from displayName (or no prefix, with the mark carrying identity).

#### [LOW] AP-18 — Terminal is modelled as a provider, so every capability switch and list carries a terminal arm and every 'agents' list must filter it

*Category:* concept-overload

- `App/Core/Models.swift:37` — static let agents: [AgentProvider] = allCases.filter(\.isAgent) /// The agents plus the plain shell: what a "new session" chooser offers. static let sessionKinds: [AgentProvider] = allCases
- `App/Core/Models.swift:110` — /// The distinction was made ad hoc — twenty-odd `provider == .terminal` comparisons, each deciding for itself — and the places that forgot it are what put "Claude is waiting for your input" and an MCP badge on a plain t
- `App/UI/MainWindow.swift:491` — accountID: provider == .terminal ? nil : account?.id,
- `App/UI/ProjectExtensionPicker.swift:325` — settings.launcherProviders .filter { $0 != .terminal } .compactMap(\.extensionAgent)

**Why it matters:** The plain shell inherits fields it cannot use (accountID, launchSelection, working mode) and every provider-keyed API has to answer for it; the comment records the bugs this caused.

**Direction:** Session kind (agent | shell) orthogonal to agent identity.

#### [LOW] AP-19 — Half-built or dead per-agent fields: AgentInstallation.version is never populated by any adapter, AgentProfile is unused, SessionPreset.permissionMode is 'reserved', AgentWorkingMode.onRequest is never offered

*Category:* other

- `App/Extensions/ClaudeCodeAdapter.swift:39` — version: nil, isAuthenticated: nil,
- `App/Extensions/HermesAdapter.swift:71` — version: nil,
- `App/UI/ExtensionsView.swift:806` — value: installation.version ?? versions[installation.agent] ?? "not asked"
- `App/Core/SessionPreset.swift:20` — /// Permission mode label; reserved for future provider-specific mapping.
- `App/Core/Models.swift:468` — case (.codex, .onRequest): .askForApproval

**Why it matters:** Each is a concept a reader (or a UI) can reach that does nothing, adding to the sense that agent configuration is larger than it is.

**Direction:** Remove or finish.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Settings > Agents > Installed Agents | screen | `App/UI/Settings/AgentsSettingsPage.swift` | Settings sidebar category Agents (SettingsView.swift:76,108); Onboarding hooks step copy points here ('Settings › Uncoil › Agent Status Hooks' actually points to a different page: OnboardingPlatformSt |
| Settings > Agents > Accounts | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > Agents (SettingsView.swift:77); Session header account menu (SessionHeaderBar.swift:129) |
| Settings > Agents > CLI Tools | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > Agents (SettingsView.swift:78); Sidebar pending-updates badge (SidebarView.swift:24 settings.pendingCLIUpdates) |
| Settings > Agents > Run Parameters | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > Agents (SettingsView.swift:79) |
| Settings > Agents > Working Mode | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > Agents (SettingsView.swift:80); Onboarding 'Working modes' step (same setting) |
| Settings > General > Keyboard and Input (Shift+Enter section) | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > General (SettingsView.swift:74,107) |
| Settings > Agents > Session Presets (+ editor sheet) | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings > Agents (SettingsView.swift:81); Task dispatch sheet preset picker (TaskDispatchSheet.swift:458-471); MCP list_presets (HelpRegistry.swift:87) |
| Settings > General > Default agent | row | `App/UI/Settings/GeneralSettingsPage.swift` | Settings > General |
| Settings > Uncoil > Agent Status Hooks | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings > Uncoil (SettingsView.swift:96,122); Onboarding hooks step copy (OnboardingPlatformSteps.swift:76) |
| Settings > Uncoil > Uncoil MCP > Per Agent | screen | `App/UI/Settings/McpSettingsPage.swift` | Settings > Uncoil (SettingsView.swift:95) |
| Settings > Appearance > Theme and Colours > Providers | screen | `App/UI/Settings/AppearanceSettingsPage.swift` | Settings > Appearance |
| Settings > Appearance > Quick Launch | screen | `App/UI/Settings/LauncherSettingsPage.swift` | Settings > Appearance (SettingsView.swift:92,113) |
| Extensions window > Agents screen | screen | `App/UI/ExtensionsView.swift` | Extensions window section .agents (ExtensionsView.swift:7); -route extensions -extensions-section agents |
| Onboarding > Agent CLIs | screen | `App/UI/Onboarding/OnboardingIntroSteps.swift` | First run; 'Finish setup' in sidebar; -route onboarding -onboarding-step clis |
| Onboarding > Accounts | screen | `App/UI/Onboarding/OnboardingIntroSteps.swift` | Onboarding step .accounts |
| Onboarding > Working modes | screen | `App/UI/Onboarding/OnboardingToolSteps.swift` | Onboarding step .workingModes (OnboardingState.swift:13) |
| Onboarding > Status tracking (hooks) | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | Onboarding step .hooks (OnboardingState.swift:14 'Status tracking') |
| Session header bar | toolbar | `App/UI/SessionHeaderBar.swift` | Any open session |
| Task dispatch sheet | sheet | `App/UI/TaskDispatchSheet.swift` | Tasks board 'Send to agent' |
| Task orchestrator sheet | sheet | `App/UI/TaskOrchestratorSheet.swift` | Tasks board orchestrate |
| Project tasks context menus | menu | `App/UI/ProjectTasksView.swift` | Right-click a task card |
| Command palette provider commands | panel | `App/Core/PaletteModel.swift` | ⌘K |
| Sidebar quick-launch strip | toolbar | `App/UI/SidebarView.swift` | Project screen |
| Menu bar monitor new-session menu | menu | `App/UI/MenuBarMonitorView.swift` | Menu bar extra |
| Project extension picker (agent tabs) | sheet | `App/UI/ProjectExtensionPicker.swift` | Project customize / 'What this project loads' |
| Handoff sheet | sheet | `App/UI/HandoffSheet.swift` | Session header usage alert / hand over |
| Login terminal sheet | sheet | `App/UI/LoginTerminalSheet.swift` | Accounts page Sign In; Onboarding accounts |
| Codex approval banner / structured session | banner | `App/Core/PermissionNotifications.swift` | Codex app-server sessions (hidden feature) |

### Concepts

- `U!` **AgentProvider** — Session-launch identity: claude, codex, gemini, opencode, grok, hermes, cursor, terminal. Carries displayName, color, launchCommand, loginCommand and eleven capability switches (isAgent, reportsStatusThroughHooks, wiresControlPlane, extensionScoping, hasBuiltInUpdater, resumesConversation, defaultShiftEnterNewline) — App/Core/Models.swift:20-271. *Overlaps:* ExtensionAgentID, SessionPreset.provider, UsageKey.provider
- `U` **ExtensionAgentID** — Extensions-system identity: claudeCode, codex, geminiCLI, cursor, amp, opencode, grok, hermes. Has its own displayName ('Claude Code', 'Gemini CLI', 'Grok CLI' vs AgentProvider's 'Claude', 'Gemini', 'Grok'), cliBinaryName, defaultConfigDirectory, and a hand-written `provider` map with `extensionAgent` as its reverse — ExtensionModels.swift:8-95, 168-178. *Overlaps:* AgentProvider, AgentInstallation, AgentIntegrationState
- `U` **AgentWorkingMode** — 12-case global enum (providerDefault, auto, plan, manual, acceptEdits, dangerouslySkipPermissions, askForApproval, approveForMe, fullAccess, dontAsk, onRequest, readOnly) whose per-provider subset, labels, launch flags and cross-provider normalization all live as switches on it — Models.swift:273-479. `onRequest` is never offered to anyone (only appears in normalized(for: .codex), line 468). *Overlaps:* SessionPreset.permissionMode, ProviderBehavior.workingMode, AgentLaunchSelection.workingMode, Codex approvalPolicy/sandbox pair
- `i` **ProviderBehavior** — Per-provider stored overrides {shiftEnterNewline?, workingMode?} keyed by provider.rawValue in settings.json — Models.swift:483-489, SettingsStore.swift:96. *Overlaps:* AgentLaunchSelection, SettingsStore.extraArguments
- `U` **AccountProfile** — An isolated config root per provider ('Work', 'Personal'), pointed at via isolationEnvironmentKey (CLAUDE_CONFIG_DIR / CODEX_HOME / GROK_HOME / CURSOR_CONFIG_DIR / HERMES_HOME; nil for gemini, opencode, terminal) — Models.swift:493-539. *Overlaps:* AgentProfile (dead), SessionPreset ('Active profile' in Extensions card)
- `i` **AgentProfile** — A second 'profile' struct (agent, name, configDirectory, model, workingMode, isDefault) in ExtensionModels.swift:120-146 that is referenced nowhere else in App or Tests (grep returns only its definition). *Overlaps:* AccountProfile, SessionPreset
- `U!` **SessionPreset** — Named launch template {id slug, name, provider, extraArguments, initialPromptTemplate, grantedCapabilities, permissionMode:'standard'} used both for MCP create_child and as a user-editable Settings object — App/Core/SessionPreset.swift:9-40. `permissionMode` is documented as 'reserved for future provider-specific mapping' (line 21) yet is an editable free-text field. *Overlaps:* AccountProfile, AgentWorkingMode (permissionMode string is parsed as its rawValue, TaskDispatchSheet.swift:468), AgentLaunchSelection
- `U` **AgentLaunchSelection / AgentLaunchCapabilities / AgentLaunchCatalog** — Per-dispatch model/effort/mode choice, the per-provider detection of which pickers to show (hard-coded Claude model list incl. 'fable'; Codex reads ~/.codex/config.toml; Hermes parses --help; Gemini/OpenCode/Grok/Cursor offer nothing), and the flag composition per provider — App/Tasks/AgentLaunchOptions.swift:6-42, 49-125, 218-267. *Overlaps:* AgentWorkingMode, ProviderBehavior, extraArguments
- `U!` **AgentIntegrationLevel / AgentIntegrationSupport / AgentIntegrationState** — A 4-level ladder (none/observed/controlPlane/hooks) with user labels 'Detected only' / 'Terminal only' / 'Control plane' / 'Live events', a per-agent hand-written ceiling table with prose reasons, and derived state with pendingAction — App/Extensions/AgentIntegration.swift:10-49, 63-155, 160-330. *Overlaps:* AgentProvider.wiresControlPlane, AgentProvider.reportsStatusThroughHooks, HookInstaller.Status
- `i!` **AgentAdapter / AgentAdapterRegistry / JSONMCPConfigLayout** — Per-agent config read/plan/apply implementation (ClaudeCodeAdapter, CodexAdapter, OpenCodeAdapter, GrokAdapter, HermesAdapter, JSONMCPAdapter×3 for Gemini/Cursor/Amp) — App/Extensions/AgentAdapter.swift:70-100, AgentAdapterRegistry.swift:10-14. *Overlaps:* AgentProviderCapabilities, AgentInstallation
- `U!` **AgentProviderCapabilities** — Eight booleans per adapter (readsSkillsFromDirectory, supportsPerSkillSymlinks, supportsStdioMCP, supportsHTTPMCP, supportsProjectScopedMCP, reloadsConfigWithoutRestart, preservesUnknownConfigKeys, reportsAuthenticationState) — ExtensionModels.swift:152-165. *Overlaps:* AgentProvider.extensionScoping (a different 'scoping' concept on the other enum)
- `U` **ExtensionScopingSupport** — strict / mcpOnly / none: how far a project's extension selection can be enforced per provider — Models.swift:8-18, 194-210. *Overlaps:* AgentProviderCapabilities.supportsProjectScopedMCP, wiresControlPlane
- `U` **AgentInstallSource / AgentUpdatePlan / AgentUpdateAvailability / AgentVersionSource** — How a CLI was installed (homebrew/npm/volta/nativeInstaller/unknown), the exact update command, and the row state (unchecked/notInstalled/upToDate/available/selfChecking/noUpdater) — App/Core/AgentCLIInstall.swift, AgentUpdateAvailability.swift. *Overlaps:* AgentProvider.hasBuiltInUpdater, ExtensionsView 'Update status' (which is about extensions, not the CLI — 1027-1039)
- `U!` **Hooks (HookInstaller / HermesHookInstaller / HookEvent)** — Claude Code's settings.json hook entries (and a translated equivalent for Hermes config.yaml) that stream session events to a Unix socket. Wire format and HookEvent.Kind names are Claude Code's — App/Hooks/HookEvent.swift:14-22, HookInstaller.swift:11-15, HermesHookInstaller.swift:30-44. *Overlaps:* AgentIntegrationLevel.hooks, AgentProvider.reportsStatusThroughHooks
- `U!` **Control plane wiring ('wired' / 'not wired')** — Whether Uncoil registers its MCP server for a provider's sessions: Claude via --mcp-config file, Codex via -c overrides, OpenCode via OPENCODE_CONFIG_CONTENT env — Models.swift:160-183, TerminalHost.swift:232-249, 992-1035. *Overlaps:* AgentIntegrationLevel.controlPlane, ExtensionScopingSupport
- `i` **Codex app-server structured session** — A Codex-only alternative session runtime (App/Codex: CodexAppServerSession 761 lines, CodexUnixWebSocket, PromptLineEditor, CodexAppServerProtocol; CodexApprovalRequest; CodexSessionLocator) gated by the `-codex-app-server` launch argument — LaunchConfig.swift:80-89, TerminalHost.swift:154-160, 524-570. *Overlaps:* AgentWorkingMode (needs a second mapping codexApproval, AgentLaunchOptions.swift:191-211), Terminal PTY session
- `U` **Run Parameters (extraArguments)** — Per-provider free-text CLI argument string stored as extraArguments[provider.rawValue] — SettingsStore.swift:90; appended last in TerminalHost.launchCommand (1050-1052). Setting it for Codex silently disables the app-server path (TerminalHost.swift:158-160). *Overlaps:* SessionPreset.extraArguments (presetArguments), AgentLaunchSelection (model/effort flags), ProviderBehavior.workingMode (mode flags)
- `U` **Quick Launch strip (LauncherPrefs / launcherProviders)** — Ordered subset of sessionKinds shown as launch buttons; also used to decide which agent tabs the project extension picker shows — LauncherPrefs.swift:29-47, ProjectExtensionPicker.swift:323-327. *Overlaps:* Default agent, installedProviders
- `U` **Terminal-as-provider** — `AgentProvider.terminal` is a case of the same enum as the agents, so every capability switch carries a `.terminal` arm and every agent list must filter it out (`agents` vs `sessionKinds`, Models.swift:37-41; `isAgent` comment admits twenty-odd `== .terminal` comparisons, 110-121). *Overlaps:* AgentProvider

### Flows

- **Start a new agent session from the sidebar strip** (7 steps) — friction: Five separate provider-keyed decision points (env, mcp path, resume store, resume flag chain, mcp flags) plus four argument sources (selection, mode, preset, extra) composed in one string; a user has no single place that tells them what a given provider's session will actually be launched with. Gemini sessions get no control plane, no resume, no hooks, no models, no usage — and nothing in the launch flow says so.
- **Connect an agent's status hooks** (6 steps) — friction: Four surfaces for one action; two of them (A, B) are Claude-only and unaware of Hermes; the Settings tree places 'Agent Status Hooks' under Uncoil while 'Installed Agents' under Agents does the same thing with more agents. The onboarding step's fallback copy sends the user to the Claude-only page.
- **Choose how much an agent does on its own (working mode)** (7 steps) — friction: The same choice is asked at four altitudes (onboarding, settings, dispatch, preset) with three different vocabularies (mode enum, capability-filtered list, free-text 'permission mode'). Labels are shared across providers while meaning differs ('Auto' = --permission-mode auto for Claude/Grok, --auto for OpenCode, --auto-review for Cursor, and becomes 'Approve for Me' for Codex; 'Dangerously Skip Permissions' = --force for Cursor, --yolo for Hermes). Detail sentences exist only for Claude/Codex/Hermes.
- **Update an agent CLI** (5 steps) — friction: Well-reasoned but entirely provider-hard-coded in three switches plus five `provider == .x` checks; `hasBuiltInUpdater` on AgentProvider is a fourth partial copy of the same fact (Models.swift:221-227). The Extensions > Agents card has a 'Update status' row that is about extensions, not the CLI, under the same agent heading.
- **Add a second account for a provider** (3 steps) — friction: A user can create 'Work' and 'Personal' Gemini or OpenCode accounts that silently share one login; no surface reads isolationEnvironmentKey to hide or explain the button.
- **Scope what a project's agents load (MCP servers / skills)** (5 steps) — friction: Scoping ability is a per-provider fact on AgentProvider while the UI is keyed by ExtensionAgentID, so the view has to hop the mapping and then special-case OpenCode inline. The picker offers tabs for agents that cannot be scoped at all.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| defaultProvider | global | settings.json (SettingsStore.swift:83) | Settings > General 'Default agent' (GeneralSettingsPage.swift:12-25); Onboarding Agent CLIs (OnboardingIntroSteps.swift:148-160) | yes |
| extraArguments[provider] | global | settings.json (SettingsStore.swift:90) | Settings > Agents > Run Parameters (AgentSettingsPages.swift:386-414) |  |
| providerBehaviors[provider].workingMode | global | settings.json (SettingsStore.swift:96, Models.swift:483-489) | Settings > Agents > Working Mode; Onboarding Working modes; overridden per session by record.launchSelection.workingMode |  |
| providerBehaviors[provider].shiftEnterNewline | global | settings.json | Settings > General > Keyboard and Input (AgentSettingsPages.swift:486-503) | yes |
| accounts / defaultAccountByProvider | account | settings.json + profiles/<provider>/<slug> directories (SettingsStore.swift:84, 353-367) | Settings > Agents > Accounts; Onboarding Accounts; Session header account menu; Dispatch sheet 'Profile' |  |
| agentBinaryLocations[command] | global | settings.json (SettingsStore.swift:88) mirrored into BinarySearchPath box | Installed Agents 'Locate…' and Extensions 'Connected agents' card (AgentLocationPicker) | yes |
| presets (SessionPreset) | global | settings.json (SettingsStore.swift:93, 171-177) | Settings > Agents > Session Presets editor |  |
| launcher.order (LauncherPrefs) | global | settings.json | Settings > Appearance > Quick Launch | yes |
| palette.claude / palette.codex (+ hidden gemini/opencode/grok/cursor/amp) | global | ThemePalette (ThemeStore.swift:56-66) | Settings > Appearance > Theme and Colours > Providers (only Claude and Codex rows, AppearanceSettingsPage.swift:64-67) | yes |
| record.launchSelection (model/effort/mode) | session | SessionRecord (Models.swift:771) | TaskDispatchSheet, TaskOrchestratorSheet, ProjectTasksView plan sheet |  |
| record.extraArguments (from preset) | session | SessionRecord (Models.swift:768) | Preset editor 'CLI arguments' |  |
| Claude hooks in ~/.claude/settings.json | integration | user's Claude settings file (HookInstaller.swift:40-43) | Onboarding Status tracking; Settings > Uncoil > Agent Status Hooks; Settings > Agents > Installed Agents; Extensions > Agents card | yes |
| Hermes hooks in ~/.hermes/config.yaml | integration | user's Hermes config (HermesHookInstaller.swift) | Installed Agents / Extensions card only | yes |
| codexAppServerEnabled | session | launch argument only (LaunchConfig.swift:87) | Command line `-codex-app-server` |  |
| usageWarningThreshold | global | settings.json | Notifications settings |  |

### Visibility gates

- `App/UI/SessionHeaderBar.swift:66,129,173,237,346; App/UI/SidebarView.swift:718; App/Core/ProjectStore.swift:915; App/Usage/UsageAttention.swift:51; App/Core/SessionExit.swift:38-40` — record.provider.isAgent → Account menu, usage chip and alert, status orb, launch-capability detection, launcher account submenu, hook-session pool, exit classification.
- `App/UI/Settings/AgentSettingsPages.swift:96` — provider.loginCommand != nil && email == nil → 'Sign In' button on an account row (hidden for Gemini).
- `App/UI/Settings/AgentSettingsPages.swift:397` — provider == .claude → Placeholder text of the Run Parameters field ('e.g. --model opus' vs 'e.g. --full-auto').
- `App/UI/Settings/McpSettingsPage.swift:67-77; App/Terminal/TerminalHost.swift:232,400; App/Extensions/AgentHookupService.swift:153; App/Extensions/AgentIntegration.swift:315` — provider.wiresControlPlane → 'wired'/'not wired' rows; UNCOIL_* env; MCP binary path; skipping config parsing; control-plane integration level.
- `App/Core/ProjectStore.swift:930` — provider.reportsStatusThroughHooks → Which live sessions may be guessed as the target of an unattributed hook event (Claude only — Hermes excluded despite having hooks).
- `App/Core/SessionSleep.swift:79-82; App/Core/AgentResume.swift:69-72` — provider.resumesConversation && providerSessionID non-empty → Hibernate action; whether a resume flag is even considered.
- `App/UI/ProjectExtensionPicker.swift:132-135` — provider.extensionScoping == .mcpOnly && agent != .opencode → 'not scoped for <agent>' skills warning in the project extension picker.
- `App/UI/Settings/AgentsSettingsPage.swift:42-44` — state.active == .hooks → Disconnect button on an Installed Agents row.
- `App/Extensions/AgentHookupService.swift:100-121, 214` — agent == .claudeCode || agent == .hermes → Whether an agent is evaluated as hook-capable and whether disconnect does anything.
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:22-23, 37, 80` — hasClaude / hasCodex (settings.binaryPath(for:) != nil) → Which cards the onboarding hooks step shows; the other five providers are never mentioned.
- `App/UI/TaskDispatchSheet.swift:240,256; App/UI/TaskOrchestratorSheet.swift:185,199` — !capabilities.models.isEmpty / !capabilities.efforts.isEmpty → Model and Effort pickers (present for Claude, Codex, Hermes-effort only).
- `App/Terminal/TerminalHost.swift:154-160` — record.provider == .codex && LaunchConfig.shared.codexAppServerEnabled && binaryPath != nil && no extra arguments → Whether a Codex session runs as a structured app-server session instead of the CLI TUI.
- `App/Terminal/RuntimeClient.swift:722-723` — provider == .claude && buffer contains 'manual mode on' → Input-ready detection shortcut when typing text into a session.
- `App/Usage/HandoffProducer.swift:40-42, 95-96` — HandoffProducer.canProduce(provider) == (provider == .claude || provider == .codex) → Whether a handover can be produced; other providers fail with 'Uncoil cannot ask <X> for a handover.'
- `App/Usage/UsageStore.swift:60-64, 127-133` — UsageStore.providers[provider] != nil (Codex, Claude, Gemini only) → Whether the usage chip shows numbers or a `providerUnsupported` reason; `isSupported` is never called from the UI so the chip is rendered for all agents (inferred from SessionHeaderBar.swift:173 and grep).
- `App/Core/LauncherPrefs.swift:33-35, 41` — provider.isAgent || installed.contains(provider) → Which providers the default Quick Launch strip shows.
- `App/UI/ExtensionsView.swift:822-824` — installation.isAuthenticated == false → Warning tint on 'Login status' row; value is only ever set by Codex/OpenCode/Grok/Hermes adapters (Claude/JSON adapters pass nil).
- `App/UI/Settings/AgentSettingsPages.swift:102` — profile.directoryName != nil → Delete button on an account row (the auto-created 'Default' cannot be deleted).

### Open questions

- Is Amp meant to remain a config-only agent forever, or is the plan for every ExtensionAgentID to become launchable? If the former, is 'Installed Agents' (which lists Amp beside launchable agents) the right home for it?
- Is the Codex app-server runtime (App/Codex) a planned product feature (structured approvals in the UI) or a retained experiment? The answer decides whether 'structured session' should become a declared capability or be removed from shared code.
- Hermes: `reportsStatusThroughHooks` is false while the hook bridge, installer and integration table treat it as hook-capable. Which is the intended truth, and does ProjectStore.swift:929's filter need Hermes? (Not verified at runtime.)
- Should Shift+Enter newline really be a user setting per provider, or a fixed fact of each CLI's TUI (verified once per provider) that the user never sees?
- Is 'Run Parameters' (global per-provider free text) still needed once model/effort/mode are structured per dispatch, given it silently disables the Codex app-server path?
- Does the product intend one word for AccountProfile ('account' vs 'profile') and one for SessionPreset ('preset' vs 'profile' vs 'role')?
- Should the Quick Launch strip continue to double as the source of the project extension picker's agent tabs (ProjectExtensionPicker.swift:323-327)?
- Are the AgentWorkingMode labels meant to be provider-neutral (an autonomy ladder) or provider-faithful (each CLI's own names)? The current enum is neither.

---

## Status, attention, notifications and the menu bar

From the user's chair this subsystem is "how do I know an agent needs me, and where do I look". The answer today is five overlapping places that each derive "needs you" from a different model: (1) a 10-case session status (AgentSessionStatus) drawn as an animated orb in the sidebar, session header, dashboard, group view, pop-out title bar and command palette; (2) an Attention Center popover behind a 20pt bell on the sidebar rail, listing rows of 18 AttentionKinds derived from status + Codex auth + git conflicts + daemon phase + a 20-second task scan + usage figures + ad-hoc "reported" rows from tests, runs, crashes, artifacts and task assignment; (3) a sidebar row pulse driven by a separate SessionStore.unseenAttention set that is only written when a macOS banner actually got sent; (4) a menu-bar status item with a 3-state icon, up to four cryptic counters ("3 2! 1×"), and a drop-down that mixes task orchestration, attention rows, interrupt and quick-launch; (5) macOS banners governed by 7 NotificationEvents with a priority/sound matrix resolved event → project → global, plus reminders, quiet hours and three delivery filters — but posted through two different pipelines (NotificationPolicy for hooks/attention rows, a policy-free PermissionNotificationCenter for control-plane and Codex approvals). Configuring all of this is spread over five Settings > Notifications panes, Appearance > Menu Bar, Appearance > Theme > Attention (sidebar pulse), General > Provider Limits, Settings > Uncoil > Agent Status Hooks, and two onboarding steps — roughly sixty controls, several of which cannot take effect because the wiring never delivers the event they configure.

### Findings

#### [CRITICAL] ATT-01 — Four unaligned vocabularies say 'the agent needs you': 10 statuses, 18 attention kinds, 7 notification events, 12 task states

*Category:* concept-overload

- `App/Core/Models.swift:610` — enum AgentSessionStatus: String, Codable { … case waitingForInput … var label … "Waiting for a reply"
- `App/Core/AttentionCenter.swift:4` — enum AttentionKind: String, CaseIterable … case permission, input, testFailure, mergeConflict, authentication, runtime, completed, taskAssigned, reviewRequested, changesRequested, taskBlocked, taskFailed, taskCompleted, 
- `App/Core/NotificationPrefs.swift:10` — enum NotificationEvent … case permission, input, turnCompleted, problem, taskCompleted, mergeReady, loginRequired … "Waiting for input"
- `App/Tasks/ProjectTaskModels.swift:189` — enum ProjectTaskExecutionState … case waitingForUser … "Waiting for you"
- `App/Core/MenuBarMonitor.swift:68` — parts.append("\(waitingInput) waiting for a reply")
- `App/Core/MenuBarPrefs.swift:61` — case .waiting: String(localized: "Pending")
- `App/Hooks/SessionStore+Hooks.swift:100` — body: String(localized: "Waiting for input · \(sessionTitle)")

**Why it matters:** One state — 'the agent asked me something' — is labelled 'Waiting for a reply', 'Waiting for input', 'Waiting for you', 'Pending' and 'waiting for a reply' across the header, panel, banner, task board and menu bar. Each enum has its own colour, priority and predicate switch, so no surface can be reasoned about from another and every new feature has to be added to all four.

**Direction:** Collapse to one 'signal' model (a small set of user-meaningful states with one label, colour and urgency each) that status, rows, banners and counts all project from.

#### [CRITICAL] ATT-02 — Notification settings promise events the wiring can never deliver: taskCompleted, mergeReady, and most 'problems' never fire; two of four reminders are inert

*Category:* visibility-logic

- `App/UI/MainWindow.swift:908` — guard let event = item.kind.notificationEvent, let projectID = item.projectID, let sessionID = item.sessionID else { continue }
- `App/Tasks/TaskAttention.swift:128` — if task.isDone { items.append(item(.taskCompleted, task: task, title: title, detail: …, now: now)) }  // no sessionID
- `App/Tasks/TaskAttention.swift:138` — if let blockers = task.mergeBlockers, blockers.isEmpty, !task.assignments.isEmpty { items.append(item(.mergeReady, …)) }  // no sessionID
- `App/Core/TestRegistry.swift:132` — AttentionStore.shared.report(kind: .testFailure, … projectID: project.id, sessionID: nil,
- `App/Core/NotificationPrefs.swift:38` — case .problem: String(localized: "A runtime error, a failing test or a dropped connection.")
- `App/Hooks/SessionStore+Hooks.swift:250` — static func status(matching event: NotificationEvent) -> AgentSessionStatus? { switch event { case .permission: .waitingForPermission; case .input: .waitingForInput; default: nil } }
- `App/Hooks/SessionStore+Hooks.swift:227` — guard Self.status(matching: entry.event) == status(of: entry.sessionID) else { notificationLedger.clear(…); continue }
- `App/Core/NotificationPrefs.swift:62` — case .permission, .input, .loginRequired, .mergeReady: true  // supportsReminder

**Why it matters:** The Events pane offers on/off, priority, sound and remind for 'Task done' and 'Ready to merge', and the Reminders pane lists 'Login needed' and 'Ready to merge', yet none of these can ever produce a banner or a reminder. Suite failures, run failures, merge conflicts and daemon failures are documented under 'Errors and problems' but are filtered out because they carry no session id. Users will tune controls, see nothing, and lose trust in the whole pane.

**Direction:** Either give every attention row a route target that satisfies the bridge or drop the per-event matrix to the events that actually flow; verify with a test per event that a row of that kind reaches AttentionNotifier.

#### [CRITICAL] ATT-03 — 'Done', 'Login required' and permission handling differ per provider: Claude and Codex take different paths through status, rows and banners

*Category:* agent-leak

- `App/Hooks/SessionStore+Hooks.swift:108` — case .stop: setStatus(.idle, for: sessionID); notify(.turnCompleted, …)
- `App/Codex/CodexAppServerSession.swift:429` — sessionStore?.setStatus(.completed, detail: String(localized: "Codex finished"), for: recordID)
- `App/Core/AttentionCenter.swift:167` — case .permission, .input, .completed, .taskAssigned, .reviewRequested, .changesRequested: nil
- `App/Codex/CodexAppServerSession.swift:495` — PermissionNotificationCenter.shared.post(request, projectID: record.projectID)
- `App/Core/PermissionNotifications.swift:137` — center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
- `App/Core/NotificationPrefs.swift:361` — It does not ask for permission: macOS shows that prompt exactly once, and asking for it here meant it appeared at whatever moment an agent finished
- `App/Codex/CodexAppServerSession.swift:570` — sessionStore?.setCodexAuthentication(.required, for: recordID)
- `App/Hooks/SessionStore+Hooks.swift:85` — if message.localizedCaseInsensitiveContains("permission") {

**Why it matters:** A Claude turn ending gives a banner and a sidebar pulse but no row; a Codex turn ending gives a 'Done' row and a menu-bar count but no banner. Codex approvals and control-plane grants ignore quiet hours, delivery filters, dedup and reminders, and re-ask macOS authorization inside the post despite the other path's explicit design against that. 'Login required' can only ever come from Codex. The user sees one settings tree and assumes one behaviour.

**Direction:** Route every provider through one status→signal→notification pipeline; treat provider-specific mechanics (hooks, app-server, auth) as adapters that emit the same signals.

#### [HIGH] ATT-04 — Five independent 'acknowledged' states: read marks, resolved marks, unseenAttention, notification ledger, and macOS delivered banners that are never cleared

*Category:* duplicate-concept

- `App/Core/AttentionCenter.swift:501` — func markRead(_ id: String) { … readMarks[id] = mark(items[index])
- `App/Core/AttentionCenter.swift:515` — func resolve(_ id: String) { … resolvedMarks[id] = mark(item) … items.removeAll
- `App/Core/ProjectStore.swift:770` — func markAttention(_ recordID: UUID) { unseenAttention.insert(recordID) }
- `App/UI/MainWindow.swift:612` — .task(id: id) { sessionStore.clearAttention(id) }
- `App/Core/NotificationPolicy.swift:155` — struct NotificationLedger … clear(sessionID:) // new turn, session ended
- `App/Core/PermissionNotifications.swift:207` — private func open(sessionID: String?) { … MainRoute.shared.request(.session(record.id)) }  // no removeDeliveredNotifications anywhere in App/

**Why it matters:** Clicking 'Clear' on a permission row hides it while the sidebar row keeps pulsing (status still needsAttention), the reminder keeps firing (ledger untouched), and the banner remains in Notification Center. Opening the session stops the pulse but leaves the row unread. There is no single act that means 'I have seen this'.

**Direction:** One acknowledgement per signal occurrence, shared by panel, sidebar, reminders and Notification Center (removeDeliveredNotifications on open/resolve).

#### [HIGH] ATT-05 — ~60 notification/attention controls across 8 places, including the same control shown twice in one pane and the same binding in two panes

*Category:* settings-sprawl

- `App/UI/Settings/NotificationPermissionRow.swift:60` — Button("Send a Test Notification") { run { await authorization.sendTestNotification() } }
- `App/UI/Settings/NotificationSettingsPages.swift:129` — Button("Send a Test Notification") { Task { await NotificationAuthorization.shared.sendTestNotification() } }
- `App/UI/Settings/NotificationSettingsPages.swift:210` — Toggle(isOn: Binding(get: { prefs.prefs(for: event).remind ?? true }, …  // Events page
- `App/UI/Settings/NotificationSettingsPages.swift:295` — Toggle(isOn: Binding(get: { settings.notifications.prefs(for: event).remind ?? true }, …  // Reminders page
- `App/UI/Settings/SettingsView.swift:110` — case .notifications, .notificationEvents, .reminders, .quietHours, .projectNotifications: .notifications
- `App/UI/Settings/AppearanceSettingsPage.swift:34` — Section("Attention") { Picker … title: String(localized: "Sidebar pulse")
- `App/UI/Settings/GeneralSettingsPage.swift:91` — Section("Provider Limits") { Toggle … "Warn before an account runs out" … "Raises a row in the Attention Center"
- `App/UI/Settings/MenuBarSettingsPage.swift:93` — ForEach(MenuBarPrefs.Counter.allCases) { counter in Toggle(…) … detail: … "Shown next to the icon, marked “\(counter.marker)”."
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:171` — Toggle(isOn: Binding(get: { settings.notifications.onlyWhenBackgrounded }, …

**Why it matters:** General (9) + Events (25) + Reminders (7) + Quiet Hours (4) + Per Project (3×N) + Menu Bar (11) + Appearance/Attention (1) + General/Provider Limits (2) + onboarding (3). Priority and sound form a 3-level inheritance matrix (event → project → global) the user must model to predict one banner. The defaults already do the right thing (NotificationPrefs.swift:67-69: 'the point of the pane is turning things off'), so the tree's size buys little.

**Direction:** One Notifications page: permission status, a short list of signals with on/off, one 'important' flag, and quiet hours; move sound/priority matrices and per-project overrides behind an advanced disclosure or drop them.

#### [HIGH] ATT-06 — The sidebar's 'turn done' pulse depends on whether a macOS banner was actually sent

*Category:* coupling

- `App/Hooks/SessionStore+Hooks.swift:150` — guard let dispatch = decision.dispatch else { return decision }         notificationLedger.record(…)         // The banner is easy to miss; the sidebar row keeps saying it until the session is opened.         markAttenti
- `App/Core/NotificationPolicy.swift:134` — if prefs.onlyWhenBackgrounded, context.appIsActive { return .skip(.appActive) }
- `App/Core/ProjectStore.swift:779` — func wantsAttention(_ recordID: UUID) -> Bool { unseenAttention.contains(recordID) || status(of: recordID).needsAttention }

**Why it matters:** Turn notifications off, enable quiet hours, or keep Uncoil frontmost with 'only while in the background' on, and a finished Claude turn leaves no trace in the sidebar (status returns to idle, no row is derived). The in-app signal is a side effect of the out-of-app one.

**Direction:** Mark the in-app signal from the state change itself; let notification policy decide only whether a banner accompanies it.

#### [HIGH] ATT-07 — Assigning a task raises a sticky 'Waiting for a reply' row plus a second 'An agent was assigned' row, and task-side rows duplicate session-side ones

*Category:* duplicate-concept

- `App/UI/ProjectTasksView.swift:1292` — AttentionStore.shared.report(kind: .input, title: …, detail: String(localized: "Assigned to the \(record.displayTitle) session as \(request.role.label)"), … id: "task-assigned:\(assignment.id.uuidString)")
- `App/Core/AttentionCenter.swift:183` — /// Derived items mirror live state and disappear on their own; reported items (test results) stay until the user resolves them.
- `App/Tasks/TaskAttention.swift:60` — case .assigned, .agentStarting, .running: items.append(item(.taskAssigned, task: task, title: who, detail: assignment.state.label, …
- `App/Tasks/TaskAttention.swift:68` — case .waitingForPermission: items.append(item(.permission, task: task, title: who, detail: String(localized: "Waiting for permission for the task."), …
- `App/Core/MenuBarMonitor.swift:23` — case .taskAssigned: running += 1 … if running > 0 { parts.append("\(running) tasks running") }

**Why it matters:** The reported row is mislabelled (nothing is waiting for a reply), never resolved by code (grep shows 'task-assigned' only at the report site), and 20 seconds later the scan adds the real row. When the agent then waits, the session-derived 'permission:<session>' row and the task-derived 'task-permission:<task>:<session>' row both appear with different titles. The menu bar counts the informational 'assigned' row as 'tasks running'.

**Direction:** One row per (session, condition); task metadata decorates the session row instead of producing a parallel set.

#### [HIGH] ATT-08 — AttentionKinds are implementation events, not user concepts; each new feature adds a kind and seven switch cases

*Category:* concept-overload

- `App/Core/AttentionCenter.swift:147` — var notificationEvent: NotificationEvent? { … case .runtime, .testFailure, .mergeConflict, .taskFailed, .taskBlocked, .relinkNeeded, .agentCrashed, .usageExhausted: .problem
- `App/Core/AttentionCenter.swift:47` — case .relinkNeeded: String(localized: "Task link lost")
- `App/Core/RunRegistry.swift:233` — AttentionStore.shared.report(kind: .runtime, title: String(localized: "Run '\(config.name)' failed")
- `App/UI/MainWindow.swift:474` — AttentionStore.shared.report(kind: .runtime, title: String(localized: "Could not file that task")
- `App/Core/AttentionCenter.swift:115` — var isTaskRow: Bool { switch self { case .taskAssigned, .reviewRequested, …
- `CHANGELOG.md:208` — Added task events to the Attention Center and menu bar, with shortcuts to a project's board, its task sessions and stopping its orchestrator.
- `CHANGELOG.md:166` — Notifications now also come from the Attention Center, so failing tests, merge conflicts, runtime trouble, lost logins, finished tasks and merge-ready branches can notify — each governed by its own event setting.

**Why it matters:** 'Runtime problem' labels a daemon outage, a failed run configuration and a failed TODO edit alike; 'Task link lost' exposes the fingerprint mechanism; 'Done', 'Task done' and 'Ready to merge' are three shades of finished. Every kind must be placed in label/iconName/color/priority/isTaskRow/isProblem/notificationEvent plus MenuBarTaskCounts and the isObservable prefix rules — nine touch points per addition, with no registry enforcing it.

**Direction:** Define signals by what the user must do (answer, approve, fix, review, merge, sign in, nothing) and let sources tag which one they raise.

#### [MEDIUM] ATT-09 — The same surface is called 'Attention Center', 'pending notifications', 'attention list', 'Sessions needing attention' and 'Notifications'

*Category:* terminology

- `App/UI/AttentionCenterView.swift:213` — ? "\(store.unreadCount) pending notifications" : "Attention center"
- `App/UI/AttentionCenterView.swift:30` — Text("Attention Center")
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:29` — no working / needs-input state, no notifications, no attention list.
- `App/UI/Settings/MenuBarSettingsPage.swift:127` — SettingsLabel(title: String(localized: "Sessions needing attention"))
- `App/UI/MenuBarMonitorView.swift:82` — ForEach(attention.items.prefix(6)) { item in Button("\(item.kind.label): \(item.title)")
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:279` — Every session shows working, needs input or done. Anything waiting on you collects in the Attention Center and in the menu-bar monitor.

**Why it matters:** 'Notifications' means macOS banners in Settings and rows in the rail tooltip; the menu-bar section named 'Sessions needing attention' lists usage, runtime and task rows that are not sessions; onboarding teaches a three-state model ('working, needs input or done') the app does not have.

**Direction:** Pick one noun for the in-app list and one for banners, and use them everywhere including onboarding.

#### [MEDIUM] ATT-10 — Attention Center is reachable only via a 20pt rail bell and a 372×380 popover; no menu, shortcut or palette action

*Category:* navigation

- `App/UI/SidebarView.swift:165` — AttentionRailButton { item in
- `App/UI/AttentionCenterView.swift:21` — .frame(width: 372)
- `App/UI/AttentionCenterView.swift:84` — .frame(maxHeight: 380)
- `App/UI/AttentionCenterView.swift:161` — .opacity(hovering ? 1 : 0.35)  // resolve check

**Why it matters:** The one place that aggregates everything waiting on the user is a hover-revealed popover with no filtering or grouping across 18 kinds and per-account rows, and the sidebar can be hidden (⌘B) taking the bell with it. The 'resolve' affordance is a 35%-opacity check that only appears on hover.

**Direction:** Give the list a first-class home (a pane or a pinned section) and a command.

#### [MEDIUM] ATT-11 — Menu-bar counters use invented glyph markers ('!', '×', '⏱') and 'Pending' counts a different set than the list beneath and the 'problems' headline

*Category:* terminology

- `App/Core/MenuBarPrefs.swift:67` — /// Suffix that keeps the counters apart at a glance: `3 2! 1×`. … case .waiting: "!" case .problems: "×" case .tasks: "⏱"
- `App/Core/MenuBarPrefs.swift:80` — case .waiting: summary.waitingPermission + summary.waitingInput
- `App/Core/MenuBarMonitor.swift:134` — summary.problems = attention.filter(\.kind.isProblem).count
- `App/UI/Settings/MenuBarSettingsPage.swift:116` — "Busy, it looks like this: \(prefs.label(for: sampleSummary))"

**Why it matters:** The settings page exists largely to explain the markers ('marked “×”'). 'Pending' excludes problems while the icon turns yellow for both; 'N problems' includes 'Login required' and 'Limit reached', which the Events settings treat as separate events.

**Direction:** Show at most one number with one meaning (things waiting on me) and let the icon carry severity.

#### [MEDIUM] ATT-12 — Dead or unwired configuration: clickAction is persisted but never exposed or read; suppression reasons have UI labels no view shows; legacy notify* accessors still gate a live path

*Category:* visibility-logic

- `App/Core/MenuBarPrefs.swift:98` — var clickAction: ClickAction = .openMenu
- `App/Core/MenuBarPrefs.swift:35` — enum ClickAction … case openMenu, openMainWindow … "Open the Uncoil window"
- `App/Core/NotificationPolicy.swift:13` — /// Why a notification was not sent. Surfaced in the settings pane's live explanation, and asserted directly by the tests.
- `App/Core/NotificationPrefs.swift:240` — // MARK: - Legacy accessors … var notifyPermission: Bool { isEnabled(.permission) }
- `App/Core/PermissionNotifications.swift:91` — guard prefs.enabled, prefs.notifyPermission else { return }

**Why it matters:** grep finds clickAction only in MenuBarPrefs.swift; NotificationSuppression is referenced by no view. Config that exists in the model but not in the UI (or vice versa) is exactly what a capability registry would have caught, and it signals that settings are added ahead of the surfaces that use them.

**Direction:** Remove clickAction or wire it; either show suppression reasons ('why did I not get a banner?') or delete the labels.

#### [MEDIUM] ATT-13 — Provider brand colour is the semantic colour for 'waiting for permission', and status is drawn with at least seven different colour/shape vocabularies

*Category:* terminology

- `App/Core/Models.swift:652` — case .waitingForPermission: Theme.claude
- `App/Core/AttentionCenter.swift:81` — case .permission: Theme.claude
- `App/UI/StatusOrb.swift:3` — /// - running: three dots orbiting … - waitingForPermission / waitingForInput: pulsing glow … - completed: calm solid dot with a soft ring … - suspended / hibernated: hollow ring … - idle / terminated: static dim dot
- `App/UI/Components/StatusRing.swift:14` — enum State: Equatable { case idle, skipped, running, live, passed, failed, warned
- `App/ControlPlane/McpStatus.swift:47` — enum McpLinkState … "MCP off" / "MCP waiting" / "MCP connected"
- `App/Usage/UsagePresentation.swift:20` — enum Severity … case healthy, low, critical, unknown … static let lowPercent: Double = 40
- `App/Usage/UsageAlert.swift:11` — enum State … case none, approaching, reached

**Why it matters:** A Codex session waiting for approval glows Claude-orange in the sidebar, header, palette and attention row. Users must also learn orb motion signatures, ring dash/solid/glyph, StatusBadge levels, MCP badge colours and two usage scales (the chip goes 'low' at 40% while the row appears at the user's 15%).

**Direction:** One semantic colour set (working / needs me / problem / done / off) shared by every status mark; provider colour only on the provider mark.

#### [MEDIUM] ATT-14 — Claude Code's hook mechanism is presented as generic 'Status tracking' in onboarding and Settings, and status is inferred by substring-matching hook messages

*Category:* agent-leak

- `App/Core/OnboardingState.swift:33` — case .hooks: String(localized: "Status tracking")
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:85` — Codex has no hook system. Uncoil follows its sessions through the CLI itself
- `App/UI/Settings/PrivacySettingsPages.swift:346` — title: String(localized: "Agent Status Hooks"), subtitle: String(localized: "Claude Code's hooks are what make session states stream into Uncoil live.")
- `App/UI/Settings/PrivacySettingsPages.swift:374` — case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"
- `App/Hooks/SessionStore+Hooks.swift:95` — } else if message.localizedCaseInsensitiveContains("waiting") {

**Why it matters:** A Codex-only user gets a mandatory-looking onboarding step and a Settings pane about a mechanism that does not apply, filed under 'Uncoil' rather than under the agent. The classification of the most important status pair rests on English substrings in a third party's message text (and the pane still carries an untranslated 'Eksik:').

**Direction:** Fold status-feed setup into each agent's own row (Installed Agents / Extensions) and make the adapter, not the UI, provider-aware.

#### [MEDIUM] ATT-15 — Ten status writers with no arbitration, four overlapping predicates, and a header that shows the raw detail string instead of a status

*Category:* coupling

- `App/Core/ProjectStore.swift:869` — func setStatus(_ status: AgentSessionStatus, detail: String? = nil, for recordID: UUID)
- `App/Core/WorkingTree.swift:29` — extension AgentSessionStatus { var isWorking: Bool {
- `App/Core/Models.swift:665` — var needsAttention: Bool … var attentionPriority: Int … var isKnownLive: Bool
- `App/UI/SessionHeaderBar.swift:239` — Text(sessionStore.detail(of: record.id) ?? status.label)
- `App/Hooks/SessionStore+Hooks.swift:80` — setStatus(.running, detail: event.toolName.map { "tool: \($0)" }, for: sessionID)
- `App/Terminal/TerminalHost.swift:612` — sessionStore.setStatus(.idle, detail: String(localized: "PTY fallback: \(reason)"), for: recordID)

**Why it matters:** setStatus is called from CodexAppServerSession (16), hooks (9), TerminalHost (5), ProjectStore handshake (5), SessionSleepService (4), PermissionService, SessionsHandler, fixtures and views; the last writer wins. The header capsule — the most prominent status surface — reads 'tool: Bash' or 'PTY fallback: …' instead of a status word whenever a detail is set. isWorking/needsAttention/isKnownLive/attentionPriority are four partially overlapping partitions of the same ten cases, one defined in an unrelated file.

**Direction:** A single status reducer with source priority, and a fixed status word with detail as secondary text.

#### [MEDIUM] ATT-16 — Usage warnings are a notification-class feature configured under General, with rows that deliberately never notify and an Events pane that does not say so

*Category:* settings-sprawl

- `App/UI/Settings/GeneralSettingsPage.swift:97` — detail: String(localized: "Raises a row in the Attention Center when a login is close to a provider limit.")
- `App/Core/AttentionCenter.swift:164` — // A banner for "approaching" would interrupt to say that nothing has happened yet. … case .usageLow: nil
- `App/UI/MainWindow.swift:177` — AttentionRefresher.shared.setUsage(UsageAttentionCollector.snapshot(… threshold: settings.usageWarningThreshold, isEnabled: settings.usageWarningsEnabled))
- `App/Core/AttentionCenter.swift:542` — /// Held rather than passed in … a caller that did not have the usage store to hand would rebuild the whole snapshot without it and silently erase every usage row.

**Why it matters:** The user configures 'warn' in General, sees the result in Attention Center, and finds no matching row in Notifications > Events; the AttentionRefresher had to grow a cached usage snapshot because refresh() is called from places that cannot rebuild it — a symptom of sources being bolted on one by one.

**Direction:** Treat 'account running out' as one signal in the same list as the others, configured in the same place.

#### [LOW] ATT-17 — Advanced orchestration actions and launch shortcuts live in the at-a-glance menu-bar menu

*Category:* other

- `App/UI/MenuBarMonitorView.swift:153` — Menu("Stop the Orchestrator") { ForEach(projectStore.projects) { project in Button(project.name) { stopOrchestrator(project) } } }
- `App/UI/MenuBarMonitorView.swift:110` — Menu("New Session") { ForEach(projectStore.projects) { project in Menu(project.name) { ForEach(AgentProvider.sessionKinds)
- `App/UI/Settings/MenuBarSettingsPage.swift:124` — SettingsLabel(title: String(localized: "Task shortcuts"), detail: String(localized: "Board, task session, orchestrator."))

**Why it matters:** A status menu meant for a glance carries three nested submenus of orchestration plus a project×provider launcher that duplicates the sidebar quick-launch strip and the palette; the settings page then needs three toggles to let users hide them.

**Direction:** Keep the status item to status and 'open the thing that needs me'.

#### [LOW] ATT-18 — Documentation of the mental model lags the code

*Category:* other

- `docs/current/STATUS.md:75` — **Notifications** (General / Events / Reminders / Quiet Hours / Per Project) · **Menu Bar** · **Appearance** · **Privacy and Permissions** (Permissions / Data and Transcripts / Status Tracking)
- `CHANGELOG.md:125` — Settings were reorganised around six categories instead of eight … The tree is now General · Agents · Notifications · Appearance · **Uncoil** · About

**Why it matters:** The current-status doc still lists Menu Bar as its own category and Status Tracking under Privacy; anyone writing the restructuring plan from docs will start from the wrong tree.

**Direction:** Regenerate STATUS.md from SettingsView.Pane or drop the tree from it.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Attention Center popover | popover | `App/UI/AttentionCenterView.swift` | AttentionRailButton on sidebar rail (SidebarView.swift:165); No menu command, shortcut or palette action (grep of PaletteModel/CommandPalette/UncoilApp/MainWindow finds none) |
| Attention rail bell | hover-control | `App/UI/AttentionCenterView.swift` | Sidebar bottom rail, between + and list-check buttons (SidebarView.swift:148-175) |
| Sidebar session row | row | `App/UI/SidebarView.swift` | Always visible |
| Session header status cluster | status | `App/UI/SessionHeaderBar.swift` | Top of every session view |
| Project dashboard session row | row | `App/UI/ProjectDashboardView.swift` | Project dashboard sessions list |
| Session group row | row | `App/UI/SessionGroupView.swift` | Multi-select session group |
| Session pop-out title bar | window | `App/UI/SessionPopoutWindow.swift` | Session dragged out of the main window |
| Command palette session row | row | `App/UI/CommandPalette.swift` | ⌘K palette |
| Menu-bar status item label | menu | `App/UI/MenuBarMonitorView.swift` | macOS menu bar, inserted when MenuBarPrefs.isVisible |
| Menu-bar drop-down | menu | `App/UI/MenuBarMonitorView.swift` | Click on status item |
| macOS session-attention banner | banner | `App/Core/NotificationPrefs.swift` | SessionStore.notify via hook reducer (SessionStore+Hooks.swift:87-118) and AttentionStore.onNewItems bridge (MainWindow.swift:905-921) and the reminder sweep (SessionStore+Hooks.swift:213-247) |
| macOS permission banner | banner | `App/Core/PermissionNotifications.swift` | PermissionService.onRequestCreated (MainWindow.swift:988-994); CodexAppServerSession.swift:495 |
| Settings > Notifications > General | screen | `App/UI/Settings/NotificationSettingsPages.swift` | Settings sidebar, category Notifications, pane titled 'General' (SettingsView.swift:139) |
| Settings > Notifications > Events | screen | `App/UI/Settings/NotificationSettingsPages.swift` | Settings sidebar |
| Settings > Notifications > Reminders | screen | `App/UI/Settings/NotificationSettingsPages.swift` | Settings sidebar |
| Settings > Notifications > Quiet Hours | screen | `App/UI/Settings/NotificationSettingsPages.swift` | Settings sidebar |
| Settings > Notifications > Per Project | screen | `App/UI/Settings/NotificationSettingsPages.swift` | Settings sidebar |
| Settings > Appearance > Menu Bar | screen | `App/UI/Settings/MenuBarSettingsPage.swift` | Settings sidebar, category Appearance (SettingsView.swift:113) |
| Settings > Appearance > Theme and Colours > Attention | screen | `App/UI/Settings/AppearanceSettingsPage.swift` | Settings sidebar |
| Settings > General > Provider Limits | screen | `App/UI/Settings/GeneralSettingsPage.swift` | Settings sidebar, General |
| Settings > Uncoil > Agent Status Hooks | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings sidebar, category Uncoil (SettingsView.swift:122,148) |
| Onboarding › Status tracking step | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | First-run flow step 5 of 13 (OnboardingState.swift:10-24) |
| Onboarding › Notifications step | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | First-run flow step 6 |
| Onboarding › finish card 'Status and the attention list' | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | Last onboarding step |
| Task board execution-state badge | status | `App/UI/ProjectTasksView.swift` | Tasks tab |
| Settings rail count badge | hover-control | `App/UI/Components/CountBadge.swift` | Sidebar rail |
| Test summary chips | status | `App/UI/Components/CountChip.swift` | Tests tab |
| StatusRing sites | status | `App/UI/Components/StatusRing.swift` | Tests / Run / Issues tabs |
| In-session Codex approval panel | panel | `App/UI/SessionDetailView.swift` | Codex session view |

### Concepts

- `U!` **Session status (AgentSessionStatus)** — 10 cases: unknown/idle/thinking/running/waitingForPermission/waitingForInput/completed/suspended/hibernated/terminated with labels Checking…/Ready/Thinking/Running/Waiting for permission/Waiting for a reply/Done/Paused/Asleep/Closed (Models.swift:610-645). Written by 10 different sources (hooks, Codex app-server, PTY host, daemon handshake, sleep service, control-plane close, fixtures). *Overlaps:* AttentionKind.permission/input/completed, NotificationEvent.permission/input/turnCompleted, ProjectTaskExecutionState.waitingForPermission/waitingForUser/running/completed
- `U` **Status detail** — Free-text string per session (SessionStore.details) set alongside status: 'tool: Bash', hook message text, 'Codex finished', 'PTY fallback: …' (SessionStore+Hooks.swift:80,86,96; CodexAppServerSession.swift:426-429; TerminalHost.swift:612). *Overlaps:* Session status label
- `U` **Attention row (AttentionItem) and AttentionKind** — 18 kinds (AttentionCenter.swift:4-28) each with label/icon/colour/priority/isTaskRow/isProblem/notificationEvent switches. Rows are 'derived' (mirror live state) or 'reported' (stick until resolved) (lines 183-185). *Overlaps:* Session status, NotificationEvent, Task execution state, UsageAlert.State
- `i` **Derived vs reported row** — Derived rows disappear when the condition clears; reported rows (tests, runs, crashes, artifacts, task assignment, capture errors) persist in memory until the user resolves them or the reporter resolves by id (AttentionCenter.swift:183-185, 476-499).
- `U` **Read mark / resolved mark** — Per-row occurrence-signature marks persisted in UserDefaults for 30 days; 'Read' dims the row, 'Clear'/check hides it until the signature changes (AttentionCenter.swift:322-347, 501-527). *Overlaps:* Unseen attention, Notification ledger, macOS delivered notifications
- `U` **Unseen attention (sidebar pulse)** — SessionStore.unseenAttention set, inserted only when a banner was actually dispatched (SessionStore+Hooks.swift:150-154), cleared when the session view appears (MainWindow.swift:612); OR'd with status.needsAttention to drive the row pulse (ProjectStore.swift:764-781). *Overlaps:* Read mark, Session status needsAttention
- `U` **Attention emphasis** — off/subtle/full: pulse period, fill opacity and border range for the sidebar row; also switches StatusOrb motion off everywhere via the AttentionMotion singleton (AttentionEmphasis.swift:11-70, 81-92). *Overlaps:* -disable-animations launch flag
- `U` **Notification event** — 7 events: permission/input/turnCompleted/problem/taskCompleted/mergeReady/loginRequired, each with title, detail, SF symbol, supportsReminder (NotificationPrefs.swift:10-70). 8 AttentionKinds fold into 'problem'; permission/input/completed/taskAssigned/reviewRequested/changesRequested/usageLow have none. *Overlaps:* AttentionKind, Session status
- `U` **Priority** — low/normal/high mapped to UNNotificationInterruptionLevel passive/active/timeSensitive (NotificationPrefs.swift:122-152); resolved event → project → global. *Overlaps:* AttentionKind.priority (a different, internal urgency scale)
- `U` **Sound** — 'default' / 'none' / one of 14 system sound names, resolved event → project → global (NotificationPrefs.swift:165, 219-223, 250-253).
- `U` **Reminder** — Repeat banners for 'persisting' events at an interval up to a count; per-event opt-in (NotificationPrefs.swift:84-92, 225-229); swept every 30s and dropped when the session status no longer matches (SessionStore+Hooks.swift:180-247). *Overlaps:* Quiet hours, Delivery filters
- `U` **Quiet hours** — Daily minute window with wrap-around and a high-priority exemption (NotificationPrefs.swift:95-117). *Overlaps:* macOS Focus (the app re-implements a subset)
- `U` **Delivery filters** — onlyWhenBackgrounded, suppressForVisibleSession, groupByProject (NotificationPrefs.swift:175-180).
- `U` **Per-project override** — enabled/priority/sound per project UUID (NotificationPrefs.swift:154-158, 184). *Overlaps:* Event override (event wins over project, line 211-217)
- `i` **Notification ledger / attempt / suppression reason** — Per (session,event) count and lastSentAt for dedup and reminders (NotificationPolicy.swift:58-62, 155-198); 10 NotificationSuppression reasons with user-facing labels (lines 15-41) that no view displays. *Overlaps:* Read/resolved marks
- `U` **macOS authorization status** — unknown/notRequested/granted/provisional/denied with labels (NotificationAuthorization.swift:16-57).
- `U` **Menu-bar summary / icon state / counters** — MenuBarSummary (running, waitingPermission, waitingInput, completed, problems + MenuBarTaskCounts of 6) (MenuBarMonitor.swift:7-105); Icon idle/working/waiting; Counter running/waiting('Pending')/problems/tasks with markers ''/'!'/'×'/'⏱' (MenuBarPrefs.swift:50-85). *Overlaps:* AttentionKind.isProblem, Session status, Task execution state
- `U` **Menu-bar prefs (icon style, monochrome, hide when idle, click action, sections)** — MenuBarPrefs.swift:5-105. clickAction (openMenu/openMainWindow) is persisted but never exposed in MenuBarSettingsPage and never read by MenuBarMonitorView/UncoilApp (grep finds no other reference).
- `U!` **Problem** — AttentionKind.isProblem: runtime/testFailure/mergeConflict/authentication/taskFailed/taskBlocked/relinkNeeded/agentCrashed/usageExhausted (AttentionCenter.swift:128-141). Escalates the menu-bar icon and feeds the 'problems' counter, but not the rail bell. *Overlaps:* NotificationEvent.problem (different membership: excludes authentication, which has its own event)
- `U` **Usage alert state and usage severity** — UsageAlert.State none/approaching/reached drives rows and handoff (UsageAlert.swift:11-20); UsageDisplay.Severity healthy/low(40%)/critical(user threshold)/unknown drives the header chip colour (UsagePresentation.swift:20-53). Two vocabularies for one figure. *Overlaps:* AttentionKind.usageLow/usageExhausted, NotificationEvent.problem (exhausted only)
- `U` **Task execution state** — 12 states with labels and its own needsAttention/isActive predicates (ProjectTaskModels.swift:189-227); TaskAttentionEngine maps 7 of them onto AttentionKinds including re-using .permission/.input/.testFailure (TaskAttention.swift:57-119). *Overlaps:* Session status, AttentionKind
- `U!` **MCP link state** — off/waiting/connected with label 'MCP off/waiting/connected', colours faint/warn/ok (McpStatus.swift:47-82). *Overlaps:* Runtime phase (a different 'is the infrastructure up' signal that surfaces as an attention row instead)
- `U` **StatusRing.State / StatusBadge.Level / SettingsStatusLine.Level / BadgeTint / CountChip** — Four more colour-level vocabularies for runs/tests/settings/badges (StatusRing.swift:14-50; Theme.swift:465-500; SettingsChrome.swift:126-127; CountBadge.swift:12-35). *Overlaps:* Session status colours
- `U` **Runtime info (model · effort with source)** — Reported / chosen / providerDefault resolution shown as a faint '(opus · high)' aside with a hover explanation (SessionRuntimeInfo.swift:11-96; SessionHeaderBar.swift:113-121).
- `i` **Codex authentication state, Runtime phase, Session exit** — Internal enums (Models.swift:706-711; RuntimeClient.swift:22-28; SessionExit.swift:14-42) that surface only as AttentionKinds authentication ('Login required'), runtime ('Runtime problem'), agentCrashed ('Agent crashed'). *Overlaps:* MCP link state, Session status terminated
- `U!` **Status hooks (Claude Code)** — Uncoil-managed entries for 7 Claude hook events written into ~/.claude/settings.json (HookInstaller.swift:11-14); the only live status feed for Claude; Codex has none.

### Flows

- **Claude agent asks for permission** (6 steps) — friction: Six surfaces light up for one event, with three different acknowledgement states (read mark, resolved mark, unseenAttention); the user can 'Clear' the row while the sidebar keeps pulsing and the banner stays in Notification Center (no removeDeliveredNotifications anywhere).
- **Codex asks for approval** (4 steps) — friction: The Events/Reminders/Quiet Hours settings the user configured for 'Waiting for permission' silently do not apply to Codex approvals or control-plane grants; the banner arrives even in quiet hours.
- **An agent finishes its turn** (2 steps) — friction: 'Done' means a status for Codex and an event for Claude; a user with both providers gets a banner for one and a row for the other for the same moment.
- **A test suite fails** (3 steps) — friction: The settings promise a banner the wiring cannot deliver; the same holds for RunRegistry failures, merge conflicts, runtime daemon rows and relink rows (all sessionID nil).
- **Assign a task to an agent from the Tasks board** (4 steps) — friction: One action yields two or three rows with three different labels; one of them is mislabelled 'Waiting for a reply' and sticks.
- **An account runs low** (3 steps) — friction: A notification-class feature configured under General, with two colour scales and two handoff buttons for one condition.
- **Set up notifications as a new user** (5 steps) — friction: About sixty controls in eight places to answer 'tell me when an agent needs me'; the defaults already do that, so the whole tree exists to turn things off.
- **Turn on reminders for a lost login or a merge-ready branch** (3 steps) — friction: Two of the four remindable events shown to the user are inert.
- **Glance at the menu bar** (3 steps) — friction: 'Pending' counter counts only permission+input while the list beneath shows usage, runtime and task rows; 'Stop the Orchestrator' — a destructive orchestration action — sits in an at-a-glance status menu.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| notifications.enabled (master) | global | settings.json → NotificationPrefs.enabled | Settings > Notifications > General (NotificationSettingsPages.swift:68-74) |  |
| notifications.priority / notifications.sound (global defaults) | global | settings.json | Settings > Notifications > General (77-103) | yes |
| notifications.events[event].enabled / priority / sound | global (per event) | settings.json events dictionary keyed by rawValue | Settings > Notifications > Events (166-207) |  |
| notifications.events[event].remind | global (per event, 4 events) | settings.json | BOTH Settings > Notifications > Events (209-225) AND > Reminders (293-317) | yes |
| notifications.reminders.enabled / intervalMinutes / maxCount | global | settings.json | Settings > Notifications > Reminders (254-291) | yes |
| notifications.quietHours.enabled / startMinute / endMinute / allowHighPriority | global | settings.json | Settings > Notifications > Quiet Hours (357-380) | yes |
| notifications.onlyWhenBackgrounded / suppressForVisibleSession / groupByProject | global | settings.json | Settings > Notifications > General (106-125); first two also in Onboarding notifications step (OnboardingPlatformSteps.swift:171-190) | yes |
| notifications.perProject[id].enabled / priority / sound | project | settings.json keyed by project UUID | Settings > Notifications > Per Project (436-480) |  |
| macOS notification authorization | account | UNUserNotificationCenter (system) | Settings > Notifications > General permission row; Onboarding notifications step |  |
| menuBar.enabled / iconStyle / monochrome / counters / hideWhenIdle / showTasksSection / showSessionsSection / showQuickLaunch | global | settings.json → MenuBarPrefs (migrated from UserDefaults, CHANGELOG.md:231) | Settings > Appearance > Menu Bar (MenuBarSettingsPage.swift:36-133) | yes |
| menuBar.clickAction | global | settings.json → MenuBarPrefs.clickAction (MenuBarPrefs.swift:98) | Nowhere — not in MenuBarSettingsPage and not read by any view (grep) | yes |
| attentionEmphasis | global | settings.json (nil when subtle) mirrored into AttentionMotion.shared (SettingsStore.swift:162, 271-275) | Settings > Appearance > Theme and Colours > Attention 'Sidebar pulse' (AppearanceSettingsPage.swift:34-54) | yes |
| usageWarningsEnabled / usageWarningThreshold | global | settings.json (SettingsStore.swift:48-50, 100-106) | Settings > General > Provider Limits (GeneralSettingsPage.swift:91-125) | yes |
| attention.readMarks / attention.resolvedMarks | global | UserDefaults JSON blobs, pruned after 30 days (AttentionCenter.swift:322-347) | Implicitly via Attention Center Read/Clear/check and menu-bar open |  |
| Claude status hooks installed | integration | ~/.claude/settings.json managed entries (HookInstaller.swift:11-14) | Onboarding 'Status tracking' step; Settings > Uncoil > Agent Status Hooks (PrivacySettingsPages.swift:340-380) | yes |
| permissionTimeoutMinutes | global | settings.json (SettingsStore.swift:54-56) | Settings > Uncoil > Permissions (out of scope) | yes |

### Visibility gates

- `App/UI/MainWindow.swift:908-911` — item.kind.notificationEvent != nil && item.projectID != nil && item.sessionID != nil → Whether an attention row produces a banner at all — excludes every reported row without a session (tests, runs, merge conflicts, runtime, relink) and taskCompleted/mergeReady rows
- `App/Core/AttentionCenter.swift:128-141` — AttentionKind.isProblem → Menu-bar icon escalation to 'waiting' and the 'problems' count/counter
- `App/Core/AttentionCenter.swift:95-113; App/UI/AttentionCenterView.swift:226-231` — AttentionKind.priority (permission 6 … completed 1) and createdAt → Panel order and the rail bell colour (max-priority unread kind)
- `App/UI/AttentionCenterView.swift:132-133` — item.kind == .usageLow || .usageExhausted, item.sessionID != nil → 'Hand off' button on a row
- `App/UI/AttentionCenterView.swift:195, 201` — store.items.isEmpty / store.unreadCount > 0 → bell vs bell-ringing icon; 6pt dot
- `App/Core/AttentionCenter.swift:470-472` — hasRefreshedOnce && !previouslyLive.contains(id) && !isRead → Which rows are 'new' for notification purposes (never on the first refresh of a launch)
- `App/Core/AttentionCenter.swift:394-406` — isObservable(id) prefix rules: permission:/input:/completed:/auth: need the session present; task- needs a non-empty task scan; conflict/runtime never → When read/resolved marks are dropped so a recurrence comes back unread
- `App/Core/MenuBarPrefs.swift:123-127` — prefs.enabled && (!hideWhenIdle || summary.icon != .idle || label non-empty) → Whether the status item is inserted in the menu bar
- `App/Core/MenuBarMonitor.swift:100-104` — waitingPermission > 0 || waitingInput > 0 || problems > 0 → waiting; running > 0 → working; else idle → Menu-bar icon state
- `App/Core/MenuBarPrefs.swift:115-120` — counter selected && value > 0 → Which counters appear next to the icon
- `App/UI/MenuBarMonitorView.swift:77, 81, 93, 109` — settings.menuBar.showTasksSection; showSessionsSection && !attention.items.isEmpty; interruptible non-empty; showQuickLaunch && projects non-empty → Drop-down sections
- `App/UI/SessionHeaderBar.swift:237, 173` — record.provider.isAgent → Status capsule, MCP badge and UsageChip in the header (terminal sessions show none)
- `App/UI/SessionHeaderBar.swift:264` — usageAlert.state.isAlerting → Handoff ControlButton in the header
- `App/UI/SessionHeaderBar.swift:113` — runtimeInfo.summary != nil → '(model · effort)' aside
- `App/UI/SessionHeaderBar.swift:239; App/UI/SessionGroupView.swift:210` — sessionStore.detail(of:) ?? status.label → Header text shows the raw detail string instead of the status word whenever one is set
- `App/Core/ProjectStore.swift:779-781; App/UI/SidebarView.swift:860-868` — unseenAttention.contains(id) || status(of:).needsAttention → Sidebar row pulse and its colour
- `App/Hooks/SessionStore+Hooks.swift:150-154` — NotificationPolicy.decide returned .send (i.e. banner dispatched) → markAttention — the sidebar 'turn done' pulse only happens if a banner was sent
- `App/Core/AttentionEmphasis.swift:90-92; App/UI/StatusOrb.swift:19-30` — emphasis != .off && !LaunchConfig.disableAnimations → Orb motion and row breathing everywhere
- `App/Core/NotificationPolicy.swift:106-147` — NotificationPolicy.decide order: masterOff → eventOff → projectOff → alreadySent/reminder rules → quietHours (high exempt) → appActive → visibleSession → Every hook/attention/reminder banner
- `App/Core/PermissionNotifications.swift:91, 114, 133` — prefs.enabled && prefs.notifyPermission && project enabled — no policy, no ledger → Control-plane and Codex approval banners (bypass quiet hours, delivery filters, dedup, reminders)
- `App/Hooks/SessionStore+Hooks.swift:227-230, 250-256` — Self.status(matching: event) == status(of: session) else clear → Reminders only for permission/input; loginRequired and mergeReady entries are dropped on the first sweep
- `App/Hooks/SessionStore+Hooks.swift:85, 95` — message.localizedCaseInsensitiveContains("permission") / ("waiting") → Whether a Claude hook notification becomes waitingForPermission or waitingForInput status (and thus every downstream surface)
- `App/UI/Settings/NotificationSettingsPages.swift:183` — prefs.isEnabled(event) → Priority/sound/remind sub-controls per event row
- `App/UI/Settings/NotificationSettingsPages.swift:209; NotificationPrefs.swift:60-65` — event.supportsReminder → Remind toggle presence
- `App/UI/Settings/MenuBarSettingsPage.swift:73` — prefs.iconStyle == .logo → 'Single colour' toggle
- `App/UI/Settings/GeneralSettingsPage.swift:105` — settings.usageWarningsEnabled → Threshold picker; and UsageAttentionEngine returns [] when off (UsageAttention.swift:101)
- `App/Usage/UsageAttention.swift:51-52` — account has ≥1 non-terminated agent session → Whether a low account gets a row at all
- `App/Tasks/TaskAttention.swift:138, 128, 121, 49` — task.mergeBlockers == [] && !assignments.isEmpty; task.isDone; latestReview == .changesRequested; assignments.contains(needsRelinking) → Task-side rows
- `App/Terminal/TerminalHost.swift:487-491; App/Core/SessionExit.swift:38-42` — exit.isCrash (agent && exitCode != 0) → 'Agent crashed' row
- `App/UI/MainWindow.swift:163-172` — 20-second polling loop → Freshness of task and merge-conflict rows (and hence of the 'tasks running' count)
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:75, 85; App/Codex/CodexAppServerSession.swift:426-429, 566-573` — provider == .claude (hooks) vs .codex (app-server) → Which statuses a session can ever reach: .completed and CodexAuthenticationState are Codex-only; .turnCompleted banner is Claude-only

### Open questions

- Is 'Done' (.completed) intended as a lasting status or a momentary event? Codex treats it as a status row; Claude treats it as a banner. Which should the product commit to?
- Are the taskCompleted / mergeReady / problem banners meant to fire for rows without a session (tests, runs, conflicts, daemon)? If yes the bridge filter needs a project-level route; if no, those event settings should not exist.
- Is menuBar.clickAction shelved on purpose (MenuBarExtra makes 'open window on click' awkward) or forgotten? It ships in settings.json with localized strings.
- Should Codex approvals and control-plane permission requests obey quiet hours / delivery filters / reminders like hook permissions do, or is bypassing policy a deliberate 'permissions always interrupt' rule?
- Are usage rows an attention concept (they have a Hand off action) or a header concern (the chip and its handoff button already exist)? Two surfaces currently offer the same action with different colour scales.
- Is the second 'Send a Test Notification' button on the General page intentional (one inside the permission row, one at the bottom)?
- Is the sidebar pulse meant to be a notification echo (current behaviour: only after a banner is dispatched) or an in-app signal in its own right?
- The onboarding finish card teaches 'working, needs input or done' — is that the intended user-facing status model, and should the ten-case enum be projected onto it everywhere?

---

## MCP control plane as it surfaces in the UI: capability grants, directional permissions, session presets, driver setup, the Uncoil MCP pane, and the adjacent working-mode / Codex / Claude-hook approval paths

From the user's chair, "what may an agent do" in Uncoil is answered in at least ten different places with at least six different vocabularies. The control plane itself is a bounded, well-tested engine: 27 capability grant keys in 8 domains (19 on by default, 8 opt-in), stored per session; plus a separate directional permission record (caller→target) that is only ever consulted for two keys (`sessions.control`, `sessions.close`) which do not exist in the catalog. On top of that engine the UI grew a per-session Permissions pane with 4 hand-made groups, an onboarding step with 8 different hand-made groups that writes a global default nowhere else editable, a Session Presets editor exposing every raw key plus a free-text "Permission mode", a task-dispatch sheet whose "Permission profile" is never enforced, a Drivers page whose remedies and accessibility ids still say "Permissions", a Working Mode setting (CLI flags) in two places, Codex's own approvals in the session, Claude's hook-derived "waiting for permission" status, and macOS TCC via a "Set Permissions" button. The 90% user never needs any of it: the defaults already cover projects, sessions, tasks, runs, artifacts and browser, and the only opt-ins (Computer Use, task delete/orchestrate/worktree/merge, blueprints) are reached by a toggle, not by an approval. TODO N.5 and N.2 already name this as the second-worst thing about the product.

### Findings

#### [CRITICAL] CP-01 — At least ten distinct 'may the agent do this' concepts, each with its own UI and vocabulary

*Category:* concept-overload

- `App/UI/Settings/PrivacySettingsPages.swift:78` — SettingsPage(title: String(localized: "Permissions")) {
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:364` — settings.setSessionCapabilityDefaults(granted)
- `App/UI/Settings/AgentSettingsPages.swift:683` — Section("Grants") {
- `App/UI/Settings/AgentSettingsPages.swift:658` — title: String(localized: "Permission mode"),
- `App/ControlPlane/PermissionService.swift:6` — struct PermissionRequest: Codable, Equatable, Identifiable {
- `App/UI/Settings/AgentSettingsPages.swift:430` — title: String(localized: "Working Mode"),
- `App/UI/TaskDispatchSheet.swift:307` — pickerRow(String(localized: "Permission profile")) {
- `App/UI/SessionDetailView.swift:178` — private struct CodexApprovalPanel: View {
- `App/Hooks/SessionStore+Hooks.swift:85` — if message.localizedCaseInsensitiveContains("permission") {
- `App/UI/Settings/DriverSetupSections.swift:184` — Button("Set Permissions") { grantPermissions() }
- `TODO.md:106` — Map every route a permission request can arrive by today — the control plane, Claude's hooks, Codex's structured approvals, macOS's own prompts — and the different UI each one currently ends up in.

**Why it matters:** A user cannot form one mental model of 'trust' when per-session grants, a global default, preset grants, directional approvals, CLI working modes, a preset 'permission mode', a prompt-only 'permission profile', Codex approvals, Claude hook prompts and macOS TCC all answer the same question in different places with different scope words (Once/Permanent, For the Session, providerDefault…). Every new tool or provider adds another row to each of these.

**Direction:** One trust model with named levels; everything else derived or hidden behind an advanced surface.

#### [CRITICAL] CP-02 — The two grant keys the directional flow actually uses are not catalog keys, so real requests show raw keys and can never be answered from the banner

*Category:* visibility-logic

- `App/ControlPlane/SessionsHandler.swift:193` — if let gate = permissionOutcome(request, caller: caller, target: target, grantKey: "sessions.control") {
- `App/ControlPlane/SessionsHandler.swift:153` — if let gate = permissionOutcome(request, caller: caller, target: target, grantKey: "sessions.close") {
- `App/ControlPlane/CapabilityCatalog.swift:79` — .init(key: "sessions.control_children", domain: .sessions,
- `App/Core/PermissionNotifications.swift:17` — guard let entry = CapabilityCatalog.entry(for: grantKey) else { return true }
- `App/UI/Settings/PrivacySettingsPages.swift:241` — Text(CapabilityCatalog.entry(for: request.grantKey)?.label ?? request.grantKey)
- `App/ControlPlane/HelpRegistry.swift:326` — Args: `grant_key` (required — e.g. `sessions.control`, `sessions.close`)
- `Tests/PermissionManagementTests.swift:82` — let granted = a.addGrant(grantKey: "sessions.control_children", from: "A", target: "B")

**Why it matters:** The only permission dialog a normal user will ever meet reads '<8 hex> → <8 hex>: sessions.control'. The fail-safe 'unknown key is sensitive' rule also means the Allow Once / Deny banner actions exist only for synthetic test requests. The totality test checks catalog ∪ PolicyEngine, not the keys handlers request, so nothing catches this.

**Direction:** Make the directional keys members of the same registry the handlers, catalog, notification policy and tests all read from.

#### [HIGH] CP-03 — Three hand-maintained groupings of the same 27 keys, and the Permissions pane's grouping leaves 10 keys reachable only under Advanced

*Category:* duplicate-concept

- `App/ControlPlane/CapabilityCatalog.swift:11` — case projects, worktrees, sessions, tasks, runs, browser, computer, artifacts
- `App/UI/Settings/PrivacySettingsPages.swift:28` — AccessGroup(                 id: "projects",
- `App/UI/Settings/PrivacySettingsPages.swift:56` — keys: ["browser.use", "browser.persistent_state"],
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:257` — id: "tasks",                 symbol: "checklist",                 title: String(localized: "Reading and ticking tasks"),
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:265` — id: "runs",
- `App/UI/Settings/PrivacySettingsPages.swift:83` — Text("Project, session, artifact and Agent Browser are on by default in new sessions. Computer Use stays off for every session until you turn it on.")
- `App/ControlPlane/PolicyEngine.swift:42` — "runs.read", "runs.write", "runs.control",

**Why it matters:** Catalog domains (8), Permissions access groups (4, 17 keys), onboarding groups (8, 26 keys) disagree; tasks.*, runs.* (runs.control is flagged risky and default-on) and blueprints.write have no group in Settings, and the overview sentence does not mention that tasks and runs are on. Adding a key means editing three views plus two docs.

**Direction:** Groups belong to the registry; views render them.

#### [HIGH] CP-04 — Global capability default is editable only in onboarding, contradicts its own footer, and makes every later session read as 'customised'

*Category:* onboarding

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:351` — You can change all of this later in Settings › Uncoil › Permissions.
- `App/Core/SettingsStore.swift:763` — func setSessionCapabilityDefaults(_ capabilities: Set<String>?) {
- `App/Core/ProjectStore.swift:439` — record.capabilities = Self.defaultSessionCapabilities
- `App/UI/Settings/PrivacySettingsPages.swift:182` — Text(record.capabilities == nil                              ? "Using the default profile"                              : "Customised for this session")
- `App/UI/Settings/PrivacySettingsPages.swift:190` — projectStore.updateSession(record.id) { $0.capabilities = nil }

**Why it matters:** grep shows setSessionCapabilityDefaults has one caller (onboarding). A user who unticked anything on first run gets a list stamped on every session, so the Permissions footer says 'Customised for this session' for all of them and 'Back to Default' resets to the engine defaults, discarding the choice they made. The promised Settings location edits single sessions only.

**Direction:** Either drop the onboarding step or give the default a home in Settings and make 'default' mean one thing.

#### [HIGH] CP-05 — Session Presets editor exposes internal machinery: slug 'Identity', raw grant keys, and a free-text 'Permission mode' that is documented as reserved

*Category:* agent-leak

- `App/UI/Settings/AgentSettingsPages.swift:695` — SettingsLabel(title: capability.label, detail: capability.key)
- `App/UI/Settings/AgentSettingsPages.swift:555` — Text("\(preset.id) · \(preset.provider.displayName) · \(preset.grantedCapabilities.count) grants")
- `App/UI/Settings/AgentSettingsPages.swift:660` — prompt: "standard",                         text: $permissionMode,                         monospaced: true
- `App/Core/SessionPreset.swift:20` — /// Permission mode label; reserved for future provider-specific mapping.
- `App/UI/TaskDispatchSheet.swift:468` — if let mode = AgentWorkingMode(rawValue: preset.permissionMode),
- `App/Core/SessionPreset.swift:49` — grantedCapabilities: Array(PolicyEngine.defaultGrants) + ["sessions.read"]
- `App/UI/Settings/SettingsView.swift:198` — case .presets: "preset alt agent child yetki capability prompt şablon template"

**Why it matters:** The editor asks the user for a machine slug, shows 27 raw keys, and offers a field whose only working values are undocumented enum rawValues like 'acceptEdits'. The built-ins even append 'sessions.read' to a set that already contains it. 'Preset' is an internal name for a child-launch template that the 90% user never spawns.

**Direction:** Hide presets unless orchestration is on; replace 'Permission mode' with the working-mode picker or remove it.

#### [HIGH] CP-06 — The task-dispatch 'Permission profile' shows N grants that are never enforced

*Category:* coupling

- `App/UI/TaskDispatchSheet.swift:311` — request.permissionProfile.isEmpty                             ? "session default"                             : "\(request.permissionProfile.count) grants"
- `App/UI/TaskDispatchSheet.swift:465` — request.permissionProfile = preset.grantedCapabilities
- `App/Tasks/TaskDispatch.swift:101` — lines.append("Permission profile: \(context.permissionProfile.sorted().joined(separator: ", "))")
- `App/UI/ProjectTasksView.swift:1266` — record = projectStore.createSession(                 projectID: project.id,                 provider: request.provider,                 accountID: request.accountID,                 title: String(localized: "\(request.pr
- `App/ControlPlane/SessionsHandler+Children.swift:121` — $0.capabilities = caps

**Why it matters:** The same preset binds capabilities when an agent uses create_child but only adds a sentence to the prompt when the user dispatches from the UI (the record gets the global default; preset extraArguments are also dropped). A row labelled with a permission word that changes nothing teaches users the wrong model.

**Direction:** Either apply the preset on the UI path or remove the row.

#### [HIGH] CP-07 — 'Capabilities', 'Permissions', 'Grants', 'Session Access', 'permission bounds', 'permission profile' and 'Profile' all name overlapping things

*Category:* terminology

- `App/Core/OnboardingState.swift:34` — case .capabilities: String(localized: "Agent capabilities")
- `App/UI/Settings/McpSettingsPage.swift:92` — Button(String(localized: "Capabilities…")) {                         SettingsRoute.shared.requestedPane = SettingsView.Pane.permissions.rawValue
- `App/UI/Settings/PrivacySettingsPages.swift:178` — Text("Session Access")
- `App/UI/Settings/AgentSettingsPages.swift:548` — subtitle: String(localized: "Set the provider, opening prompt and permission bounds for child agents.")
- `App/UI/TaskDispatchSheet.swift:228` — pickerRow(String(localized: "Profile")) {
- `App/UI/ExtensionsView.swift:812` — KeyValueRow(key: "Active profile", value: activeProfile(installation.agent))
- `App/Tasks/AgentLaunchOptions.swift:28` — struct AgentLaunchCapabilities: Equatable {
- `App/Extensions/AgentAdapter.swift:77` — var capabilities: AgentProviderCapabilities { get }

**Why it matters:** A button called 'Capabilities…' opens a pane called 'Permissions' whose main section is 'Session Access' and whose sibling editor calls the same keys 'Grants'. 'Profile' means account in one row and preset-plus-grants two windows away. Internally 'capabilities' is four unrelated types, which is why the UI word keeps drifting.

**Direction:** Pick one user word per concept and rename internals to match.

#### [HIGH] CP-08 — Control-plane policy, status and setup are spread across six Settings panes in two categories, with stale cross-references

*Category:* settings-sprawl

- `App/UI/Settings/SettingsView.swift:122` — case .permissions, .mcp, .hooks, .drivers, .github, .privacyData: .uncoil
- `App/UI/Settings/SettingsView.swift:108` — case .installedAgents, .accounts, .cliTools, .launchArgs, .agentBehavior, .presets,                  .blueprints: .agents
- `App/UI/Settings/PrivacySettingsPages.swift:9` — rebuilt on `Form`. Driver installation moved to its own Integrations page.
- `App/UI/Settings/DriverSetupSections.swift:4` — /// Settings → Entegrasyonlar → Sürücüler.
- `App/UI/Settings/IntegrationsSettingsPages.swift:190` — .settingsID("permissions.drivers")
- `App/ControlPlane/Adapters/AgentBrowserAdapter.swift:25` — static let installRemedy = "Open Uncoil Settings → Permissions → Agent Browser Setup"
- `App/ControlPlane/Adapters/CuaDriverAdapter.swift:423` — remedy: "open Uncoil Settings → Permissions → Computer Use Setup and grant Accessibility + Screen Recording"
- `App/UI/Onboarding/OnboardingToolSteps.swift:236` — Text("Installed from Settings › Uncoil › Drivers, where the driver's own setup runs.

**Why it matters:** Permissions (policy), Uncoil MCP (status), Drivers (setup) sit under 'Uncoil'; Session Presets and Working Mode (also policy) sit under 'Agents'; Notifications > Events gates the banner. The Drivers page still carries 'permissions.*' ids and Turkish doc comments from two moves ago, and agents are still told to open panes that no longer exist.

**Direction:** One 'Agent trust' surface; drivers as a setup sub-step of the feature they enable.

#### [HIGH] CP-09 — Four of the 13 onboarding steps configure agent policy or drivers before the user has a project, using protocol vocabulary

*Category:* onboarding

- `App/Core/OnboardingState.swift:10` — case welcome     case clis     case accounts     case workingModes     case hooks     case notifications     case capabilities     case tools     case project
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:311` — subtitle: String(localized: "Uncoil hands every session an MCP server of its own, so the agent can talk back: eight tools, each one gated by a capability you control."),
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:240` — detail: String(localized: "uncoil_projects · uncoil_artifacts — the agent reads your projects, cuts a worktree for itself, and leaves files behind that you can open."),
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:334` — > uncoil_tasks {"action":"help"}
- `App/UI/Onboarding/OnboardingToolSteps.swift:30` — footnote: String(localized: "Uncoil never raises a session above the mode you pick here — a child agent inherits its parent's, intersected, and cannot escalate.")
- `TODO.md:50` — Cut the steps that do not have to be answered before first use. Anything       Uncoil can detect, default, or ask for later does not belong in setup.

**Why it matters:** Working modes (#4), Status tracking (#5), Agent capabilities (#7) and Optional tools (#8) precede First project (#9). The capabilities step shows tool ids and a JSON help sample; the working-modes footnote describes capability intersection, not working modes (inferred: no code intersects AgentWorkingMode). The defaults already cover the 90% case, so the step mostly teaches vocabulary.

**Direction:** Detect CLIs, pick a project, start; ask for Computer Use when a session first needs it.

#### [MEDIUM] CP-10 — Permissions pane availability and its session picker are bound to the wrong things

*Category:* coupling

- `App/UI/Settings/SettingsView.swift:344` — if let service = sessionStore.permissionService {                 PermissionsSettingsPage(service: service)             } else {                 SettingsUnavailablePage(
- `App/UI/Settings/PrivacySettingsPages.swift:151` — ForEach(projectStore.sessions) { session in
- `App/Core/Models.swift:159` — var wiresControlPlane: Bool {         switch self {         case .claude, .codex, .opencode: true

**Why it matters:** Per-session capability toggles live on SessionRecord and work without the service, yet the whole pane disappears when the control plane is off. Conversely the picker lists terminal sessions and Gemini/Grok/Cursor/Hermes sessions that never receive the uncoil tools, so toggles there are inert with no hint.

**Direction:** Gate only the request lists on the service; filter or annotate sessions by wiresControlPlane.

#### [MEDIUM] CP-11 — A pending control-plane request is visible only as a macOS banner and inside Settings; nothing in the main window changes

*Category:* discoverability

- `App/Core/PermissionNotifications.swift:28` — guard let target else { return "\(caller) → \(label)" }         return "\(caller) → \(short(target)): \(label)"
- `App/Core/PermissionNotifications.swift:32` — static func short(_ id: String) -> String {         String(id.prefix(8))
- `App/Core/PermissionNotifications.swift:207` — private func open(sessionID: String?) {         if let sessionID, let record = sessionResolver?(sessionID) {             MainRoute.shared.request(.session(record.id))
- `App/UI/MainWindow.swift:977` — permissions.onRequestCreated = { [weak projectStore] request in
- `App/ControlPlane/PermissionService.swift:57` — static let defaultPendingTTL: TimeInterval = 10 * 60
- `TODO.md:116` — Fix the timeout behaviour: a request nobody answered must fail closed and       say so in the session, not disappear.

**Why it matters:** grep shows no UI reads service.pending() outside PrivacySettingsPages, and no control-plane path sets .waitingForPermission. The banner names sessions by 8-hex prefixes, 'Open in Uncoil' lands on the session rather than the decision, and if notifications are off the request silently expires. The audit log (AuditLog) has no surface at all, so 'reviewable with the time it was given and what asked for it' (N.5) is unmet.

**Direction:** Surface pending requests in the session and attention centre; name sessions by title.

#### [MEDIUM] CP-12 — Three independent risk axes (risky, optional, requiresApproval) and the catalog's promised warning hint does not exist

*Category:* visibility-logic

- `App/ControlPlane/CapabilityCatalog.swift:46` — /// Elevated-risk grant: control that reaches beyond the agent's own         /// sandbox (foreground control, cross-project, other sessions, personal         /// browser profile). Surfaced with a warning hint in the UI.
- `App/Core/PermissionNotifications.swift:18` — return entry.risky
- `App/ControlPlane/PolicyEngine.swift:31` — "sessions.read", "sessions.read_all", "sessions.control_children",         "sessions.control_all", "sessions.create_children", "sessions.cross_project",
- `App/ControlPlane/CapabilityCatalog.swift:76` — .init(key: "sessions.read_all", domain: .sessions,               label: "Read every session",               detail: "Sees sessions in other projects too.", risky: true),
- `App/UI/Settings/PrivacySettingsPages.swift:68` — requiresApproval: true

**Why it matters:** grep for '.risky' finds only the notification policy; no view renders a hint. Four grants are risky and default-on (read_all, cross_project, browser.persistent_state, runs.control), sessions.control_all is default-on and not risky, and the pane's own requiresApproval flag exists only on Computer Use and only changes a label. The user sees none of these distinctions and cannot predict which request will be answerable from a banner.

**Direction:** One risk level per key in the registry, rendered consistently.

#### [MEDIUM] CP-13 — Turkish strings inside the English catalog and Hooks page

*Category:* terminology

- `App/ControlPlane/CapabilityCatalog.swift:57` — label: "Projeleri oku",
- `App/ControlPlane/CapabilityCatalog.swift:22` — case .computer: "Bilgisayar"
- `App/ControlPlane/CapabilityCatalog.swift:68` — detail: "Mevcut worktree'leri listeler.", risky: false),
- `App/ControlPlane/CapabilityCatalog.swift:125` — label: "Arka planda kontrol",
- `App/ControlPlane/CapabilityCatalog.swift:142` — label: "Artifact oku",
- `App/UI/Settings/PrivacySettingsPages.swift:375` — case .partiallyInstalled(let missing): "Eksik: \(missing.joined(separator: ", "))"

**Why it matters:** These labels are what the Advanced toggles, the preset editor, the pending rows and the banner display; CLAUDE.md requires English UI strings. Mixed-language labels in a permissions list read as broken trust UI.

**Direction:** Move labels into the string catalog; lint the registry for non-English.

#### [MEDIUM] CP-14 — Docs describe a permission model the code does not implement

*Category:* other

- `docs/current/mcp/PERMISSIONS.md:43` — When policy would deny an action that a human could reasonably authorize — most notably Computer Use and `bring_to_front` — the handler returns `PERMISSION_REQUIRED`
- `docs/current/mcp/PERMISSIONS.md:65` — | `computer.inspect` | inspect the bound application window |
- `App/ControlPlane/ComputerHandler.swift:34` — guard grants.contains("computer.foreground_control") else {                 return .failure(request, code: .capabilityDisabled,
- `docs/current/mcp/PERMISSIONS.md:15` — projects.read  worktrees.read  worktrees.create sessions.read  sessions.read_all  sessions.control_children  sessions.control_all
- `docs/current/mcp/CAPABILITIES.md:3` — Six MCP tools (capabilities).

**Why it matters:** PERMISSIONS.md lists computer.* as the directional keys 'used today' while the only isGranted caller uses sessions.control/close; its default list omits tasks.* and runs.*; CAPABILITIES.md says six tools where there are eight. A designer reading the docs will design for the wrong model.

**Direction:** Generate these tables from the registry.

#### [MEDIUM] CP-15 — Driver setup appears in three user surfaces plus an agent tool, and one of its settings lives outside SettingsStore

*Category:* duplicate-concept

- `App/UI/Onboarding/OnboardingToolSteps.swift:203` — title: String(localized: "Cua Driver — Computer Use"),
- `App/UI/Settings/IntegrationsSettingsPages.swift:180` — title: String(localized: "Drivers"),
- `App/Extensions/AgentIntegration.swift:28` — case .controlPlane: "Control plane"
- `App/ControlPlane/SystemHandler.swift:47` — case "dependencies":             let browser = browserEngine.probe()             let computer = computerEngine.probe()
- `App/UI/Settings/DriverSetupSections.swift:17` — @AppStorage(AgentBrowserAdapter.executablePreferenceKey)     private var executablePath = ""
- `TODO.md:86` — ## N.4 Rewrite the agent-browser and Computer Use setup

**Why it matters:** Onboarding, Drivers, Installed Agents/Extensions ('Control plane' level) and uncoil_system dependencies each describe readiness differently; the browser executable choice is a UserDefaults key invisible to backups and SchemaRegistry. Setup (is the driver there) and policy (may the agent use it) are presented as unrelated pages that point at each other.

**Direction:** Attach driver readiness to the Computer Use / Browser feature row and keep one source of truth.

#### [MEDIUM] CP-16 — Working mode is configured in four places and shadowed by the preset's 'Permission mode'

*Category:* duplicate-concept

- `App/UI/Onboarding/OnboardingToolSteps.swift:44` — get: { settings.workingMode(for: provider) },                             set: { settings.setWorkingMode($0, for: provider) }
- `App/UI/Settings/AgentSettingsPages.swift:436` — get: { settings.workingMode(for: provider) },                         set: { settings.setWorkingMode($0, for: provider) }
- `App/UI/TaskDispatchSheet.swift:277` — pickerRow(String(localized: "Working mode")) {
- `App/UI/TaskOrchestratorSheet.swift:214` — get: { launch.workingMode }, set: { launch.workingMode = $0 }
- `App/Core/Models.swift:273` — enum AgentWorkingMode: String, Codable, CaseIterable, Identifiable {     case providerDefault     case auto     case plan     case manual     case acceptEdits     case dangerouslySkipPermissions

**Why it matters:** Working mode is the CLI's own trust axis (what Codex/Claude will ask about) and MCP grants are Uncoil's; the UI never says which is which, and a user who lowers one may believe they lowered the other.

**Direction:** Present working mode and MCP grants as two facets of one trust level.

#### [LOW] CP-17 — 'Permission Timeout' is a global knob wedged between the request list and the per-session section

*Category:* settings-sprawl

- `App/UI/Settings/PrivacySettingsPages.swift:126` — Section("Permission Timeout") {
- `App/Core/SettingsStore.swift:116` — @Published private(set) var permissionTimeoutMinutes = 10

**Why it matters:** A rarely needed operational setting sits in the middle of a decision surface; it also only concerns the sessions.control/close flow, which most users never trigger.

**Direction:** Fold into advanced or remove in favour of a fixed policy.

#### [LOW] CP-18 — Session header badge says 'MCP off / MCP waiting / MCP connected' on every agent session

*Category:* agent-leak

- `App/ControlPlane/McpStatus.swift:54` — var label: String {         switch self {         case .off: "MCP off"         case .waiting: "MCP waiting"         case .connected: "MCP connected"
- `App/ControlPlane/McpStatus.swift:76` — case .waiting: Theme.warn
- `App/UI/SessionHeaderBar.swift:250` — McpStatusBadge(sessionID: record.id)

**Why it matters:** A protocol acronym in the everyday header, coloured amber for the normal 'agent has not called yet' state, competes with the session status orb next to it.

**Direction:** Keep it in the MCP diagnostics page or as a quiet hover detail.

#### [LOW] CP-19 — Dead or unreachable permission affordances

*Category:* other

- `App/ControlPlane/PermissionService.swift:183` — func injectTestRequest(
- `App/ControlPlane/PermissionService.swift:173` — func addGrant(grantKey: String, from: String, target: String?) -> PermissionRequest {
- `App/ControlPlane/PermissionService.swift:169` — /// first (Settings → İzinler → "İzin Ekle").

**Why it matters:** grep finds no callers for injectTestRequest and no UI for addGrant ('İzin Ekle' no longer exists), so the service carries API for surfaces that were removed; the doc comments still describe the old Turkish pane names.

**Direction:** Delete with the redesign.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Settings > Uncoil > Permissions (PermissionsSettingsPage) | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings sidebar, Uncoil category; 'Capabilities…' button on Settings > Uncoil > Uncoil MCP (McpSettingsPage.swift:92-96); Command-palette deep link via SettingsRoute (MainWindow.swift:410); HelpRegis |
| Settings > Uncoil > Permissions — unavailable state | empty-state | `App/UI/Settings/SettingsView.swift` | Settings > Uncoil > Permissions when the control plane is gated off (UI-test launches without -control-plane, or startup failure) |
| Settings > Uncoil > Uncoil MCP (McpSettingsPage) | screen | `App/UI/Settings/McpSettingsPage.swift` | Settings sidebar, Uncoil category |
| Settings > Uncoil > Drivers (DriversSettingsPage + AgentBrowserSetupSe | screen | `App/UI/Settings/DriverSetupSections.swift` | Settings sidebar, Uncoil category; Onboarding 'Optional tools' text: 'Installed from Settings › Uncoil › Drivers' (OnboardingToolSteps.swift:236); Agent-facing remedy strings point at the OLD location |
| Settings > Uncoil > Agent Status Hooks (HooksSettingsPage) | screen | `App/UI/Settings/PrivacySettingsPages.swift` | Settings sidebar, Uncoil category |
| Settings > Agents > Session Presets (SessionPresetsSettingsPage) | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings sidebar, Agents category |
| Session Preset editor sheet (SessionPresetEditorSheet) | sheet | `App/UI/Settings/AgentSettingsPages.swift` | Session Presets page Edit / Add Preset |
| Settings > Agents > Working Mode (AgentBehaviorSettingsPage) | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings sidebar, Agents category; Onboarding step 4 'Working modes' edits the same store |
| Settings > Agents > Installed Agents (AgentsSettingsPage / AgentContro | screen | `App/UI/Settings/AgentsSettingsPage.swift` | Settings sidebar, Agents category |
| Settings > Agents > Blueprints — 'write with agent' | screen | `App/UI/Settings/BlueprintsSettingsPage.swift` | Settings > Agents > Blueprints |
| Onboarding step 7 'Agent capabilities' (OnboardingCapabilitiesStep) | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | First run (OnboardingFlow.currentVersion 3); Settings > About > start setup over; -route onboarding -onboarding-step capabilities |
| Onboarding step 4 'Working modes' (OnboardingWorkingModesStep) | screen | `App/UI/Onboarding/OnboardingToolSteps.swift` | First run |
| Onboarding step 8 'Optional tools' (OnboardingToolsStep) | screen | `App/UI/Onboarding/OnboardingToolSteps.swift` | First run |
| Onboarding step 5 'Status tracking' (OnboardingHooksStep) | screen | `App/UI/Onboarding/OnboardingPlatformSteps.swift` | First run |
| macOS notification 'Permission request' / 'Permission request (sensiti | banner | `App/Core/PermissionNotifications.swift` | PermissionService.onRequestCreated (MainWindow.swift:977-984) when notifications enabled and the 'Waiting for permission' event is on |
| macOS notification 'Codex is waiting for approval' | banner | `App/Core/PermissionNotifications.swift` | Codex app-server approval request |
| In-session Codex approval panel (CodexApprovalPanel) | panel | `App/UI/SessionDetailView.swift` | Codex session detail |
| Session status 'waiting for permission' from Claude hooks | status | `App/Hooks/SessionStore+Hooks.swift` | Claude Code hook socket |
| Session header MCP badge (McpStatusBadge) | status | `App/ControlPlane/McpStatus.swift` | Every agent session header |
| Task dispatch sheet (TaskDispatchSheet) | sheet | `App/UI/TaskDispatchSheet.swift` | Project > Tasks > dispatch a task |
| Extensions window > Agents card rows | row | `App/UI/ExtensionsView.swift` | Extensions window > Agents section |
| Settings > Notifications > Events — 'Waiting for permission' | row | `App/Core/NotificationPrefs.swift` | Settings > Notifications > Events |

### Concepts

- `U!` **Capability grant key** — One of 27 dotted strings (projects.read, blueprints.write, worktrees.read/create, sessions.read/read_all/control_children/control_all/create_children/cross_project/organize, tasks.read/write/delete/orchestrate/worktree/merge, browser.use/persistent_state, computer.inspect/background_control/foreground_control, runs.read/write/control, artifacts.read/write) that a handler checks with PolicyEngine.grants(for:).contains before acting (CapabilityCatalog.swift:55-147; PolicyEngine.swift:29-59). 19 default-on, 8 opt-in. *Overlaps:* Capability domain, Access group, Onboarding group, Permission profile, Preset granted capabilities
- `U` **Capability domain** — 8 display buckets projects/worktrees/sessions/tasks/runs/browser/computer/artifacts, with titles partly in Turkish ('Bilgisayar') (CapabilityCatalog.swift:10-25). *Overlaps:* Access group (4 groups in the Permissions pane), Onboarding group (8 different groups)
- `U` **Access group (Permissions pane)** — Hand-made bundle of keys with a single toggle: Projects and Files (5 keys), Session Management (7), Agent Browser (2), Computer Use — needs approval (3). Covers 17 of 27 keys; tasks.*, runs.* and blueprints.write are reachable only under Advanced (PrivacySettingsPages.swift:26-71). *Overlaps:* Onboarding group, Capability domain
- `U` **Onboarding group** — A second, different hand-made bundling of the same keys into 8 cards (adds Reading and ticking tasks, Running the project, Task orchestration and worktrees, Deleting and merging tasks; omits blueprints.write) (OnboardingPlatformSteps.swift:236-305). *Overlaps:* Access group, Capability domain
- `U` **Session capability override ('default profile' vs 'customised')** — SessionRecord.capabilities: nil = PolicyEngine.defaultGrants, otherwise an explicit list (Models.swift:763-765; PolicyEngine.swift:61-64). Written by the Permissions pane toggles, Blueprints 'write with agent', create_child, and — for every session — ProjectStore.createSession stamping the global default (ProjectStore.swift:439). *Overlaps:* Global session capability default, Preset granted capabilities
- `U` **Global session capability default** — SettingsStore.sessionCapabilityDefaults, set ONLY by the onboarding capabilities step, copied into ProjectStore.defaultSessionCapabilities and stamped on every new session (SettingsStore.swift:763-776; ProjectStore.swift:23, 439). No Settings pane edits it. *Overlaps:* Session capability override, PolicyEngine.defaultGrants
- `U!` **Directional permission (PermissionRequest)** — Record {grantKey, fromSessionID, targetSessionID, status pending/granted/denied/expired/consumed, scope once/persistent} in permissions.json; consulted by exactly one call site, SessionsHandler.permissionOutcome, for keys 'sessions.control' and 'sessions.close' (PermissionService.swift:6-48; SessionsHandler.swift:153, 193, 212-233). *Overlaps:* Capability grant key (the two runtime keys are not catalog keys), Codex approval, Claude hook permission
- `U` **Permission timeout** — Global minutes (Off/1/5/10/30, default 10) after which a pending directional request becomes 'expired' (SettingsStore.swift:116, 320-325; PermissionService.swift:57-61).
- `U!` **Session preset** — Template {id slug, name, provider, extraArguments, initialPromptTemplate, grantedCapabilities, permissionMode} — the only way create_child may spawn work; child grants = requested ∩ preset ∩ caller (SessionPreset.swift:9-39; PolicyEngine.swift:148-158). Three built-ins: claude-worker, codex-reviewer, task-orchestrator (44-69). *Overlaps:* Blueprint (a stored prompt for a project), Account profile, Working mode, Run Parameters (extraArguments per provider)
- `U!` **Preset 'Permission mode'** — Free-text string on the preset, default 'standard', documented as 'reserved for future provider-specific mapping' (SessionPreset.swift:20-21); the only consumer maps it to AgentWorkingMode(rawValue:) when it happens to match, e.g. 'acceptEdits' (TaskDispatchSheet.swift:466-470). *Overlaps:* Working mode
- `U` **Permission profile (task dispatch)** — TaskDispatchRequest.permissionProfile = preset.grantedCapabilities; shown as 'N grants'; written into the agent prompt as a sentence and never applied to the session record (TaskDispatch.swift:16, 100-101; ProjectTasksView.swift:1266-1276). *Overlaps:* Preset granted capabilities, Session capability override
- `U` **Working mode** — AgentWorkingMode (12 cases; per-provider subsets) that becomes CLI flags such as --permission-mode / --sandbox / --yolo (Models.swift:273-327; SettingsStore.swift:227-245). Global per provider, overridable per session via launchSelection (AgentLaunchOptions.swift:6-20). *Overlaps:* Preset Permission mode, Codex approval (what the mode avoids), Capability grants (a second 'how much may it do' axis)
- `U` **Codex approval** — CodexApprovalRequest {kind command/fileChange/permissions, availableDecisions} from the Codex app-server, answered in-session (Models.swift:721-733; SessionDetailView.swift:178-222). *Overlaps:* Directional permission, Claude hook permission
- `U` **Claude hook permission** — Not a request Uncoil can answer: a Notification hook whose text contains 'permission' flips the status orb and posts a banner (SessionStore+Hooks.swift:83-93). *Overlaps:* Codex approval, Directional permission
- `U` **macOS TCC permission (Accessibility, Screen Recording)** — Needed by cua-driver; Uncoil offers a 'Set Permissions' button that shells to `cua-driver permissions grant` and a probe that reports the driver's own 'permissions status' text (DriverSetupSections.swift:184, 234-252; CuaDriverAdapter.swift:37-45). *Overlaps:* Capability grants computer.* (a separate gate for the same feature)
- `U!` **Driver** — An optional external CLI (agent-browser, cua-driver) behind BrowserEngine / ComputerEngine (ControlEngines.swift:88-130). Install is never automatic. *Overlaps:* Extension / MCP server (Extensions window), Integration level 'Control plane'
- `U` **Managed browser choice** — Which Chromium-family executable agent-browser uses; stored in UserDefaults key agentBrowserExecutablePath outside SettingsStore (AgentBrowserAdapter.swift:26, 84-125; DriverSetupSections.swift:17-18). *Overlaps:* browser.persistent_state grant ('personal browser profile')
- `U!` **MCP link state** — off / waiting / connected per session, from McpStatusStore.isServing + lastContact (McpStatus.swift:36-43). *Overlaps:* Integration level 'Control plane'
- `U!` **Integration level** — Detected only / Terminal only / Control plane / Live events per agent (AgentIntegration.swift:10-31); 'Control plane' is derived from wiresControlPlane or a hand-registered MCP server. *Overlaps:* MCP link state, Uncoil MCP pane 'wired/not wired'
- `U` **wiresControlPlane** — Providers Uncoil can register its MCP server for per session: claude, codex, opencode only (Models.swift:159-176). Others get no uncoil tools. *Overlaps:* Integration level
- `i` **Risky flag** — Bool on 11 catalog entries; comment says 'Surfaced with a warning hint in the UI' (CapabilityCatalog.swift:46-49) but the only reader is the notification policy (PermissionNotifications.swift:18). Independent of default/optional: sessions.read_all, sessions.cross_project, browser.persistent_state, runs.control are risky AND default-on. *Overlaps:* AccessGroup.requiresApproval (a third risk axis, only on Computer Use, rendered as '— needs approval'), PolicyEngine.optionalGrants
- `U!` **'capabilities' (four internal meanings)** — Control-plane grants (SessionRecord.capabilities), AgentLaunchCapabilities = model/effort/mode pickers (AgentLaunchOptions.swift:28-41), AgentProviderCapabilities in the extension adapters (AgentAdapter.swift:77), ExtensionSourceCapabilities (ExtensionSourcePolicy.swift:106). *Overlaps:* Permissions, Grants, Session Access, permission bounds, permission profile
- `U` **'profile' (four user-facing meanings)** — AccountProfile (dispatch sheet 'Profile' row = account), 'default profile' (session capability nil), 'Active profile' in Extensions (= preset · N grants), browser profile (browser.persistent_state detail).

### Flows

- **Agent asks to act on a session it does not own (the only live directional-permission path)** (9 steps) — friction: Raw internal key in the highest-stakes UI; banner can never be answered inline for real requests; no in-app signal beyond a macOS notification; decision surface is three clicks away inside Settings; agent must poll. TODO N.5 lists all of this.
- **User narrows or widens what one session may do** (4 steps) — friction: tasks.*, runs.*, blueprints.write have no group; Computer Use group says '— needs approval' but is a plain toggle; the picker offers sessions the change cannot affect; 'default' means two different things depending on whether onboarding set a global override.
- **First-run capability defaults** (4 steps) — friction: A global setting that is only editable during onboarding; once set, every session reads as 'Customised for this session' and 'Back to Default' silently discards the user's choice.
- **Child session via the control plane (where presets actually bind)** (4 steps) — friction: This is the only path where a preset's grants are enforced; the UI dispatch path below uses the same preset with prose-only effect.
- **Dispatch a task from the UI with a preset** (4 steps) — friction: 'N grants' shown to the user has no enforcement effect; the same word 'Profile' means account two rows up; preset extraArguments are also dropped on this path.
- **Turn on Computer Use end to end** (4 steps) — friction: Three gates (driver installed, TCC granted, capability granted) across two panes plus onboarding; setup (Drivers) and policy (Permissions) are split but cross-reference each other with stale names; the docs claim a fourth gate (directional permission for computer.*) that the code does not implement.
- **Agent Browser readiness** (3 steps) — friction: Onboarding card for the browser has no action, only text pointing at Settings › Uncoil › Drivers (OnboardingToolSteps.swift:236); remedy text names a pane that moved.
- **Codex structured approval** (3 steps) — friction: A third approval UI with its own scope vocabulary ('For the Session' vs the control plane's 'Once/Permanent').
- **Claude Code permission prompt** (2 steps) — friction: Shares the notification event and the status colour with the control-plane flow, but nothing in Uncoil can answer it.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| Per-session capability override | session | SessionRecord.capabilities in the sessions store (Models.swift:763-765) | Settings > Uncoil > Permissions (Session Access groups, Advanced per-key toggles, Back to Default) | yes |
| Global new-session capability default | global | SettingsStore.sessionCapabilityDefaults (settings.json) mirrored to ProjectStore.defaultSessionCapabilities | Onboarding 'Agent capabilities' step only (OnboardingPlatformSteps.swift:364-367) | yes |
| Preset granted capabilities | global | SettingsStore.configuredPresets → presets.json (SettingsStore.swift:94, 171-199; SchemaRegistry.swift:49) | Settings > Agents > Session Presets editor 'Grants' (27 toggles) | yes |
| Preset permission mode | global | presets.json (SessionPreset.permissionMode) | Preset editor free-text 'Permission mode' | yes |
| Preset CLI arguments / opening prompt / provider / slug | global | presets.json | Preset editor |  |
| Directional permission records | session | <AppSupport>/Uncoil/permissions.json (PermissionService.swift:71) | Settings > Uncoil > Permissions (Once/Permanent/Deny/Remove/Cancel); notification Allow Once/Deny (dead for real keys) |  |
| Permission timeout | global | SettingsStore.permissionTimeoutMinutes (SettingsStore.swift:116, 320-325) | Settings > Uncoil > Permissions > Permission Timeout | yes |
| Working mode per provider | global | SettingsStore.providerBehaviors[provider].workingMode (SettingsStore.swift:227-245) | Onboarding 'Working modes'; Settings > Agents > Working Mode |  |
| Working mode per session | session | SessionRecord.launchSelection.workingMode (Models.swift:768; AgentLaunchOptions.swift:6-20) | Task dispatch sheet, orchestrator sheet |  |
| Agent browser executable | global | UserDefaults 'agentBrowserExecutablePath' via @AppStorage — outside SettingsStore, backups and SchemaRegistry (AgentBrowserAdapter.swift:26; DriverSetupSections.swift:17-18) | Settings > Uncoil > Drivers > Browser picker | yes |
| cua-driver TCC grants (Accessibility, Screen Recording) | account | macOS TCC database, probed via `cua-driver permissions status` | Settings > Uncoil > Drivers > Computer Use > Set Permissions | yes |
| Claude Code status hooks | account | ~/.claude/settings.json (HookInstaller) | Settings > Uncoil > Agent Status Hooks; Settings > Agents > Installed Agents 'Connect'; Onboarding 'Status tracking'; Extensions window Agents card | yes |
| 'Waiting for permission' notification event | global | NotificationPrefs.events[.permission] (NotificationPrefs.swift:245) | Settings > Notifications > Events |  |
| Per-provider Run Parameters | global | SettingsStore.extraArguments[provider] (SettingsStore.swift:90) | Settings > Agents > Run Parameters |  |

### Visibility gates

- `App/UI/Settings/SettingsView.swift:343-352` — sessionStore.permissionService == nil (control plane not running) → Whole Permissions pane replaced by 'Control plane not running' — including per-session capability toggles that do not need the service
- `App/UI/Settings/PrivacySettingsPages.swift:96` — !service.pending().isEmpty → 'Awaiting Approval' section
- `App/UI/Settings/PrivacySettingsPages.swift:111` — !service.expired().isEmpty → 'Timed Out' section (max 5 rows)
- `App/UI/Settings/PrivacySettingsPages.swift:146-148` — projectStore.sessions.isEmpty → Session Access shows 'There is no session to grant anything to yet.' instead of picker + groups
- `App/UI/Settings/PrivacySettingsPages.swift:15, 198` — showAdvanced (default false) → 27 per-key toggles and the granted directional records list are collapsed by default
- `App/UI/Settings/PrivacySettingsPages.swift:182-191` — record.capabilities != nil → Footer 'Customised for this session' and 'Back to Default' button (true for every session when an onboarding global override exists)
- `App/UI/Settings/PrivacySettingsPages.swift:161-163` — group.keys.isSubset(of: grants) → Group toggle state: any single key removed under Advanced turns the whole group OFF
- `App/UI/Settings/PrivacySettingsPages.swift:68, 166-168` — group.requiresApproval (only 'computer') → Suffix '— needs approval' on the toggle label; no approval flow follows
- `App/Core/PermissionNotifications.swift:91, 114, 133-135` — prefs.enabled && prefs.notifyPermission && project enabled && !isRunningTests → Whether any permission/approval banner is posted at all
- `App/Core/PermissionNotifications.swift:16-23, 74-85` — CapabilityCatalog.entry(for: grantKey) exists && !risky → Decidable banner (Allow Once/Deny/Open) vs sensitive (Open only). Runtime keys sessions.control/sessions.close have no entry → always sensitive
- `App/UI/SessionHeaderBar.swift:240-251` — record.provider.isAgent → McpStatusBadge shown in the session header
- `App/ControlPlane/McpStatus.swift:36-43` — McpStatusStore.isServing / lastContact[sessionID] → Badge reads off / waiting / connected
- `App/Core/Models.swift:159-176; App/Terminal/TerminalHost.swift:232; App/UI/Settings/McpSettingsPage.swift:67-76` — provider.wiresControlPlane (claude, codex, opencode) → Whether UNCOIL_* env + MCP config are injected; 'wired/not wired' on the MCP page; integration level 'Control plane' (AgentIntegration.swift:295-300). NOT used to filter the Permissions pane session picker
- `App/UI/Settings/DriverSetupSections.swift:51-63` — status?.installed / status?.path (agent-browser) → Start and Verify vs Install Chromium vs Open the Setup Guide
- `App/UI/Settings/DriverSetupSections.swift:179-190` — status?.installed (cua-driver) → Start and Verify + Set Permissions vs Open the Setup Guide
- `App/UI/Onboarding/OnboardingToolSteps.swift:211-217` — cua?.installed != true → 'Open the setup guide' button on the onboarding Cua card
- `App/UI/TaskDispatchSheet.swift:311-313` — request.permissionProfile.isEmpty → 'session default' vs 'N grants' text
- `App/UI/TaskDispatchSheet.swift:466-470` — AgentWorkingMode(rawValue: preset.permissionMode) ∈ options(for: provider) → Whether a preset's 'Permission mode' changes the dispatch working mode
- `App/UI/SessionDetailView.swift:41-45` — sessionStore.codexApprovals[record.id] != nil → In-session Codex approval panel
- `App/Hooks/SessionStore+Hooks.swift:85` — hook Notification message contains 'permission' → Status .waitingForPermission + banner for Claude sessions
- `App/Core/OnboardingState.swift:61, 87-90` — OnboardingFlow.shouldPresent(stampedVersion) (< 3) → Whether the 13-step flow (incl. Working modes, Agent capabilities, Optional tools) opens on launch
- `App/UI/Settings/McpSettingsPage.swift:18-22, 42-55` — helperPath != nil (Contents/Helpers/uncoil-mcp executable) → 'bundled' vs 'missing' on the MCP page (CLAUDE.md says the binary ships in Contents/Resources — inferred mismatch, not verified against the built bundle)

### Open questions

- Is the directional permission flow meant to cover Computer Use (as PERMISSIONS.md says) or only cross-session control (as the code does)? The answer decides whether 'Computer Use — needs approval' should be a toggle or a request.
- Does any real user need per-key toggles (Advanced Permissions) or per-session capability overrides at all, given the defaults already cover everything except Computer Use, task delete/orchestrate/worktree/merge and blueprints.write?
- Should sessions of providers that do not wire the control plane (gemini, grok, cursor, hermes, terminal) appear in permission UIs at all?
- Is the preset 'Permission mode' intended to become a working mode, or should it be removed before it is relied on?
- Should a UI-dispatched task honour the preset's grants and arguments (making the 'Permission profile' row true) or should the row go?
- What should 'default' mean once onboarding can set a global override — the engine defaults or the user's?
- Is the 'risky' distinction meant to be visible (a hint, a confirmation) or only to gate banner actions? If visible, does it need to align with default/optional?
- Is there any reason the audit log should stay UI-less if N.5 wants grants reviewable with time and requester?
- The MCP page probes Contents/Helpers/uncoil-mcp while CLAUDE.md says the binary ships in Contents/Resources — which is right for the built bundle? (not verified here)

---

## Command palette, quick actions, keyboard (App/Core/PaletteModel.swift, App/UI/CommandPalette.swift, App/Core/FuzzyScore.swift, App/Core/HotkeyBinding.swift, App/UncoilApp.swift, App/UI/ExtensionsCommands.swift, App/UI/Settings/GeneralSettingsPage.swift)

From the user's chair, Uncoil's keyboard story is "press ⌘K and type". The command palette (a VS Code-style overlay in the main window) is the single keyboard route to almost everything: opening projects and sessions, starting agents, files and artifacts, every Settings pane, the Extensions window, restarting/closing/popping out the current session, plus two typed modes ("?" asks an agent, "+" files a task into TODO.md). Outside the palette the whole app has seven real shortcuts (⌘K, ⌘,, ⌘N, ⌘B, ⇧⌘E, ⇧⌘R and a ⌘O that only works inside the menu-bar monitor), and two of those seven belong to the Extensions subsystem, which is also the only custom top-level menu in the menu bar (15 items) while Project and Session — the everyday objects — have no menu at all. Everything a mouse user does through the sidebar rail, the hover launcher strip, right-click menus, the session header and the menu-bar monitor is a separate implementation from the palette's PaletteAction → MainWindow.perform switch, so the same verb (restart, new session, popout, blueprint, debug bundle) exists in two to four places with drifting names and behaviour, and there is no registry that could give a palette row its shortcut or a menu its item. The palette is also the only home for two developer tools (Create a Test Workspace, and in practice Close the Session) and carries a "Create Worktree…" command that only navigates to the project. Configuration touches the keyboard in three places: the palette hotkey is recorded in Settings › General and again in the onboarding "Command palette" step, while every other key behaviour lives in Settings › Keyboard and Input.

### Findings

#### [CRITICAL] PAL-01 — No action registry: every command is re-implemented per surface (palette, menus, sidebar menus, header, menu-bar), with behaviour and naming drifting between copies

*Category:* coupling

- `App/Core/PaletteModel.swift:8` — enum PaletteAction: Equatable {
- `App/UI/MainWindow.swift:369` — private func perform(_ action: PaletteAction) {
- `App/UI/MainWindow.swift:413` — case .restartSession(let id):             TerminalRegistry.shared.closeTerminal(for: id)             projectStore.updateSession(id) { $0.lastActivityAt = .now }             sessionStore.bumpRestart(id)
- `App/UI/SessionDetailView.swift:171` — private func restart() {         TerminalRegistry.shared.closeTerminal(for: record.id)         projectStore.updateSession(record.id) { $0.lastActivityAt = .now }         restartToken += 1
- `App/UI/SessionGroupView.swift:265` — private func restartTargets() {         for id in targetIDs {             TerminalRegistry.shared.closeTerminal(for: id)
- `App/UI/MainWindow.swift:466` — private func launchSession(projectID: UUID, provider: AgentProvider) -> SessionRecord {
- `App/UI/SidebarView.swift:719` — private func launch(_ provider: AgentProvider, account chosen: AccountProfile? = nil) {
- `App/UI/MenuBarMonitorView.swift:188` — private func launch(project: Project, provider: AgentProvider) {
- `App/UI/AppKit/SidebarOutline.swift:929` — super.init(title: title, action: #selector(fire), keyEquivalent: "")
- `App/UI/ExtensionsCommands.swift:10` — final class ExtensionsCommandBus: ObservableObject {

**Why it matters:** Four dispatch channels coexist — PaletteAction→pendingAction→MainWindow.perform, SwiftUI Commands closures, AppKit NSMenu closures via SidebarRowActions, ExtensionsCommandBus/MainRoute/SettingsRoute singletons — and none knows about the others. 'New session' has three copies of the createSession+title logic; 'Restart' has four. Consequently a palette row cannot display its shortcut, a menu cannot be generated from the palette's list, and each new feature will again be added to whichever one or two surfaces the author remembers (Test Workspace: palette only; Close the Session: palette only; Rescan: menu only; settings panes: palette only).

**Direction:** One command table (id, title, icon, scope/enablement, shortcut, handler) that the palette, main menu, context menus and toolbars all render from.

#### [HIGH] PAL-02 — Only seven app-level shortcuts exist; the palette-plus-typing is the sole keyboard path to every everyday action

*Category:* navigation

- `App/UncoilApp.swift:85` — .keyboardShortcut("b", modifiers: .command)
- `App/UncoilApp.swift:207` — .keyboardShortcut(",", modifiers: .command)
- `App/UncoilApp.swift:213` — .keyboardShortcut("n", modifiers: .command)
- `App/UI/ExtensionsCommands.swift:43` — .keyboardShortcut("e", modifiers: [.command, .shift])
- `App/UI/ExtensionsCommands.swift:54` — .keyboardShortcut("r", modifiers: [.command, .shift])
- `App/UI/MenuBarMonitorView.swift:127` — .keyboardShortcut("o")
- `App/UI/CommandPalette.swift:266` — let binding = settings.commandPaletteHotkey
- `App/UI/CommandPalette.swift:230` — /// Installs (once) a local key monitor so ⌘K works even while a SwiftTerm view /// holds first responder (terminal views swallow key equivalents).
- `App/UI/SessionHeaderBar.swift:279` — ControlButton(                     iconName: "refresh",                     help: String(localized: "Restart the session")

**Why it matters:** Full table of what the code binds: ⌘K palette (configurable; main windows only); Esc/↑/↓/↩/⌤ inside the palette; ⌘, Settings; ⌘N New Uncoil Window; ⌘B Hide/Show Sidebar; ⇧⌘E Open Extensions; ⇧⌘R Extensions Rescan; ⌘O 'Open Uncoil' (only while the menu-bar menu is open); bare 'R' Refresh inside the branch popup (BranchBadge.swift:116); terminal-focused: ⇧↩/⌥↩ newline per provider setting, ⌘⌫/⌥⌫/⌘←/⌘→ editing bytes, ⌘V image paste (TerminalKeyHandling.swift:39-90, 204-241); Return as defaultAction in 4 sheets and Escape as Cancel in 12 sheets; NSOutlineView arrows/⌘-click in the sidebar. NO keyboard path exists for: new session in the current project, next/previous session, focus sidebar↔terminal, back to project dashboard, Tasks/Run/Tests/Issues areas, Attention Center, interrupt, restart, close, split pane, popout, Organise, worktree creation, Settings pane switching, Extensions search focus, choosing in the New Window overlay, or dismissing SheetScaffold-based sheets. In an app whose main surface swallows key equivalents, this makes the palette a bottleneck rather than an accelerator.

**Direction:** Define a small everyday shortcut set (new session, next/prev session, go to project, focus terminal, interrupt/restart) on the registry from PAL-01 and show them in palette rows.

#### [HIGH] PAL-03 — Extensions — an advanced subsystem — owns the only custom top-level menu (15 items) and two of the seven shortcuts, while Project and Session have no menu at all

*Category:* agent-leak

- `App/UI/ExtensionsCommands.swift:41` — CommandMenu("Extensions") {             Button("Open Extensions") { open(nil) }                 .keyboardShortcut("e", modifiers: [.command, .shift])
- `App/UI/ExtensionsCommands.swift:47` — ForEach(ExtensionsView.Section.allCases) { section in                 Button(section.title) { open(section) }
- `App/UI/ExtensionsCommands.swift:53` — Button("Rescan") { open(.overview, action: .rediscover) }                 .keyboardShortcut("r", modifiers: [.command, .shift])             Button("Run Health Check") { open(.overview, action: .healthCheck) }            
- `App/UncoilApp.swift:133` — .commands {             ExtensionsMenuCommands()         }
- `App/UncoilApp.swift:209` — CommandGroup(replacing: .newItem) {             Button("New Uncoil Window") {
- `CHANGELOG.md:195` — Added an Extensions menu to the menu bar: opening any Extensions screen directly, plus rediscovery, health check and a Bumblebee scan without going through the command palette.

**Why it matters:** The menu bar is the canonical place a Mac user learns an app's vocabulary; here it says the app is about MCP Catalogs, Skill Catalogs, Assignments, Sources, Security and Bumblebee, and says nothing about projects, sessions or agents. 'Bumblebee' and 'Assignments' are shown under their internal names. The everyday objects get no menu, so their actions have no discoverable shortcut column.

**Direction:** Menus should mirror the product's primary nouns (Project, Session, Agents) with Extensions folded under one of them; move ⇧⌘E/⇧⌘R to everyday actions.

#### [HIGH] PAL-04 — Palette 'Create Worktree… [project]' does not create a worktree; it only selects the project

*Category:* other

- `App/Core/PaletteModel.swift:349` — items.append(PaletteItem(                 id: "cmd.worktree.\(project.id)",                 title: String(localized: "Create Worktree… [\(project.name)]"),
- `App/UI/MainWindow.swift:406` — case .createWorktree(let projectID):             selection = .project(projectID)
- `App/UI/ProjectDashboardView.swift:269` — TextField("New worktree name (isolated task branch)", text: $newWorktreeName)
- `App/UI/ProjectDashboardView.swift:282` — Button(creatingWorktree ? "Creating…" : "Create") { createWorktree() }

**Why it matters:** A command with an ellipsis that navigates is a broken promise, and it is offered for every project in the empty palette (ranked with the current project's commands). Real creation is an inline text field on the dashboard with no focus hand-off, so the palette row is effectively a duplicate of 'open project' under a misleading name.

**Direction:** Either give the action a real dialog/prompt (name field) or remove the row until it has one.

#### [HIGH] PAL-05 — The palette is the only home for a developer tool ('Create a Test Workspace') and it is listed as an everyday command for every user

*Category:* concept-overload

- `App/Core/PaletteModel.swift:325` — PaletteItem(id: "cmd.testWorkspace", title: String(localized: "Create a Test Workspace"),                         iconName: "flask", kind: .command, action: .createTestWorkspace),
- `App/UI/MainWindow.swift:373` — case .createTestWorkspace:             do {                 let url = try TestWorkspaceService().create()                 projectStore.addProject(at: url)
- `App/Core/TestWorkspaceService.swift:26` — .appendingPathComponent("UncoilAcceptance-\(UUID().uuidString)", isDirectory: true)
- `docs/current/STATUS.md:93` — A temporary acceptance workspace created with one click from the command palette; Swift and JavaScript samples, process fixtures for success/failure/long/large output/crash, and permission-classified fake MCP tools
- `Tests/PaletteModelTests.swift:37` — func testGlobalCommandsAlwaysPresent() {         let groups = PaletteEngine.compute(baseContext(query: "", projects: []))         XCTAssertTrue(items(groups).contains { $0.action == .addProject })         XCTAssertTrue(i

**Why it matters:** 'Test Workspace' uses the same flask icon as 'One-off session' and sits beside 'Add a New Project' and 'Settings'; a new user has no way to tell it is an acceptance fixture that creates a git repo in $TMPDIR and adds it to their sidebar. It also introduces a fourth 'place to put things' next to Project, Scratch and Worktree. The unit test pins it as a permanent global command.

**Direction:** Gate behind a developer/debug flag or move to Settings › About next to Debug bundle; keep the everyday command list to everyday nouns.

#### [HIGH] PAL-06 — Provider × project matrix floods the Commands group and the 20-row cap silently drops session commands and globals

*Category:* visibility-logic

- `App/Core/PaletteModel.swift:338` — for project in ctx.projects {             let rank = project.id == ctx.currentProjectID ? currentProjectRank : 0             for provider in AgentProvider.sessionKinds {
- `App/Core/Models.swift:43` — static let sessionKinds: [AgentProvider] = allCases
- `App/Core/PaletteModel.swift:216` — private static let perGroupLimit = 20
- `App/Core/PaletteModel.swift:428` — if isEmpty {             let items = Array(candidates                 .sorted { $0.rank > $1.rank }                 .prefix(limit))
- `App/Core/PaletteModel.swift:360` — if let sid = ctx.currentSessionID {             items.append(PaletteItem(id: "cmd.restart", title: String(localized: "Restart the Session"),
- `App/Core/PaletteModel.swift:312` — for provider in ctx.launcherProviders {
- `App/Core/PaletteModel.swift:407` — for provider in AgentProvider.agents {

**Why it matters:** Per project the palette emits 8 'New Session' rows (all providers, installed or not) + Create Worktree + Apply Blueprint = 10 rows; with the ask row, N one-off rows, 5 globals and 3 session commands the group exceeds 20 with two projects. Because rank-0 rows are appended last, 'Restart/Close/Popout the Session' and often 'Settings'/'Extensions' vanish from the empty palette exactly when the user has several projects. Three different provider lists are used for three kinds of 'new session' (sessionKinds, launcherProviders, agents), so the same palette offers an uninstalled Gemini under 'New Session' but not under 'One-off'.

**Direction:** Emit 'New Session…' once for the current project (provider chosen in a second step or via launcherProviders) and use one installed-aware provider list everywhere.

#### [MEDIUM] PAL-07 — Palette hotkey is configured in two places (onboarding + Settings › General), and lives apart from every other keyboard setting

*Category:* settings-sprawl

- `App/UI/Settings/GeneralSettingsPage.swift:151` — Section("Command Palette") {                 AdaptiveRow {                     SettingsLabel(                         title: String(localized: "Shortcut"),                         detail: String(localized: "Must include 
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:225` — HotkeyRecorder(                             binding: settings.commandPaletteHotkey,                             onCapture: { settings.setCommandPaletteHotkey($0) }                         )
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:223` — detail: String(localized: "Must include ⌘ or ⌃ — ⇧ and ⌥ belong to the keyboard layout. It applies immediately — no restart, and you can change it later in Settings › General.")
- `App/UI/Settings/AgentSettingsPages.swift:472` — // Was a "Keyboard" section on the General page. Keyboard settings             // in two places is the same defect this reorganisation is for.
- `App/Core/OnboardingState.swift:21` — case palette

**Why it matters:** Onboarding asks a first-run user to make a keyboard decision before they have used the palette; the same recorder and helper paragraph are duplicated; and the code's own comment names 'keyboard settings in two places' as the defect while leaving the palette shortcut on General instead of 'Keyboard and Input'. (Also: CLAUDE.md's -onboarding-step list omits 'palette'.)

**Direction:** One 'Keyboard' page holding the palette shortcut with the other key behaviours; drop the onboarding step to a one-line mention of ⌘K.

#### [MEDIUM] PAL-08 — Palette modes are undiscoverable and fail silently: only '?' is advertised; '+', '>', 'todo:', 'task:', 'ask:', 'soru:' are hidden; no-project and no-TODO cases give no feedback

*Category:* discoverability

- `App/UI/CommandPalette.swift:79` — ? String(localized: "Search commands, find files, jump to a project… (? to ask)")
- `App/Core/PaletteModel.swift:142` — for prefix in ["?", "soru:", "ask:"] where trimmed.lowercased().hasPrefix(prefix) {
- `App/Core/PaletteModel.swift:160` — for prefix in ["+", "todo:", "task:"] where trimmed.lowercased().hasPrefix(prefix) {
- `App/Core/PaletteModel.swift:246` — if !commandsOnly, askPrompt(in: raw) != nil, ctx.currentProjectID == nil {             return []         }
- `App/Core/PaletteModel.swift:186` — guard let pid = ctx.currentProjectID,               let text = capturePrompt(in: raw), !text.isEmpty else { return [] }
- `App/UI/CommandPalette.swift:120` — Text("No result")
- `App/UI/Onboarding/OnboardingExtensionsSteps.swift:242` — detail: String(localized: "Projects and sessions by fuzzy name · start an agent on a project · tasks from your TODO.md · every settings page · the Extensions window. Arrow keys move, Return opens, Escape closes.")

**Why it matters:** The palette is a mini command language with three modes, but the UI teaches one glyph. With no project selected, '?' yields an empty 'No result' while the placeholder still promises asking. With a project that has no TODO.md, '+ fix the login bug' silently turns into a fuzzy search for that string. 'soru:' is a hard-coded Turkish prefix that works in the English interface and is not localized with the rest.

**Direction:** Show the modes as chips/hints in the empty palette, and render an explicit empty state ('Select a project to ask' / 'No TODO.md in this project') instead of an empty list.

#### [MEDIUM] PAL-09 — Session lifecycle verbs are scattered with different names per surface; 'Close the Session' exists only in the palette

*Category:* duplicate-concept

- `App/Core/PaletteModel.swift:364` — items.append(PaletteItem(id: "cmd.close", title: String(localized: "Close the Session"),
- `App/UI/MainWindow.swift:416` — case .closeSession(let id):             TerminalRegistry.shared.closeTerminal(for: id)             sessionStore.setStatus(.terminated, for: id)             projectStore.markSessionEnded(id, exitCode: nil)
- `App/UI/AppKit/SidebarOutline.swift:840` — add(to: menu, title: String(localized: "Delete the Session")) {
- `App/UI/AppKit/SidebarOutline.swift:830` — add(to: menu, title: String(localized: "Open in a New Window")) {
- `App/Core/PaletteModel.swift:367` — items.append(PaletteItem(id: "cmd.popout", title: String(localized: "Open in a Popout Window"),
- `App/UI/AppKit/SidebarOutline.swift:866` — items.append((String(localized: "Pause"), {
- `App/UI/AppKit/SidebarOutline.swift:879` — items.append((String(localized: "Hibernate"), {

**Why it matters:** A user sees Restart (header + palette), Close (palette only), Delete (sidebar), Pause/Hibernate/Wake (sidebar), Interrupt (menu bar and group view) — six verbs on one object, split across four surfaces with no single place that lists them. 'Popout Window' and 'New Window' name the same thing; 'New Uncoil Window' (⌘N) names a different one.

**Direction:** One session action set with one vocabulary, rendered identically in header overflow, context menu and palette.

#### [MEDIUM] PAL-10 — Palette settings search and the Settings window's search index different data; the palette matches titles only

*Category:* duplicate-concept

- `App/UI/MainWindow.swift:342` — settingsPanes: SettingsView.Pane.allCases.map { ($0.rawValue, $0.title) },
- `App/Core/PaletteModel.swift:290` — let panes = ctx.settingsPanes.map { pane in                 PaletteItem(                     id: "settings.\(pane.id)", title: String(localized: "Settings: \(pane.title)"),
- `App/UI/Settings/SettingsView.swift:186` — /// Search terms (Turkish + English) matched by the filter box. They name         /// the *settings inside* the page, not the page
- `App/UI/Settings/SettingsView.swift:190` — "varsayılan default editör editor agent dil language kapanış quit çıkış kısayol hotkey komut paleti palette"

**Why it matters:** Typing 'hotkey' or 'paste' in ⌘K finds nothing, while the same words work in Settings › search. Two search boxes, two indexes, two behaviours for the same 24 panes — and the palette lists panes by ambiguous titles ('Settings: General' appears twice conceptually since Notifications also has a 'General' pane, SettingsView.swift:129 and 139).

**Direction:** Feed the palette the pane keywords and category path ('Settings › Notifications › General').

#### [MEDIUM] PAL-11 — Debug Bundle and Apply Blueprint are hosted twice each with separate state and result UI

*Category:* duplicate-concept

- `App/UI/MainWindow.swift:384` — case .createDebugBundle:             do {                 let result = try DebugBundleService().create()                 debugBundleURL = result.bundleURL                 debugBundleMessage = "Created: \(result.bundleURL
- `App/UI/Settings/AboutSettingsPage.swift:117` — private func createDebugBundle() {         do {             debugBundleURL = try DebugBundleService().create().bundleURL
- `App/UI/MainWindow.swift:298` — .sheet(item: $blueprintProject) { project in             ApplyBlueprintSheet(project: project)
- `App/UI/SidebarView.swift:213` — .sheet(item: $blueprintProject) { project in             ApplyBlueprintSheet(project: project)

**Why it matters:** Same service, two result presentations (an alert with Show in Finder vs a settings footer). The blueprint sheet is mounted in both MainWindow and SidebarView because the palette and the context menu cannot share a presenter — another symptom of PAL-01.

**Direction:** Single presenter per action; the palette should invoke the same closure the context menu does.

#### [MEDIUM] PAL-12 — Palette hotkey ignores the onboarding overlay; ⌘K during first run opens a hidden palette that captures navigation keys (inferred from code)

*Category:* visibility-logic

- `App/UI/MainWindow.swift:67` — ZStack {             mainContent             if palette.isOpen {                 CommandPaletteOverlay(model: palette)             }             // Setup covers the app rather than sitting beside it             if onboar
- `App/UI/CommandPalette.swift:267` — if binding.matches(keyCode: event.keyCode,                                modifiers: event.modifierFlags.rawValue),                !isAuxiliaryWindow(event.window) {                 model.toggle()
- `App/UI/CommandPalette.swift:274` — guard model.isOpen else { return event }             switch event.keyCode {             case 53: model.close(); return nil                       // Escape             case 125: model.move(1); return nil

**Why it matters:** Feature-visibility is decided in three unrelated places (the ZStack order, isAuxiliaryWindow's string match on window identifiers, and the missing onboarding check), so a new full-window state will again need its own patch. Not visually verified; derived from the ZStack order and the monitor's conditions.

**Direction:** A single 'palette available' predicate owned by the window model.

#### [MEDIUM] PAL-13 — 'Shortcut' and 'Quick Launch' mean launcher buttons in some copy and keyboard chords in other copy

*Category:* terminology

- `App/UI/Settings/LauncherSettingsPage.swift:31` — Text("Drag to reorder. At least one shortcut stays — without one there is no way to start a session from the project screen.")
- `App/UI/Settings/MenuBarSettingsPage.swift:129` — Toggle(isOn: bind(\.showQuickLaunch)) {                     SettingsLabel(title: String(localized: "New-session menu"))
- `App/UI/Settings/GeneralSettingsPage.swift:154` — title: String(localized: "Shortcut"),
- `docs/current/STATUS.md:70` — **Organise automatically** — the shortcut on the project dashboard starts a Claude session
- `App/UI/MenuBarMonitorView.swift:113` — ForEach(AgentProvider.sessionKinds) { provider in

**Why it matters:** 'Quick Launch' (settings page) = 'strip' (code) = 'shortcuts' (page copy) = 'New-session menu' (menu-bar setting, which then ignores the Quick Launch order). Meanwhile 'Shortcut' in General means a key chord. The user cannot form a model of what 'shortcut' refers to.

**Direction:** Reserve 'shortcut' for keys; call the strip one thing everywhere and make the menu-bar menu obey it.

#### [LOW] PAL-14 — Keyboard dismissal of sheets and overlays is inconsistent; SheetScaffold-based sheets and the New Window overlay have no Escape path

*Category:* navigation

- `App/UI/TaskCreateSheet.swift:127` — .keyboardShortcut(.escape, modifiers: [])
- `App/UI/Settings/AgentSettingsPages.swift:708` — .keyboardShortcut(.cancelAction)
- `App/UI/Components/SheetChrome.swift:14` — struct SheetScaffold<Content: View, Actions: View>: View {
- `App/UI/NewProjectSheet.swift:101` — Button(String(localized: "Cancel")) { cancel() }
- `App/UI/WindowOverlays.swift:26` — ForEach(options) { option in                         Button {                             choose(option.choice)

**Why it matters:** Twelve sheets bind Escape explicitly, one uses .cancelAction, and the shared scaffold used by NewProjectSheet, ApplyBlueprintSheet, BlueprintEditorSheet, ProjectCustomizeSheet (plus TaskDispatchSheet, TaskMergeSheet, HandoffSheet) binds nothing, so Escape behaviour depends on which file the sheet was written in (inferred: SwiftUI sheets on macOS need a cancelAction binding to react to Escape). The New Window overlay that ⌘N raises has no keyboard path at all.

**Direction:** Put Escape/Return handling into SheetScaffold and the overlays once.

#### [LOW] PAL-15 — Palette exposes internal-ish nouns and mixed naming styles in row titles

*Category:* terminology

- `App/Core/PaletteModel.swift:344` — title: String(localized: "New Session: \(provider.displayName) [\(project.name)]"),
- `App/Core/PaletteModel.swift:314` — title: String(localized: "One-off \(provider.displayName) session"),                 subtitle: String(localized: "In Uncoil's scratch folder, outside every project"),
- `App/Core/PaletteModel.swift:353` — title: String(localized: "Apply Blueprint… [\(project.name)]"),
- `App/UI/ExtensionsCommands.swift:56` — Button("Run Bumblebee Scan") { open(.security, action: .bumblebeeScan) }

**Why it matters:** 'Scratch', 'Blueprint', 'Bumblebee', 'Popout', 'Artifacts' are shown under their internal names with no in-palette explanation; row titles mix 'Verb: Object [project]' with 'Verb Object… [project]' and sentence-case subtitles, so scanning the list relies on reading every row.

**Direction:** One title grammar (verb + object), project shown as subtitle, internal nouns explained or renamed.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| Command palette overlay | panel | `App/UI/CommandPalette.swift` | ⌘K (configurable) via PaletteHotkeyMonitor (CommandPalette.swift:266-272); Title-bar search button 'Open the command palette (⌘K)' (SidebarView.swift:507-510, hosted by TitlebarControls.swift:66); No  |
| Palette ask banner | banner | `App/UI/CommandPalette.swift` | Type '?', 'ask:', 'soru:' or a trailing '?' (PaletteModel.swift:139-149); Run the 'Ask an agent…' command which sets query to '? ' (PaletteModel.swift:557-561) |
| Main menu bar: App / File / View commands | menu | `App/UncoilApp.swift` | Menu bar |
| Extensions menu (top-level menu) | menu | `App/UI/ExtensionsCommands.swift` | Menu bar, always |
| Title-bar controls cluster | toolbar | `App/UI/SidebarView.swift` | Always visible in main windows |
| Sidebar rail (bottom) | toolbar | `App/UI/SidebarView.swift` | Sidebar visible |
| Sidebar right-click menus | menu | `App/UI/AppKit/SidebarOutline.swift` | Right-click |
| Agent launcher strip (hover) | hover-control | `App/UI/SidebarView.swift` | Hover only |
| Menu-bar monitor menu | menu | `App/UI/MenuBarMonitorView.swift` | Menu bar extra, when settings.menuBar.isVisible |
| Settings › General › Command Palette | row | `App/UI/Settings/GeneralSettingsPage.swift` | Settings › General; Palette 'Settings: General' row |
| Onboarding › Command palette step | screen | `App/UI/Onboarding/OnboardingExtensionsSteps.swift` | First run; Settings › About › Setup guide 'Run again' (AboutSettingsPage.swift:70-82) |
| Settings › Keyboard and Input | screen | `App/UI/Settings/AgentSettingsPages.swift` | Settings › General › Keyboard and Input |
| Settings › About › Support › Debug bundle | row | `App/UI/Settings/AboutSettingsPage.swift` | Settings › About |
| Session header bar | toolbar | `App/UI/SessionHeaderBar.swift` | Session selected |
| Project dashboard › Worktrees panel | panel | `App/UI/ProjectDashboardView.swift` | Project selected |
| New Window overlay | panel | `App/UI/WindowOverlays.swift` | ⌘N / File › New Uncoil Window |

### Concepts

- `U!` **Command palette** — ⌘K overlay that fuzzy-searches commands, projects, sessions, files, artifacts and settings panes, and hosts the ask/capture modes. *Overlaps:* Settings search (.searchable, SettingsView.swift:267), Extensions 'Search everywhere' field (ExtensionsView.swift:240), Extensions menu (section jumps)
- `U` **Palette group** — PaletteGroupKind: ask, capture, command, project, session, file, artifact, settings — the section headers in the result list (PaletteModel.swift:48-70).
- `U` **Query prefixes / modes** — '>' = commands only (PaletteModel.swift:227); '?', 'ask:', 'soru:' or trailing '?' = ask mode (139-149); '+', 'todo:', 'task:' = capture mode (156-164). Ask beats capture beats search (236-245). *Overlaps:* Tasks screen TaskCreateSheet (another way to add a task), Session prompt (another way to ask)
- `i` **PaletteAction** — Internal enum of 20 cases the palette can emit; MainWindow.perform performs them (PaletteModel.swift:8-33, MainWindow.swift:369-436). *Overlaps:* ExtensionsCommandBus.QuickAction, SidebarRowActions, MainRoute.request, SettingsRoute.requestedPane
- `U` **Hotkey / HotkeyBinding** — keyCode + canonical modifiers, persisted as settings.json 'commandPaletteHotkey' (nil ⇒ ⌘K) (HotkeyBinding.swift:10-25, SettingsStore.swift:44-45, 803, 854). Requires ⌘ or ⌃ (isTextSafe, HotkeyBinding.swift:50-53).
- `U!` **Quick Launch (launcher strip)** — LauncherPrefs.order resolved against installed CLIs (LauncherPrefs.swift:29-45; SettingsStore.swift:282). Drives the hover strip, the palette's one-off rows, the sidebar empty-area menu and the Extension picker tabs. *Overlaps:* Menu-bar 'New Session' submenu, Palette 'New Session: X [project]' rows (sessionKinds, all providers)
- `U!` **One-off session / Scratch workspace** — A session in Uncoil's own scratch folder, outside every project (PaletteModel.swift:10-12, ProjectStore.swift:54-67). *Overlaps:* Test Workspace (another 'somewhere to try things' folder)
- `U!` **Test Workspace (acceptance workspace)** — TestWorkspaceService creates a temp git repo 'UncoilAcceptance-<uuid>' with Swift/JS samples, scripts and a fake MCP, then adds it as a project (TestWorkspaceService.swift:25-49, MainWindow.swift:373-383). Documented under 'Development infrastructure' (docs/current/STATUS.md:93). *Overlaps:* Scratch workspace, Add a New Project
- `U!` **Debug Bundle** — DebugBundleService zips sanitised logs/config (DebugBundleService.swift:13).
- `U!` **Blueprint** — A stored setup prompt handed to a new session (Blueprint.swift, BlueprintStore.swift).
- `U!` **Worktree** — git worktree under .uncoil-worktrees/<slug>; sessions can be started inside one.
- `U!` **Popout / New Window** — Terminal-only 'session-window' scene sharing the PTY (UncoilApp.swift:91-102).
- `U` **Session lifecycle verbs** — Restart (header, palette, group bulk, settings), Close (palette only: terminate + markSessionEnded), Delete (sidebar menu: remove record), Pause/Hibernate/Wake (sidebar menu), Interrupt (menu bar, group bulk).
- `U` **Extensions quick action** — ExtensionsCommandBus.QuickAction: rediscover / healthCheck / bumblebeeScan, posted on a shared bus and consumed by the Extensions window (ExtensionsCommands.swift:10-32).
- `U` **Settings pane (deep link)** — SettingsView.Pane rawValue routed via SettingsRoute.shared.requestedPane (MainWindow.swift:410-412). *Overlaps:* Settings window's own search, which matches per-pane keyword strings the palette never sees (SettingsView.swift:186-192)

### Flows

- **Start an agent on the current project from the keyboard** (4 steps) — friction: No direct shortcut exists for 'new session in current project'; the only keyboard path is palette + typing. The palette lists every provider Uncoil knows (AgentProvider.sessionKinds, all 8) for every project, while the one-off rows and the sidebar strip list only installed ones (launcherProviders). With ≥2 projects the Commands group overflows its 20-row cap and rank-0 rows (Restart/Close/Popout the Session, Settings, Extensions) drop out of the empty palette.
- **Ask a quick question** (4 steps) — friction: With no project selected the palette returns an empty list — 'No result' — although the placeholder still says '(? to ask)' (PaletteModel.swift:246-248). 'soru:' is a hard-coded Turkish prefix in an otherwise English UI. The new-session targets are not filtered by installed CLIs.
- **Capture a task into TODO.md** (3 steps) — friction: The '+' prefix is advertised nowhere in the UI (placeholder mentions only '?'; onboarding says 'tasks from your TODO.md' without the prefix). If the project has no task file, '+ fix bug' silently becomes a fuzzy search for '+ fix bug' (PaletteModel.swift:186-188; Tests/PaletteCaptureTests.swift:87). Failures surface only as an Attention Center row (MainWindow.swift:471-479).
- **Create a worktree from the palette** (3 steps) — friction: The command's ellipsis promises a dialog; nothing is created and no field is focused. It is indistinguishable from 'open project'.
- **Change the palette hotkey** (4 steps) — friction: Same control and same 60-word helper text in two places; the setting lives under General while every other key behaviour lives under Keyboard and Input. Onboarding asks a first-run user to decide a hotkey before they have used the palette once.
- **Reach an Extensions screen or quick action** (3 steps) — friction: The palette offers only 'Extensions' (open the window) and cannot jump to a section or run a quick action, whereas the menu can; conversely the menu cannot reach Settings panes, which only the palette deep-links. Two different 'ask a window to do X' channels (bus vs PaletteAction/SettingsRoute).
- **Keyboard-only session navigation (gap)** (3 steps) — friction: A terminal-centric app where the terminal swallows key equivalents (CommandPalette.swift:230-233) and the only escape hatch is a typed search.

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| commandPaletteHotkey | global | settings.json (SettingsStore.swift:44-45, 98, 803, 854); nil ⇒ ⌘K | Settings › General › Command Palette (GeneralSettingsPage.swift:151-168) AND Onboarding › Command palette step (OnboardingExtensionsSteps.swift:216-236) |  |
| launcher.order (Quick Launch strip) | global | settings.json LauncherPrefs (SettingsStore.swift:282; LauncherPrefs.swift:9-14) | Settings › Appearance › Quick Launch (LauncherSettingsPage.swift) | yes |
| menuBar.showQuickLaunch | global | settings.json MenuBarPrefs (MenuBarPrefs.swift:103) | Settings › Appearance › Menu Bar › 'New-session menu' (MenuBarSettingsPage.swift:129-131) | yes |
| sidebarVisible | global | @AppStorage UserDefaults (UncoilApp.swift:22; MainWindow.swift:31) | View › Hide/Show Sidebar ⌘B; title-bar toggle; drag divider under 120pt (MainWindow.swift:231-239) |  |
| optionAsMetaKey | global | settings.json (SettingsStore.swift:109-111) | Settings › Keyboard and Input (AgentSettingsPages.swift:474-487) |  |
| shiftEnterNewline (per provider) | global | settings.json providerBehaviors (SettingsStore.swift:94-96) | Settings › Keyboard and Input, one toggle per agent provider (AgentSettingsPages.swift:490-506) | yes |
| imagePasteMode | global | settings.json (SettingsStore.swift:61, 106) | Settings › Keyboard and Input › Clipboard (AgentSettingsPages.swift:510-530) | yes |
| TerminalMetalEnabled | global | UserDefaults, `defaults write` only (TerminalKeyHandling.swift:125-130) | Nowhere in the UI | yes |
| collapsedProjects | global | UserDefaults stringArray (SidebarView.swift:655-690) | Sidebar chevron, context menu Show/Hide Sessions, rail Collapse-all |  |

### Visibility gates

- `App/Core/PaletteModel.swift:302-306` — ctx.currentProjectID != nil → 'Ask an agent…' command row (rank 30)
- `App/Core/PaletteModel.swift:246-248` — askPrompt(in: raw) != nil && ctx.currentProjectID == nil && !commandsOnly → Returns [] — palette shows 'No result' with no explanation
- `App/Core/PaletteModel.swift:186-188, 584-626` — currentProjectID != nil && capturePrompt non-empty && captureTargets non-empty → Capture a Task group; otherwise '+text' falls through to fuzzy search
- `App/Core/PaletteModel.swift:236-245` — asks non-empty / captures non-empty → Ask or capture mode replaces every other group (ask wins over capture)
- `App/Core/PaletteModel.swift:227-229, 254` — raw.hasPrefix('>') → Projects/Sessions/Files/Artifacts hidden; Commands + Settings only
- `App/Core/PaletteModel.swift:270, 288-290` — !isEmpty (query non-empty) → Files, Artifacts and Settings groups exist only while typing
- `App/Core/PaletteModel.swift:312-320; App/UI/MainWindow.swift:343-345` — ctx.launcherProviders (LauncherPrefs resolved vs installed) → 'One-off <Provider> session' rows
- `App/Core/PaletteModel.swift:338-348` — AgentProvider.sessionKinds (all 8, unfiltered) × every project → 'New Session: <Provider> [project]' rows
- `App/Core/PaletteModel.swift:407-416` — AgentProvider.agents (unfiltered) → 'New <Provider> session' ask targets
- `App/Core/PaletteModel.swift:360-371` — ctx.currentSessionID != nil → Restart / Close / Popout the Session commands
- `App/Core/PaletteModel.swift:216-217, 428-433` — perGroupLimit = 20 after rank sort; fileLimit = 30 → Rank-0 commands (globals, other projects, session commands) truncated in the empty palette once commands exceed 20
- `App/UI/CommandPalette.swift:285-294` — window.identifier contains 'settings' or 'session-window' → Palette hotkey suppressed in Settings and popout windows; Extensions window is NOT excluded but has no registered model so nothing happens (CommandPalette.swift:253-256, 262)
- `App/UI/MainWindow.swift:67-76 (ZStack: mainContent, palette, then OnboardingView on top); App/UI/CommandPalette.swift:266-272` — onboarding.isPresenting — NOT checked by the hotkey monitor → ⌘K during first run opens a palette beneath the onboarding overlay which then owns Esc/↑/↓/Return (inferred from code)
- `App/UncoilApp.swift:195-201` — UpdaterService.shared.isAvailable → 'Check for Updates…' menu item
- `App/UI/ExtensionsCommands.swift:41-57; App/UncoilApp.swift:133-135` — always → Extensions top-level menu with 15 items is present regardless of window or state
- `App/UI/MenuBarMonitorView.swift:109-121` — settings.menuBar.showQuickLaunch && !projectStore.projects.isEmpty → Menu-bar 'New Session' submenu
- `App/UI/AppKit/SidebarOutline.swift:732-750` — project.isScratchWorkspace → Reduced context menu (no Pin/Move/Blueprint/Customise) for the scratch project
- `App/UI/MainWindow.swift:265-272` — !onboarding.isPresenting → Title-bar sidebar toggle + palette button
- `App/Core/HotkeyBinding.swift:50-53; App/UI/Settings/GeneralSettingsPage.swift:209-210` — HotkeyBinding.isTextSafe (⌘ or ⌃ present) → Whether a recorded chord is accepted; otherwise silently ignored until the user adds a modifier

### Open questions

- Is 'Create a Test Workspace' meant to ship to end users, or is it a leftover from the Computer-Use acceptance flow (STATUS.md files it under Development infrastructure)?
- Is the palette's 'Create Worktree…' intentionally navigation-only (an unfinished action) or a regression from an earlier dialog?
- Should the menu-bar 'New Session' submenu obey Quick Launch order/installed filtering like every other launcher, or is offering every provider there deliberate?
- Is 'soru:' meant to be a localized alias (only for Turkish UI) or a permanent hidden prefix?
- Which of the four dispatch channels (PaletteAction, Commands, SidebarRowActions, singleton buses) is intended to become canonical when a registry is introduced?
- Is the onboarding 'Command palette' step meant to stay once the hotkey lives in a Keyboard settings page?
- Should the palette expose Extensions sections and quick actions (Rescan, Health Check, Bumblebee) the way the menu does, or should the menu shrink instead?

---

## Product intentions and pending plans (TODO.md, CHANGELOG.md, docs/current/STATUS.md, docs/current/RUN_PREVIEW.md, docs/roadmap/RUN_PREVIEW_PLAN.md, docs/roadmap/FOUNDATION_PLAN.md §2/3/8/9/16-21, README.md, TODO-archive-0.1.0.md) cross-checked against the code they describe

From the user's side, Uncoil is (per the plan's one sentence, FOUNDATION_PLAN.md:75) "a native macOS control center for running, observing, and coordinating multiple AI coding agents across isolated projects, worktrees, accounts, and tool configurations", and per the README's shorter framing "Your entire development universe, finally connected" for "Claude Code, Codex and Gemini CLI" (README.md:8-9). What the documents actually record, release by release, is a product that started as 'one window, honest agent status, terminals that survive' (2026-07-23/24 entries) and then, in two releases, accreted: a 13-step first-run window, a 6-category/24-pane Settings window, an 11-section Extensions window, a project dashboard with up to five tabs plus a Customize sheet, per-project JSON files under .uncoil/, a usage ring and handoff sheet in the session header, an eight-tool MCP control plane whose tool names are shown to first-run users, and eight agent brands across two separate rosters. The product's own backlog already says the first-run flow "answers each question and does not hold together" (TODO.md:83-84), that permission requests arrive by four routes into different UIs (TODO.md:139-142), and that the docs contradict each other (six vs eight tools, three vs seven-plus-one agents, 8 vs 6 settings categories, nine vs thirteen onboarding steps). Pending plans (N.7.5 rules engine, N.5 permission rewrite, N.2 onboarding rewrite, N.4 driver setup rewrite) each add or relocate a surface, and none names where it lands.

### Findings

#### [CRITICAL] P1 — Four generations of 'a saved way to start an agent' coexist: Launch Profile (plan), Session Preset, Blueprint, Quick Launch — plus the dispatch sheet's own model/effort/mode

*Category:* duplicate-concept

- `docs/roadmap/FOUNDATION_PLAN.md:606` — ### 8.5 Launch Profile … var initialPromptTemplate … var permissionMode … var mcpSetID … Show a complete launch preview.
- `docs/current/STATUS.md:46` — Agent Settings holds a persistent session-preset editor for the provider, CLI arguments, opening prompt, permission mode and capability bounds
- `CHANGELOG.md:17` — Blueprints: the prompt you always write when you start a project of a certain shape, kept and named.
- `App/UI/Settings/SettingsView.swift:78` — case presets         case blueprints
- `App/UI/TaskDispatchSheet.swift:291` — String(localized: "Preset")
- `CHANGELOG.md:188` — Added model, effort and working-mode selection to task dispatch — in both the dispatch sheet and the bulk-start sheet

**Why it matters:** A user meets 'Session Presets' and 'Blueprints' as sibling Settings pages under Agents, 'Preset' in the dispatch sheet, a Quick Launch strip in Appearance, and per-provider Run Parameters/Working Mode matrices — all answering 'how does an agent start'. Each new start path (handoff destination, Fix with agent, Write One With an Agent, one-off session) picks one of them ad hoc, so the count compounds.

**Direction:** Record one 'launch recipe' concept and derive presets, blueprints and dispatch options as views of it.

#### [CRITICAL] P2 — The first-run flow has grown from nine to thirteen steps, duplicates six Settings pages, and the backlog already calls it the worst thing about the product

*Category:* onboarding

- `CHANGELOG.md:160` — Added a first-run flow, in its own window, over nine skippable steps
- `App/Core/OnboardingState.swift:9` — enum OnboardingStep … case welcome, clis, accounts, workingModes, hooks, notifications, capabilities, tools, project, tasks, extensions, palette, finish
- `App/Core/OnboardingState.swift:56` — /// 3: the working-mode and optional-tools steps.     static let currentVersion = 3
- `TODO.md:83` — The individual gaps in Stage 36 were closed one at a time, and the result is a flow that answers each question and does not hold together. This is a rewrite, not another patch.
- `TODO.md:88` — Cut the steps that do not have to be answered before first use. Anything Uncoil can detect, default, or ask for later does not belong in setup.
- `TODO.md:490` — N.2 — setup, rewritten. Every new user meets it, and it is currently the worst thing about the product.
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:311` — Uncoil hands every session an MCP server of its own, so the agent can talk back: eight tools, each one gated by a capability you control.

**Why it matters:** Working modes, hooks, notifications, capabilities, drivers and extensions adoption each exist as a Settings page and as an onboarding step; the version gate re-opens the flow for existing users whenever a step is added, so every feature that adds a step taxes every installed copy. The intention to cut is already written (N.2) and agrees with simplification.

**Direction:** Treat N.2's 'detect the CLIs, pick one project, start' as the whole required path; everything else is a Settings page reachable later.

#### [CRITICAL] P3 — Two agent rosters (AgentProvider vs Extensions AgentKind) and three public counts (three / seven / eight) — no single registry says which agents exist and what each can do

*Category:* agent-leak

- `README.md:48` — ### Three agents, one window  Claude Code, Codex and Gemini CLI
- `App/Core/Models.swift:20` — enum AgentProvider … case claude, codex, gemini, opencode, grok, hermes, cursor, terminal
- `App/Extensions/ExtensionModels.swift:90` — [.claudeCode, .codex, .geminiCLI, .cursor, .amp, .opencode, .grok, .hermes]
- `App/Extensions/AgentIntegration.swift:114` — // Uncoil never launches Amp, so there is no session to wire
- `CHANGELOG.md:33` — Settings › Agents › Installed Agents lists every agent it knows — Claude Code, Codex, Gemini CLI, OpenCode, Grok, Cursor and Amp
- `README.md:64` — Each profile gets an isolated config directory (`CLAUDE_CONFIG_DIR`, `CODEX_HOME` and the Gemini equivalent)
- `App/Core/Models.swift:521` — // No verified variable for an isolated Gemini config root, so Uncoil does not claim to isolate one … case .gemini: nil

**Why it matters:** Per-agent capability (hooks, control plane, isolation var, resume, working modes, skill scoping) is spread over AgentProvider switch statements, AgentIntegration ceilings, adapters and CHANGELOG prose. The README makes a claim (Gemini isolation) the code explicitly refuses. Every per-provider Settings matrix multiplies by this roster.

**Direction:** One provider descriptor (the plan's §8.3 AgentProviderDescriptor) as the source for every list, matrix and doc count.

#### [HIGH] P4 — Settings › Agents has seven panes; five iterate every provider as a matrix, and two of them (Installed Agents, CLI Tools) overlap with the Extensions › Agents screen and with each other

*Category:* settings-sprawl

- `App/UI/Settings/SettingsView.swift:76` — case installedAgents         case accounts         case cliTools         case launchArgs         case agentBehavior         case presets         case blueprints
- `App/UI/Settings/AgentSettingsPages.swift:13` — private let providers: [AgentProvider] = AgentProvider.agents
- `CHANGELOG.md:32` — Settings › Agents is the home for this — every row there has a "Locate…" button, installed or not — and the Extensions window's card offers the same thing so acting in either place is the same act.
- `CHANGELOG.md:33` — The same list opens the Extensions window's Agents screen.
- `CHANGELOG.md:125` — Settings were reorganised around six categories instead of eight. Four of the old ones held a single page

**Why it matters:** The 0.1.0 reorganisation removed empty categories but did not merge overlapping pages; 0.2.0 then added Installed Agents (a fourth 'which agents are here' page after CLI Tools, Accounts and Extensions › Agents) and Blueprints. Sprawl is per-provider × per-page.

**Direction:** One agent page per provider (installed, path, version, account, mode, args) instead of one page per attribute across providers.

#### [HIGH] P5 — STATUS.md is frozen at 2026-07-25 and contradicts the code on tool count, test count, settings tree and pane names; CAPABILITIES.md and CLAUDE.md disagree with each other

*Category:* other

- `docs/current/STATUS.md:3` — Last updated: 2026-07-25 · Tests: 198/198
- `docs/current/STATUS.md:51` — **Six MCP tools** open a bounded surface to agents: `uncoil_projects / uncoil_sessions / uncoil_artifacts / uncoil_system / uncoil_browser / uncoil_computer`
- `docs/current/mcp/CAPABILITIES.md:3` — Six MCP tools (capabilities).
- `McpHelper/main.swift:27` — ToolDef(name: "uncoil_projects" … uncoil_sessions … uncoil_artifacts … uncoil_tasks … uncoil_run … uncoil_system … uncoil_browser … uncoil_computer
- `docs/current/STATUS.md:75` — **General** … · **Agents** (Accounts / CLI Tools / Parameters / Mode and Keyboard / Session Presets) · **Notifications** … · **Menu Bar** · **Appearance** · **Privacy and Permissions** … · **Integrations** (GitHub / Driv
- `CHANGELOG.md:154` — All 1418 tests pass.
- `docs/current/STATUS.md:5` — A new session should read this file first, then the relevant agent instructions.

**Why it matters:** The document that tells a new reader (or agent) to read it first describes a product two releases old: no Tasks, Run, Tests, Issues, Extensions, Usage, Handoff, Blueprints, Installed Agents, Hermes/OpenCode/Grok/Cursor. Anyone restructuring from STATUS.md would restructure the wrong product.

**Direction:** Either retire STATUS.md's inventory in favour of the CHANGELOG or regenerate it from the enums (Category/Pane, ProjectArea, OnboardingStep, Extensions.Section, AgentProvider, ToolDef).

#### [HIGH] P6 — Claude-specific mechanisms are exposed under generic global names: 'Agent Status Hooks' pane, 'Status tracking' onboarding step, and a Working Mode matrix — against the plan's provider-neutral principle

*Category:* agent-leak

- `docs/roadmap/FOUNDATION_PLAN.md:123` — 4. **Provider-neutral core** … Core models must not depend on Claude-specific terminology.
- `App/UI/Settings/PrivacySettingsPages.swift:346` — String(localized: "Agent Status Hooks") … "Claude Code's hooks are what make session states stream into Uncoil live."
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:85` — Codex has no hook system. Uncoil follows its sessions through the CLI itself
- `CHANGELOG.md:31` — Hermes reports what it is doing, the way Claude Code does. It is the only other agent with a real hook system
- `CHANGELOG.md:59` — Codex's permission mode is Codex's again. Every launch carried `--sandbox` and `--ask-for-approval` whether or not anyone had opened the setting … "Provider default" is offered, and it is the default, for every agent.

**Why it matters:** A global 'Agent Status Hooks' page under the Uncoil category applies to two of seven agents; the Working Mode matrix was found in 0.2.0 to have been overriding every Codex user's own config. Provider mechanisms shown as product-wide settings mislead the six-of-seven agents they do not apply to.

**Direction:** Fold hooks/working-mode/isolation into the per-agent page as 'what this agent supports', reading from the descriptor.

#### [HIGH] P7 — N.7.5 (usage rules engine) would add a rules editor, per-project overrides, a fallback chain, model choice and a handoff history — and plan §3.2 listed a usage dashboard as a non-goal

*Category:* coupling

- `TODO.md:386` — ### N.7.5 The rules engine and its settings … A rule is: *when account A drops below N%, hand off to B*.
- `TODO.md:394` — Let rules be scoped per project, and let a project override the global one.
- `TODO.md:399` — Show every handoff that has happened, with its rule and its package.
- `TODO.md:291` — chosen in Settings › General › Provider Limits
- `App/UI/Settings/GeneralSettingsPage.swift:91` — Section("Provider Limits")
- `docs/roadmap/FOUNDATION_PLAN.md:202` — - Usage/cost analytics dashboard
- `TODO.md:311` — Decide whether the figure belongs anywhere else — the menu-bar monitor is plausible

**Why it matters:** Today's threshold already sits under General rather than with accounts. Built as written, N.7.5 needs a rules list, a per-project override (a third project-config location), a history view and probably a menu-bar section — none placed. It is the next feature and the one most likely to add a Settings category.

**Direction:** Decide the home for 'accounts and their limits' before building rules; per-project override should live where other per-project overrides live.

#### [HIGH] P8 — Project-level configuration is spread across seven places with no 'project settings'

*Category:* navigation

- `App/UI/ProjectCustomizeSheet.swift:18` — case .identity: String(localized: "Identity")             case .extensions: String(localized: "MCP & Skills")
- `App/UI/Settings/NotificationSettingsPages.swift:426` — title: String(localized: "Per Project")
- `App/Core/ProjectAreaAvailability.swift:45` — /// What the General page offers when this area has nothing yet.
- `docs/current/RUN_PREVIEW.md:9` — Everything is in the repo-owned **`.uncoil/run.json`**. The app holds no hidden copy
- `CHANGELOG.md:17` — A blueprint can also be applied to a project you already have, from its right-click menu or the command palette.
- `docs/roadmap/FOUNDATION_PLAN.md:1417` — - Projects

**Why it matters:** The plan had a 'Projects' settings page; shipped reality is Customize (2 tabs) + Settings › Notifications › Per Project + General-page offers + three .uncoil/ files + right-click + palette. N.7.5's per-project override would be an eighth.

**Direction:** One project settings surface that hosts identity, extensions scope, notifications, run/tests defaults and future overrides.

#### [HIGH] P9 — The 'show only what exists' rule is implemented for dashboard tabs only; Settings, onboarding and Extensions show every page regardless of what is installed

*Category:* visibility-logic

- `App/Core/ProjectAreaAvailability.swift:5` — Every area used to be offered on every project, so a folder with no TODO.md, no run configuration and no GitHub remote still showed five tabs — four of them leading to an empty page.
- `TODO.md:98` — Handle the empty cases properly — no CLI installed, no project, no account. Today these read as failures rather than as the ordinary starting state.
- `CHANGELOG.md:32` — every row there has a "Locate…" button, installed or not
- `App/UI/Settings/SettingsView.swift:100` — case .permissions, .mcp, .hooks, .drivers, .github, .privacyData: .uncoil

**Why it matters:** Drivers, Agent Status Hooks, GitHub and Blueprints panes appear for a user with no Cua, no Claude, no token and no blueprint; the product has already articulated the opposite rule for one surface (inferred: the ProjectAreaAvailability pattern is reusable but not reused).

**Direction:** Apply the ProjectAreaAvailability shape (facts → visible areas → offers) to Settings panes and Extensions sections.

#### [MEDIUM] P10 — Internal names are user-facing: Session Presets, Capabilities, Control plane, Drivers, Agent Status Hooks, adapter, and raw MCP tool names / grant keys in first-run copy

*Category:* terminology

- `App/UI/Onboarding/OnboardingPlatformSteps.swift:249` — uncoil_sessions — the agent sees the other sessions in its project and can start a child agent. No raw shell is ever accepted
- `App/UI/Onboarding/OnboardingPlatformSteps.swift:301` — keys: ["tasks.delete", "tasks.merge"]
- `App/UI/Settings/McpSettingsPage.swift:29` — String(localized: "Control plane")
- `App/UI/Settings/McpSettingsPage.swift:92` — Button(String(localized: "Capabilities…")) { SettingsRoute.shared.requestedPane = SettingsView.Pane.permissions.rawValue
- `App/UI/ExtensionsView.swift:974` — each moves up once an adapter for its config format lands.
- `App/UI/Settings/AgentSettingsPages.swift:640` — Cannot be changed; child agents ask for the preset by this name.

**Why it matters:** A first-run user is asked to decide grants by MCP tool name before they have a project. 'Capabilities…' navigates to a pane called 'Permissions' — the same thing under two names one click apart.

**Direction:** Name things by consequence (N.5's own rule: 'State the request in terms of consequence, not capability', TODO.md:145-146).

#### [MEDIUM] P11 — Permission has four arrival routes, three axes (working mode, capability grant, directional session permission) and three UIs — and N.5 records this as a rewrite target

*Category:* concept-overload

- `TODO.md:139` — Map every route a permission request can arrive by today — the control plane, Claude's hooks, Codex's structured approvals, macOS's own prompts — and the different UI each one currently ends up in.
- `TODO.md:143` — Design one flow they all use. A user should not be able to tell which layer asked.
- `TODO.md:149` — Make every grant reviewable and revocable in one place, with the time it was given and what asked for it.
- `docs/current/STATUS.md:82` — **Permissions** — shows the common permissions in four understandable groups; project/session/browser automation is on by default, and only Computer Use is necessarily off
- `TODO.md:493` — N.5 — the permission flow. Second thing a new user meets, and the one place where being unclear has a security cost.

**Why it matters:** Intention already recorded and agrees with simplification; the redesign must not add a fourth axis (N.7.5's 'ask first, or run automatically' per rule is a candidate).

**Direction:** Adopt N.5's scope vocabulary (once / this session / this project / always) as the single permission model across all three axes.

#### [MEDIUM] P12 — Optional-driver setup lives in three places (onboarding tools step, Settings › Uncoil › Drivers, Extensions › Security) and N.4 will rewrite it without naming a home

*Category:* duplicate-concept

- `App/UI/Onboarding/OnboardingToolSteps.swift:137` — title: String(localized: "Bumblebee scanner")
- `App/UI/Onboarding/OnboardingToolSteps.swift:203` — String(localized: "Cua Driver — Computer Use")
- `App/UI/Settings/DriverSetupSections.swift:182` — .settingsID("permissions.cua.start")
- `App/UI/ExtensionsView.swift:2598` — BumblebeeSetupSection(
- `TODO.md:92` — Move the optional installs (Bumblebee, Cua Driver, agent browser) out of the required path and behind a "set this up when you need it" route — see N.4
- `TODO.md:126` — Show real state for both: installed or not, which version, whether the permissions are actually granted right now — verified, not remembered

**Why it matters:** Three installers for three binaries in three windows, with settingsIDs prefixed 'permissions.cua' on a page called Drivers. N.4's 'real state' requirement is a capability registry by another name.

**Direction:** One 'optional capabilities' surface whose rows are driven by a registry (installed / version / grants verified / repair).

#### [MEDIUM] P13 — Turkish labels survive in English public prose, showing docs written against UI that has since been renamed

*Category:* terminology

- `docs/current/RUN_PREVIEW.md:42` — it only appends new ids ("Tespit et" in the UI
- `CHANGELOG.md:176` — Settings → Bildirimler now shows whether macOS has authorised Uncoil
- `CHANGELOG.md:190` — Added a redesigned project header with the Genel/Tasks switch inside it
- `TODO.md:509` — 10. [ ] global CLAUDE.md gibi dosyaları direkt uncoil içinden editör ile açıp düzenlenebilir olması lazım

**Why it matters:** The release notes are used verbatim in-app and on GitHub (CHANGELOG.md:7-9). Vocabulary drift between docs and UI is a symptom of no single label source; the same drift produces 'Parameters' vs 'Run Parameters', 'Mode and Keyboard' vs 'Working Mode', 'Agent Settings' vs 'Agents'.

**Direction:** Every doc path should be checked against SettingsView.Pane.title at build time, or docs should reference pane ids.

#### [MEDIUM] P14 — The plan's explicit non-goals have been crossed by vocabulary: 'Plugin marketplace' → MCP Catalog + Skill Catalog; 'Usage/cost analytics dashboard' → usage card; 'Automatic branch merging' → task merge flow (user-approved)

*Category:* other

- `docs/roadmap/FOUNDATION_PLAN.md:198` — - Automatic branch merging
- `docs/roadmap/FOUNDATION_PLAN.md:203` — - Plugin marketplace
- `CHANGELOG.md:158` — Added two catalog pages to the Extensions window — **MCP Catalog** (the official MCP Registry) and **Skill Catalog** (GitHub): a searchable, paginated grid with popularity views
- `TODO-archive-0.1.0.md:1039` — - [x] A marketplace — **deliberately not built.**
- `TODO.md:276` — A card behind the chip — a popover, not a floating panel … It carries every window with a bar, its reset, the plan and account, credits kept visibly apart from quota

**Why it matters:** Not wrong decisions, but each was made without updating the stated scope, so the plan no longer bounds anything. A restructuring needs to know which non-goals are still non-goals.

**Direction:** Re-state §3.2 for the current product before deciding what to remove.

#### [MEDIUM] P15 — Two whole surfaces (usage chip/card, handoff sheet) plus a new General setting and two Attention rows shipped in 0.2.0 with no CHANGELOG 'Added' entry

*Category:* discoverability

- `CHANGELOG.md:75` — Reading a Claude account's limit asks the CLI first, and stops asking for your password.
- `CHANGELOG.md:7` — Each released section's body is used verbatim as the GitHub Release notes and as the in-app update notes
- `TODO.md:237` — ### N.7.1 Show usage in the session — built
- `TODO.md:351` — ### N.7.4 The handoff itself — built, manual only

**Why it matters:** Verified with git: 6b9c5a9 (2026-08-10) and bcaa920 (2026-08-16) are ancestors of v0.2.0. The only release-note channel omits them; README and STATUS.md also omit them. The feature inventory now exists only in TODO.md checkboxes.

**Direction:** Add the missing 0.2.0 entries; make /changelog a gate for any new surface.

#### [MEDIUM] P16 — Design commitments that constrain a redesign are scattered across five docs and one enum comment

*Category:* coupling

- `TODO.md:193` — **The rule that governs all of it:** Uncoil never invents a number.
- `docs/current/extensions/BLUEPRINTS.md:8` — ## Uncoil creates nothing
- `README.md:59` — turns the repository's own `TODO.md` into a task board with no second database
- `docs/current/STATUS.md:53` — `create_child` accepts NO raw shell — only named `SessionPreset`s
- `docs/current/RUN_PREVIEW.md:41` — **Detection never overwrites user/agent entries**
- `docs/current/extensions/PROJECT_SCOPE.md:170` — **The next session.** The runtime daemon's `attach` command carries no argv or environment … a session already running keeps the configuration it started with.
- `CHANGELOG.md:34` — Uncoil adds no flag it has not read in the CLI's own help.
- `docs/roadmap/FOUNDATION_PLAN.md:127` — 5. **Inspectable behavior** … Avoid hidden prompt layers.
- `README.md:78` — neither is installed without your explicit approval — Uncoil asks first, every time.

**Why it matters:** These are load-bearing: 'changes take effect next session' rules out live toggles and forced the 'Restart all' button; 'no raw shell' makes presets a security boundary, not a convenience; 'creates nothing' means blueprints must open a session. Note the tension: principle 5 'avoid hidden prompt layers' vs blueprints auto-send, Fix-with-agent prompts, handoff fences and 'Organise automatically' — each a prompt the user did not type.

**Direction:** Collect the commitments in one place the redesign can cite; decide whether 'avoid hidden prompt layers' still holds.

#### [MEDIUM] P17 — The plan's UI architecture (status bar, new-session sheet, context bank, worktrees-first sidebar) was never built, and its needs resurface as ad-hoc header chips and a Turkish backlog line

*Category:* navigation

- `docs/roadmap/FOUNDATION_PLAN.md:1350` — │ MCP · Runtime · Ports · Git · Attention                            │
- `docs/roadmap/FOUNDATION_PLAN.md:1379` — ### Session header … Task title / Provider and model / Account profile / Project and worktree / Branch / Runtime status / Elapsed time / MCP set / Permission mode / Resume/fork actions
- `docs/roadmap/FOUNDATION_PLAN.md:1394` — ### New session sheet … Project / Task title / Prompt / Provider / Account / Model / Permission mode / Working directory / Worktree policy / MCP set / Launch profile / Resume existing session
- `docs/roadmap/FOUNDATION_PLAN.md:1431` — ## 21. Context Bank and Project Rules … `AGENTS.md` `CLAUDE.md` `GEMINI.md` … Show which files apply to a selected session and their precedence.
- `TODO.md:509` — global CLAUDE.md gibi dosyaları direkt uncoil içinden editör ile açıp düzenlenebilir olması lazım
- `CHANGELOG.md:84` — The changes panel is gone from the session view.

**Why it matters:** Without a new-session sheet, launch options attach to whichever surface was nearest (dispatch sheet, header account menu, Quick Launch right-click, handoff sheet). Without a status bar, run/ports/MCP state live in tabs. The plan's Context Bank is the answer to backlog item 10, but item 10 is phrased as an editor shortcut.

**Direction:** Decide explicitly which §20/§21 elements are abandoned; a new-session sheet would absorb P1's four concepts.

#### [LOW] P18 — CLAUDE.md's documented onboarding step ids do not match the enum ('liveStatus' does not exist; four steps are undocumented)

*Category:* onboarding

- `App/UI/Onboarding/OnboardingView.swift:62` — if let requested = LaunchConfig.shared.onboardingStep,                let parsed = OnboardingStep(rawValue: requested)
- `App/Core/OnboardingState.swift:14` — case hooks

**Why it matters:** An agent following CLAUDE.md to verify onboarding lands on the wrong step silently — the same 'silent failure' class CLAUDE.md warns about for flag order.

**Direction:** Derive the documented list from OnboardingStep.allCases.

#### [LOW] P19 — The product already states the empty-state principle it does not yet meet

*Category:* empty-state

- `TODO.md:98` — Handle the empty cases properly — no CLI installed, no project, no account. Today these read as failures rather than as the ordinary starting state.
- `TODO-archive-0.1.0.md:2221` — Add New Project to the context menu when the sidebar's empty area is right-clicked. The menu returned nil below the last row, so right-clicking the empty area did nothing — including on a first run, where that empty area

**Why it matters:** Agrees with simplification; the fix belongs to the same registry that decides pane visibility (P9).

**Direction:** Treat 'nothing installed' as a state with an offer, as ProjectArea already does.

### Surfaces

| Surface | Kind | File | Entry points |
|---|---|---|---|
| First-run window (onboarding) | window | `App/Core/OnboardingState.swift` | First launch; Settings › About 'Run the first-run flow again' (AboutSettingsPage.swift:75); 'Finish setup' row at the bottom of the sidebar for skipped steps (CHANGELOG.md:160); -route onboarding -onb |
| Settings window | window | `App/UI/Settings/SettingsView.swift` | ⌘, / Uncoil menu (archive Stage 38); Settings button with red update badge (CHANGELOG.md:25); Command palette deep links by pane raw value (SettingsView.swift:66-70); 'Capabilities…' button on Uncoil  |
| Extensions window | window | `App/UI/ExtensionsView.swift` | Extensions menu in the menu bar (CHANGELOG.md:195); Command palette; Settings › Agents › Installed Agents opens the Agents screen (CHANGELOG.md:33); -route extensions -extensions-section <name> |
| Project dashboard tabs | tab | `App/Core/ProjectAreaAvailability.swift` | Sidebar project row |
| Project Customize sheet | sheet | `App/UI/ProjectCustomizeSheet.swift` | Project right-click menu; New-project sheet (CHANGELOG.md:19: MCP and skill list 'moved behind one button') |
| New-project sheet | sheet | `App/UI/NewProjectSheet.swift` | Add Project; sidebar empty-area menu |
| Session header usage chip + card + Handoff sheet | popover | `App/UI/UsageChip.swift` | Session header; Attention Center 'Limit approaching' row; usage card |
| Attention Center and menu-bar monitor | panel | `App/UI/AttentionCenterView.swift` | Titlebar; menu-bar item |
| Session view control cluster | toolbar | `App/UI/SessionHeaderBar.swift` | Session selection |
| Command palette | popover | `App/UI/CommandPalette.swift` | ⌘K (configurable hotkey, Settings › General) |

### Concepts

- `U` **Project** — A folder registered in the sidebar; owns defaults, sessions, worktrees, groups, .uncoil/ files. Plan §8.1 gave it defaultProviderID/defaultAccountProfileID/defaultLaunchProfileID/defaultMCPSetID (FOUNDATION_PLAN.md:503-522); shipped defaults are spread over Customize sheet, run.json star, per-project notifications. *Overlaps:* Scratch workspace / one-off session (a project 'Uncoil owns', archive Stage 49)
- `U` **Session** — One PTY running an agent CLI or a shell; has provider, account, status, parent, handoffFromSessionID, group, worktree. *Overlaps:* Child session (create_child), Sub-agent (archive Stage 44), One-off session, Hibernated/paused session
- `i` **Launch Profile (plan only)** — Plan §8.5: a named reusable launch (provider, account, model, permission mode, prompt templates, worktree policy, MCP set, env, args, resume policy) with 'a complete launch preview' (FOUNDATION_PLAN.md:606-631). Never built under this name. *Overlaps:* Session Preset, Blueprint, Quick Launch, Task dispatch sheet
- `U!` **Session Preset** — Named preset used by create_child (only route to a child; 'no raw shell', STATUS.md:53) with provider, args, opening prompt, permission mode, capability bounds. Editable at Settings › Agents › Session Presets (AgentSettingsPages.swift:536-640); shown as 'Preset' in the task dispatch sheet (TaskDispatchSheet.swift:291). *Overlaps:* Launch Profile, Blueprint, Working Mode
- `U` **Blueprint** — A named prompt (plus optional auto-send) offered as a card when a folder becomes a project; 'Uncoil creates nothing' on disk (BLUEPRINTS.md:8-20; CHANGELOG.md:17). Editable at Settings › Agents › Blueprints; writable by an agent only through an opt-in grant. *Overlaps:* Session Preset (both are 'a saved opening prompt + options'), Launch Profile's initialPromptTemplate
- `U` **Quick Launch** — The hover strip of agents on a project row; ordered/enabled in Settings › Appearance › Quick Launch (SettingsView.swift:132); also defines which agents appear as tabs in the MCP & Skills picker (CHANGELOG.md:20) and which one-off sessions the palette offers (archive Stage 49). *Overlaps:* Installed Agents, Session Preset
- `U` **Account profile** — Isolated config root per provider (CLAUDE_CONFIG_DIR, CODEX_HOME, GROK_HOME, CURSOR_CONFIG_DIR, HERMES_HOME; nil for gemini/opencode — Models.swift:517-542). README.md:64-66 claims 'the Gemini equivalent' exists; code says no. *Overlaps:* Provider, Usage window (a limit belongs to a login, TODO.md:294)
- `U` **Provider / Agent** — AgentProvider enum: claude, codex, gemini, opencode, grok, hermes, cursor, terminal (Models.swift:20-28; 'agents' = non-terminal, Models.swift:40). A second roster, Extensions AgentKind, has claudeCode, codex, geminiCLI, cursor, amp, opencode, grok, hermes (ExtensionModels.swift:90) — Amp only there ('Uncoil never launches Amp', AgentIntegration.swift:114). README says 'Three agents, one window' (README.md:48). *Overlaps:* Integration level (live events / control plane / terminal only / found)
- `U` **Working mode / permission mode** — Per-provider trust policy (Claude Manual/Accept Edits/Plan/Auto/Dangerously Skip; Codex Ask/Approve/Full Access; STATUS.md:84), now with 'Provider default' as default (CHANGELOG.md:59). Chosen in three places: onboarding workingModes step, Settings › Agents › Working Mode, per task dispatch (CHANGELOG.md:188). *Overlaps:* Capabilities/grants (a different permission axis), Permissions pane (a third axis)
- `U!` **Capability / grant** — Control-plane permission keys (tasks.delete, tasks.merge, runs.control…) gated per session; default-on set vs opt-in set (CLAUDE.md MCP section; OnboardingPlatformSteps.swift:296-303 shows keys and groups). Shown to users as 'Agent capabilities' (onboarding), 'Capabilities…' (McpSettingsPage.swift:92), 'capability bounds' in presets. *Overlaps:* Working mode, Directional permissions (A→B grants, STATUS.md:54), Project MCP & Skills scope
- `U` **Permission (directional, user-granted)** — A→B session grant approved/denied/revoked in Settings › Permissions; expires after 10 minutes if pending (STATUS.md:54). TODO N.5 lists four arrival routes with different UIs (TODO.md:139-142). *Overlaps:* Capability, Working mode, macOS Accessibility/Screen Recording grants for Cua
- `U!` **Hook (Agent Status Hooks)** — Claude Code (and Hermes) hook entries Uncoil writes into the CLI's own settings to stream session state. Pane 'Agent Status Hooks' under the Uncoil category (SettingsView.swift:148; PrivacySettingsPages.swift:346-347 'Claude Code's hooks are what make session states stream'), onboarding step 'Status tracking' (OnboardingState.swift:32), and 'Connect' on Installed Agents (CHANGELOG.md:33). *Overlaps:* Integration level, Installed Agents
- `U!` **Driver** — Optional external binaries: agent-browser (Vercel) for uncoil_browser, cua-driver for uncoil_computer; plus Bumblebee (a scanner, not a driver). Pane titled 'Drivers' (SettingsView.swift:150), onboarding step 'Optional tools' (OnboardingState.swift:35), Bumblebee also on Extensions › Security (ExtensionsView.swift:2598). *Overlaps:* Capability (computer/browser grants), Extensions
- `i!` **Adapter** — Per-agent config format writer (JSON/TOML/YAML) in App/Extensions. Named to users: 'each moves up once an adapter for its config format lands' (ExtensionsView.swift:974). *Overlaps:* Integration level
- `U!` **Control plane** — The in-app MCP server behind control.sock. Named to users: 'Control plane' section (McpSettingsPage.swift:29), 'Control plane not running' (SettingsView.swift:349), onboarding 'Tasks and the control plane' (OnboardingExtensionsSteps.swift:283). *Overlaps:* Uncoil MCP, Capabilities
- `i` **MCP set (plan only)** — Plan §8.7: named set of servers assignable at global/provider/project/launch-profile/session levels with 'Precedence must be documented and visible' (FOUNDATION_PLAN.md:697-715). Shipped instead as per-project, per-agent exclusion lists ('Everything is on until you turn it off', CHANGELOG.md:21; PROJECT_SCOPE.md). *Overlaps:* Project MCP & Skills scope, Extensions Assignments matrix
- `U` **Run configuration / Test suite** — Entries in repo-owned .uncoil/run.json and .uncoil/tests.json with source detected|user|agent; detection never overwrites (RUN_PREVIEW.md:41-44). Tests reuse uncoil_run actions 'rather than a ninth tool: the MCP surface is eight tools by design' (TODO-archive-0.1.0.md, Stage 45.2). *Overlaps:* Task test runs (task-level test results, CHANGELOG.md:207)
- `U` **Task** — A checkbox line in a repo TODO.md; 'no second database' (README.md:59-60). Has claims, leases, roles, orchestrator, worktree/review/test/merge flows (archive Stages 22-35). *Overlaps:* Issue (GitHub) — 'its own area beside Tasks' (archive 40.2), Artifact
- `U` **Extension / Skill / MCP server** — Managed packages in a central store with revisions, mirrors, security scan, assignments to agents. Plan called the surface 'MCP Center' (FOUNDATION_PLAN.md:1117); shipped as 'Extensions'. *Overlaps:* Uncoil MCP (the app's own server is also an MCP server, 'uncoil is never excluded', PROJECT_SCOPE.md:177)
- `U` **Usage window / Provider limit / Handoff package** — Per-account quota windows (usedPercent, reset) with 'Uncoil never invents a number' (TODO.md:193); threshold in Settings › General › Provider Limits (GeneralSettingsPage.swift:91); handoff package written to .uncoil/handoff/<id>.md (TODO.md:337-339). Plan §3.2 listed 'Usage/cost analytics dashboard' as a non-goal (FOUNDATION_PLAN.md:202). *Overlaps:* Account profile, Session Preset (destination choice), Rules engine (planned N.7.5)
- `U` **Integration level** — Four levels per installed agent: live events, control plane, terminal only, found-but-nothing-more (CHANGELOG.md:33; AgentIntegration.swift:316-323). *Overlaps:* Hook, Provider descriptor flags (plan §8.3 supportsStructuredEvents etc.)

### Flows

- **First run (as shipped vs as planned)** (13 steps) — friction: TODO.md:80-101 (N.2) already calls it 'painful and incomplete' and 'a flow that answers each question and does not hold together' and orders it first (TODO.md:490-491: 'currently the worst thing about the product'). OnboardingFlow.currentVersion=3 reopens the flow for existing users whenever a step is added (OnboardingState.swift:56-60), so every new feature can re-enter onboarding. CLAUDE.md's step-id list names 'liveStatus', which OnboardingStep(rawValue:) cannot parse (OnboardingView.swift:62-64) — silent fallthrough.
- **Add a project** (6 steps) — friction: Project-level configuration has no single home: Customize sheet (2 tabs), Settings › Notifications › Per Project, General-page offers, .uncoil/run.json + tests.json + handoff/, right-click (apply blueprint), palette.
- **Permission request (as N.5 maps it)** (4 steps) — friction: N.5 is the product's own admission that 'a user should not be able to tell which layer asked' is not true today (TODO.md:143-144). Separately, capability toggles (onboarding + Permissions pane), working modes (three places) and directional grants are three permission axes with three vocabularies.
- **Account runs low → handoff** (6 steps) — friction: Shipped inside v0.2.0 (commits 6b9c5a9, bcaa920) with no CHANGELOG 'Added' entry — the in-app and GitHub release notes do not mention the chip, the card, the sheet, the new General setting or the two new Attention rows. N.7.5 would add rules (per-project override, chains, model choice, history) on top with no stated home.
- **Run a project and fix it with an agent** (5 steps) — friction: RUN_PREVIEW.md:42 still calls the button 'Tespit et' (Turkish) — the doc predates the English UI. Plan §20 imagined a bottom bar 'MCP · Runtime · Ports · Git · Attention' (FOUNDATION_PLAN.md:1350-1352) that never shipped; ports/preview state live only inside the Run tab.
- **Set up an optional driver** (4 steps) — friction: Three entry points for three installs, none of them a registry of 'what optional capability is present'. N.2 explicitly wants installs out of the required path 'behind a set this up when you need it route — see N.4' (TODO.md:92-94).

### Configuration points

| Setting | Scope | Stored in | Edited at | Inferable |
|---|---|---|---|---|
| Usage warning threshold (Provider Limits) | global | SettingsStore (settings.json) — usageWarningsEnabled / usageWarningThreshold | Settings › General › Provider Limits (GeneralSettingsPage.swift:91-107) |  |
| Working mode per provider | global | settings.json | Settings › Agents › Working Mode (AgentBehaviorSettingsPage, AgentSettingsPages.swift:423); onboarding workingModes step; overridden per dispatch (CHANGELOG.md:188) | yes |
| Run parameters (CLI args, model) per provider | global | settings.json | Settings › Agents › Run Parameters (LaunchArgumentsSettingsPage, AgentSettingsPages.swift:385) |  |
| Session Presets | global | presets file (BackupService.swift:27 'Presets') | Settings › Agents › Session Presets (AgentSettingsPages.swift:536-640) |  |
| Blueprints | global | BlueprintStore (App/Core/BlueprintStore.swift) | Settings › Agents › Blueprints; agent-written drafts via opt-in grant |  |
| Per-project MCP & skill scope | project | App-side exclusion records (PROJECT_SCOPE.md:11-23), applied per session at launch | Project Customize › MCP & Skills; new-project sheet | yes |
| Run configurations | project | .uncoil/run.json (repo-owned, re-read every operation) | Run tab editor sheet; by hand; uncoil_run update | yes |
| Test suites | project | .uncoil/tests.json | Tests tab; uncoil_run test_update | yes |
| Handoff packages | project | .uncoil/handoff/<id>.md | Not editable in-app yet ('Let the user see and edit it before it is handed on' unchecked, TODO.md:341) |  |
| Tasks | project | TODO.md files in the repo ('no second database', README.md:59-60); task↔session index in App Support | Tasks tab; palette quick capture; uncoil_tasks |  |
| Per-project notification overrides | project | settings.notifications.perProject[project.id] (NotificationSettingsPages.swift:451,485) | Settings › Notifications › Per Project — not in the project's Customize sheet |  |
| Agent location (Locate…) | global | settings (CHANGELOG.md:32) | Settings › Agents › Installed Agents and Extensions › Agents card ('the same act', CHANGELOG.md:32) | yes |
| Agent Status Hooks | integration | ~/.claude/settings.json, ~/.hermes/config.yaml (backup first) | Settings › Uncoil › Agent Status Hooks; onboarding hooks step; Installed Agents 'Connect' | yes |
| Drivers (agent-browser, cua-driver) and Bumblebee | global | On disk under Uncoil's tools directory / npm | Settings › Uncoil › Drivers; onboarding tools step; Extensions › Security | yes |
| Capability defaults and directional permissions | session | permissions.json (atomic) | Settings › Uncoil › Permissions; onboarding capabilities step; preset capability bounds |  |
| Quit policy / transcripts / menu-bar / attention emphasis / theme | global | settings.json | Settings › General, Uncoil › Data and Transcripts, Appearance › Menu Bar, Appearance › Theme and Colours › Attention |  |
| Onboarding completion | global | settings.onboardingCompletedSteps + version stamp | Onboarding; 'Finish setup' sidebar row; Settings › About rerun |  |

### Visibility gates

- `App/Core/ProjectAreaAvailability.swift:88-95` — Project has task sources / run configs / test suites / GitHub remote → Which of Tasks/Run/Tests/Issues tabs appear; missing ones become General-page offer cards (45-70). The one place a 'show only what exists' rule is implemented as a pure function.
- `App/Core/OnboardingState.swift:44-50` — OnboardingStep.isActionable (everything except welcome/finish) → Whether a skipped step counts toward the 'Finish setup' sidebar row.
- `App/Core/OnboardingState.swift:56-60` — Stamped onboarding version < OnboardingFlow.currentVersion (3) → Existing users are re-shown the flow 'at the new steps only'.
- `App/UI/Onboarding/OnboardingView.swift:62-64` — LaunchConfig -onboarding-step id parses as OnboardingStep(rawValue:) → Which step opens; an unknown id (e.g. CLAUDE.md's 'liveStatus') silently falls back.
- `CHANGELOG.md:24` — Agent has running (non-sleeping) sessions → 'Restart all' button per agent in Settings › Agents › CLI Tools.
- `CHANGELOG.md:255; archive Stage 49` — Agent detected on this machine → Assignment screens list only detected agents; one-off session palette entries only for quick-launch agents that are installed.
- `TODO-archive-0.1.0.md Stage 42.1` — Provider.resumesConversation → Hibernate offered; Gemini and terminals can pause but not hibernate.
- `TODO.md:290-310` — Usage below threshold; provider says limit_reached → 'Limit approaching' (warn-only) vs 'Limit reached' (problem + notification) Attention rows; chip colour.
- `TODO.md:235-236, 264-266` — Chip is on screen → Usage refresh loop runs at all ('driven from the chip, so it stops with the view').
- `TODO-archive-0.1.0.md Stage 45.1` — Run has a log → Session-header shortcut to run logs.
- `docs/current/RUN_PREVIEW.md:45-49,56-59` — Project has a default run configuration (star / single config) → Play/stop button in every session header.
- `CHANGELOG.md:22; PROJECT_SCOPE.md:84` — Claude Code skills scoped? (no per-session mechanism) → Whether the MCP & Skills picker shows skills as scopable per agent; the screen states the limit inline.
- `App/Extensions/AgentIntegration.swift:316-323` — Integration level ceiling per agent (AgentIntegration.support.ceiling) → Whether Installed Agents offers a 'Connect' action; Amp has no ceiling above 'found'.
- `App/UI/Settings/SettingsView.swift:349-350` — Control plane running → Permissions pane shows 'Control plane not running' instead of requests.
- `TODO-archive-0.1.0.md Stage 49` — Project is the Scratch workspace → Sorted last, dimmed, no pin/reorder/remove, hidden from pickers, closes when its last session does.

### Open questions

- Which of FOUNDATION_PLAN §20/§21 (bottom status bar, new-session sheet with launch preview, Projects settings page, Context Bank) are abandoned versus deferred? STATUS.md's deviations table (STATUS.md:7-16) does not list them.
- Is Amp meant to become an AgentProvider, or stay Extensions-only? Two rosters exist today (Models.swift:20-28 vs ExtensionModels.swift:90).
- Where does N.7.5 land — under General › Provider Limits, under Accounts, or a new category? And is the per-project override going into the Customize sheet?
- Will N.2's rewrite also retire the Settings pages that exist only as twins of onboarding steps (Agent Status Hooks, Drivers), or must setup remain 're-enterable' from each of them (TODO.md:95-96)?
- Is 'Catalog' vs 'Marketplace' (archive:1039 vs CHANGELOG.md:158) an intentional scope line, and does §3.2's 'Usage/cost analytics dashboard' non-goal still hold after N.7.1?
- Does principle 5 'Avoid hidden prompt layers' (FOUNDATION_PLAN.md:127-129) still hold, given blueprints auto-send, Fix-with-agent, handoff fences and 'Organise automatically' all inject prompts?
- Is STATUS.md going to be maintained, retired, or regenerated? It instructs new readers to start there (STATUS.md:5) and is two releases stale.
- Why does CHANGELOG 0.2.0 omit the usage chip/card, handoff sheet, Provider Limits setting and the two Attention rows (commits 6b9c5a9, bcaa920 are in v0.2.0)? Should 0.2.1 carry them?
- README says the build is 'signed and notarized' (README.md:91) while C.1 (TODO.md:426-430) lists Developer ID, notarization and stapling as unfinished — which is true?
