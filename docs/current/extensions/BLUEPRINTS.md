# Blueprints

A blueprint is the prompt you always write when you start a project of a certain
shape — the workspace layout, the files at the root, what goes in them, the
first thing an agent should do. Kept, named, and one click away when a folder
becomes a project.

## Uncoil creates nothing

A blueprint is text, and applying one opens a session and hands it that text.
The app does not create the directories itself.

That was a deliberate choice over stamping out a tree. Whether `api/` should
hold a Fastify skeleton or a Go module, and what *this* project's `CLAUDE.md`
should actually say, is judgement — which is what the agent is there for. A tree
the app produced would still need all of that applied on top of it, so the app
would have done the easy half and left the hard half looking finished.

The cost is honest and worth stating: two runs of the same blueprint will not
produce byte-identical trees, because an agent is not a template engine.

## The file

`~/.uncoil/blueprints/<slug>.md` — markdown with YAML front matter, the same
shape as `SKILL.md`:

```markdown
---
name: Full-stack workspace
icon: layout-grid
color: 4C8DFF
startsImmediately: true
---

Create a full-stack workspace at {{project_path}} called {{project_name}}:
api/, web/, mobil/, design-kit/ and docs/, with CLAUDE.md, AGENTS.md and
CHANGELOG.md at the root…
```

Not JSON: the body is a long prompt, and a long prompt inside a JSON string is a
wall of `\n` escapes nobody can read or hand-edit. In this shape, exporting is
copying the file out, importing is putting one back, and an agent asked to write
one is writing a format it already writes daily.

Two placeholders are filled in when a blueprint is applied — `{{project_name}}`
and `{{project_path}}`. There is no third: a blueprint that wants more can say
it in prose, because it is talking to an agent rather than to a template engine.

A file that does not parse is skipped rather than fatal. The folder is somewhere
people drop things, and one stray note must not empty the list.

## Applying one

`BlueprintRunner.apply` opens a session with `settings.defaultProvider` and the
default account for it, routes the main window to it, and delivers the prompt
through `SessionPromptDelivery`.

`startsImmediately` decides whether the prompt is **sent** or **typed in and
left**. Off is the default and the safer one: you read it before it runs.

Three entry points, one list:

- the sheet that opens when a folder becomes a project (`NewProjectSheet`)
- the sidebar's project context menu → "Apply Blueprint…"
- the command palette → "Apply Blueprint… [project]"

## Writing one

Three ways, and the third is the reason the control-plane surface exists.

1. **By hand** — Settings › Agents › Blueprints.
2. **Import** a `.md` file someone sent you.
3. **With an agent** — "Write One With an Agent…" opens a session in the scratch
   workspace whose one job is to interview you and save the result through
   `uncoil_projects save_blueprint`.

### Why writing is opt-in

`blueprints.write` lives in `PolicyEngine.optionalGrants`, so no ordinary
session has it. The authoring session is created with it explicitly
(`SessionRecord.capabilities`), which is exactly what per-session capabilities
are for.

The reason is not hypothetical. A blueprint is text that a *later* session gets
handed and, if `startsImmediately` were set, runs without being read. A session
able to write one silently could leave instructions behind for a session that
has not started yet. So:

- the grant is opt-in, and belongs to the one session opened to use it;
- the caller session must be **resolvable** — `uncoil_projects` reads fall back
  to the default grant set when it is not, which is right for reading and wrong
  for leaving a prompt behind;
- anything written through the control plane, or imported from someone else, is
  stored as a **draft**: `needs_review` is true and `starts_immediately` is
  forced false. Opening it in the editor and keeping it *is* the review, and
  clears the mark.

Input is capped at 60 characters of name and 8000 of prompt, and the prompt goes
through `CapabilityRouter.sanitizePrompt` — the same escape defence the child
launcher applies, because this text reaches a PTY too, just later.

## Tests

`Tests/BlueprintStoreTests.swift` — the file round trip, a `---` in the body not
being read as a fence, placeholder filling, name collisions not overwriting,
the draft rule, import/export, and a stray file not taking the list down.
`Tests/ControlPlaneTests.swift` — the grant being opt-in, an unresolvable caller
being refused, the draft rule over the wire, and the length/escape caps.
