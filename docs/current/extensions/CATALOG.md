# Extension Catalogs

Two catalog pages inside the Extensions window let the user discover and
install extensions from remote registries:

- **MCP Catalog** — the official MCP Registry (`registry.modelcontextprotocol.io`)
- **Skill Catalog** — GitHub, through the app's existing GitHub session

Both open from the Extensions sidebar (`-extensions-section mcpCatalog` /
`skillCatalog` in UI-testing launches) and share one screen (`CatalogScreen`),
one detail/install sheet (`CatalogDetailSheet`), and one provider layer under
`App/Extensions/Catalog/`.

## Architecture

```
CatalogScreen / CatalogDetailSheet          UI, one per section
        │
   CatalogStore                             @MainActor state: pages, search,
        │                                   cancellation, per-item detail cache
        ├── McpRegistryProvider             GET /v0/servers (cursor pagination,
        │                                   version=latest, search), /versions
        ├── GitHubSkillProvider             search/repositories over seed
        │                                   sources, git trees at a pinned
        │                                   commit, blobs for skill files
        ├── GitHubEnrichment                repo stars/license/pushed_at,
        │                                   secondary and best-effort
        └── CatalogHTTPClient               one HTTP path: TTL disk cache,
              └── CatalogDiskCache          stale-cache fallback when offline
CatalogInstallService                       bridge into the existing install
                                            machinery (see below)
```

Everything is normalised into `CatalogItem` (`CatalogModels.swift`): stable id
(`provider:name`), kind, publisher, repository, version, dates, installs,
license, audits, plus type-specific payloads (`MCPCatalogDetails`,
`SkillCatalogDetails`). A new registry is a new provider struct mapping its
wire shapes into `CatalogItem` — the UI and the install path do not change.

## Caching and failure

`CatalogHTTPClient.get(url, ttl:)` answers from the disk cache
(`~/.uncoil/extensions/catalog-cache/`) while the entry is inside its TTL
(lists 15 min, details 5 min, versions/audits 1 h, GitHub 1 day), hits the
network after that, and falls back to the stale cache when the network fails —
the UI then shows an explicit "showing cached results" banner. A 401 never
falls back to cache: a missing credential must surface, not be masked.
Loads run in cancellable tasks; a new query cancels the one in flight, and
pages are deduplicated by item id.

## Quality filtering and ranking

Both catalogs filter and rank locally, because neither source's native order
is usable (the MCP registry lists alphabetically; GitHub topics are
self-assigned). All rules are deterministic and testable; search is gated
more loosely than browsing, so anything can still be found by name. None of
this is a safety judgment — the scanner runs on every install regardless.

**MCP** (`McpRegistryProvider.isPresentable` / `ranked`): browsing hides
entries that are deprecated/deleted, have nothing Uncoil can install, have no
real description, or are predominantly CJK-named/-described; the rest are
ranked by repository presence, description quality and recency. The MCP page
has a **Featured** section led by a small verified curated list (GitHub,
Chrome DevTools, Context7, Sentry, Firecrawl, Notion, Stripe, Supabase,
Linear), fetched concurrently.

**Skills** (`GitHubSkillProvider.passesQualityGate`): browsing requires a
description, a "skill" signal in name/description/topics, no `awesome-`
index repos, a small star floor, and not predominantly CJK text
(`cjkRatio`/`cjkCount`); curated seeds bypass the gate.

## Skill discovery (GitHub)

`GitHubSkillProvider` discovers skills over several **seed sources**
(`SkillSeedSource`): GitHub topics (`agent-skills`, `claude-skills`, …), a
repository-search query for `SKILL.md` mentions, and a small curated repo
list (a discovery seed, never a safety claim — such entries carry a
"Curated" badge). Seeds are a value list, so sources can be added, disabled
or replaced (an awesome-list parser, an external registry) without touching
the UI or the install path. Results from all queries are deduplicated by
repository; forks and archived repositories are excluded.

Sections are computed transparently — GitHub has no install ranking, and
stars are labelled as stars, never as installs:

- *Featured* — curated seeds first, then by stars
- *Popular* — by stars
- *Trending* — stars discounted by days since the last push (active in the
  last 30 days)
- *Updated* — by last push
- *New* — created in the last 180 days, newest first

A repository is not assumed to be one skill. The detail pass resolves the
default branch to an exact **commit SHA**, walks the git tree at that commit,
and exposes every directory holding a `SKILL.md` (root included; hidden and
`node_modules` paths excluded) as its own installable skill — multi-skill
repositories get a picker on the detail page. Files come from the blob API at
that commit inside hard caps (400 KB/file, 100 files, 5 MB total); non-UTF-8
files are carried as bytes so assets survive. `SKILL.md` front matter refines
the display name/description; a repository with no `SKILL.md` anywhere is
refused as not installable.

## Authentication

Nothing is embedded in the app, and no separate catalog key exists.

- The MCP Registry is read unauthenticated.
- Skill discovery uses the GitHub token the app's existing **Device
  Authorization** flow already stores (`KeychainStore`, key `github-token`) —
  the same session Settings → GitHub manages. Connected users get
  authenticated rate limits automatically; without a session the catalog
  still works inside GitHub's small anonymous search limit, and the page
  embeds the existing `GitHubLoginView` to connect. Public repositories only;
  no extra scopes are requested by the catalog.
- Rate-limit answers (403/429) surface as a retry state, falling back to the
  stale cache when one exists.
- `SkillsShProvider` remains in the tree as a dormant optional provider (its
  API needs a separate key); it is not reachable from the default runtime
  path.

## Install flow

Catalog inclusion is not treated as proof of safety. Both paths go through the
machinery ordinary installs use — nothing is written before a plan is shown.

**MCP servers** (`CatalogInstallService`): the entry's packages/remotes become
`MCPInstallChoice`s (npm→npx, pypi→uvx, oci→docker run, remotes→HTTP; `mcpb`
and unknown types are refused as incompatible). The chosen form becomes an
`MCPServerDefinition` pinned to the exact published version. Environment
variables are split: secret-looking or required-without-default names go to
`environmentKeys` (values later, Keychain only), plain defaults stay in config.
Per selected agent the definition is planned through the agent's adapter
(`ConfigurationTransactionService`: diff + backup + stale-config refusal), the
diffs are shown, and only then applied. An agent whose config already declares
the name is blocked per-agent, not silently overwritten. After a successful
apply the definition is recorded in the store the same way an adopted server
is, and agent bindings are set.

**Skills**: the detail pass carries the full file set of the chosen skill
directory at the pinned commit, which is written into a staging directory
under `~/.uncoil/extensions/staging/` (paths are validated; `..` and absolute
paths are refused; binary files land byte-for-byte). The staged copy is run
through `ExtensionSecurityScanner`, `ExtensionUpdateEngine.structureIssues`,
Bumblebee's pre-install scan, and `ExtensionInstallPreviewBuilder`;
`ExtensionInstallGuard` gates the install (blocked findings, unapproved
executables, unresolved versions). The install itself is `SkillStore.install`
— one immutable revision (`catalog/<slug>@<pin12>`, pinned to the resolved
commit SHA, with the SHA recorded on the revision), one symlink per selected
agent — plus registry package, agent bindings, findings and an audit event.
A skill already installed outside Uncoil is refused with a pointer to the
adoption flow.

## Updates and rollback

Installed state on cards/detail is computed by name match against the
registry's packages; a catalog-pinned skill whose revision hash no longer
matches the registry's content hash shows **Update**. Updating reinstalls
through the same staged/scanned path; the previous revision is kept as
`previousRevision`, so the ordinary revision rollback applies. MCP config
edits carry the transaction backup, so "back to the previous config" works
from the Agents screen as with any other config change. Deprecated/deleted
registry entries are labelled on card and detail and never auto-removed.

## Tests

`Tests/CatalogTests.swift` — fixture-driven: MCP registry decoding and
mapping, cursor pagination, version pinning and secret splitting, cache TTL /
stale fallback / offline / 401 behaviour, installed state, staging path
safety, full skill install into a fake agent directory, and
executable-approval refusal. `Tests/GitHubSkillProviderTests.swift` — search
mapping (archived/fork exclusion, stars-are-not-installs), auth header and
pagination, per-view query windows, transparent ranking, multi-skill and
root-skill trees, hidden-directory exclusion, blob text/binary decoding,
front-matter refinement, no-SKILL.md and archived refusals, 403 → rate-limit
with stale-cache fallback, and commit-pin update detection.
