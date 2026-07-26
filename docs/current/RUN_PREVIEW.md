# Project Run / Dev Preview

Start a project's development environment with one action — a dev server, an
Xcode build+launch, a compose stack, or several processes in order — so changes
made by coding agents can be tested and previewed immediately.

## Where the configuration lives

Everything is in the repo-owned **`.uncoil/run.json`**. The app holds no hidden
copy: the file is re-read on every operation, so edits by hand, by the editor
sheet, or by an agent all take effect immediately.

```json
{
  "version": 1,
  "configurations": [
    {
      "id": "web-dev",
      "name": "Web dev server",
      "command": "npm run dev",
      "cwd": "apps/web",
      "env": { "PORT": "3000" },
      "ports": [3000],
      "preview_url": "http://localhost:3000",
      "ready_pattern": "Local:",
      "depends_on": ["api"],
      "source": "user",
      "notes": "free text"
    }
  ]
}
```

- `command` runs through the user's login shell (`$SHELL -l -c`), so PATH,
  nvm, asdf etc. behave like a terminal.
- `cwd` is relative to the project root; `"."` is the root.
- Readiness = `ready_pattern` regex match in output, **or** a declared port
  accepting connections, **or** (with neither) simply surviving a short grace
  period.
- `depends_on` entries start first and must become ready.
- `source` is `detected` | `user` | `agent`. **Detection never overwrites
  user/agent entries** — it only appends new ids ("Tespit et" in the UI,
  `{"action":"detect"}` over MCP; `{"replace":true}` resets only *detected*
  entries).
- `default: true` marks the project's default configuration — the one the run
  button in every session header launches, and the one id-less MCP calls
  (`{"action":"start"}`) resolve to. At most one entry carries it (the UI star,
  `set_default` and `update` keep it exclusive). A project with exactly one
  configuration needs no flag.
- Unknown JSON keys are preserved on rewrite, so agents can annotate freely.
- A malformed entry is skipped and reported under `problems`, never fatal.

## UI

Project dashboard → **Run** tab: configuration list with status dot,
start/stop/restart, log tail viewer, preview-URL link, detect button, and an
editor sheet (id, command, cwd, env, ports, preview URL, ready pattern,
dependencies). The star on a row marks the default; that default gets a
play/stop button in the top-right control cluster of every session header, so
the project can be launched without leaving the agent conversation. Failures show a diagnostic banner (`issue.code` + hint). A green
dot on the tab means something is running. Crashes also surface in the
Attention Center. Run processes stop when Uncoil quits.

Each run writes its own timestamped log under
`~/Library/Application Support/Uncoil/projects/<projectID>/run/logs/`; the last
10 runs per configuration are kept and listed (with exit codes) in the row's
history popover and over MCP (`history`). While a process runs, the row shows a
live 3-line output pulse, the full log view has an input field that writes to
the process's stdin (`send_input` over MCP — e.g. Flutter's `r` hot reload),
and a failure banner offers "Fix with agent", which submits a ready-made
repair prompt to the project's most recent agent session (clipboard fallback
when none is live).

## Agents: the repair loop

Agents drive the same feature through the `uncoil_run` MCP tool
(see `docs/current/mcp/CAPABILITIES.md`). The intended loop for
"fix the project run configuration":

1. `{"action":"status","id":"web-dev"}` → read `state.issue` ({code, hint}) and
   `{"action":"logs","id":"web-dev"}` for the tail (untrusted content).
2. Repair: edit `.uncoil/run.json` directly, or call
   `{"action":"update","configuration":{...}}` (marks the entry
   `source: "agent"`).
3. `{"action":"start","id":"web-dev"}` → success returns pid/log_file/
   preview_url; failure returns `details.issue` + `log_tail` to iterate on.

Id-less calls (`{"action":"start"}`, `status`, `stop`, `restart`, `logs`)
resolve to the default configuration, so "run the project" needs no id
discovery; `{"action":"set_default","id":"..."}` moves the flag.

To verify a fresh change builds and launches:
`restart` → `status` (expect `"running"`) → open `preview_url`.

Common `issue.code` values and what they mean: `port_in_use` (stop the other
process or change the port), `command_not_found` (PATH/absolute path),
`missing_dependencies` (run the install step), `invalid_scheme` /
`invalid_destination` (xcodebuild arguments), `docker_unavailable`,
`build_failed`, `not_ready` (the server is fine — fix `ready_pattern`/`ports`).

## Detection coverage

package.json scripts (`dev`/`start`/`serve`, package manager from the lockfile),
`.xcworkspace`/`.xcodeproj` (scheme guessed from the container name — verify
with `xcodebuild -list`), compose files, `Makefile` dev/run/start/serve
targets, `Procfile` entries, Django `manage.py`, `pyproject.toml`
`[project.scripts]` (+uv), bare `index.html` static sites — at the repo root
and one directory level down (`backend/`, `mobile/`, …). Detection is a
suggestion, not truth: correct it once and it stays corrected.
