# claude-p: Smithers Cloud agent operating manual

Every AI agent working on `smithersai/claude-p` (Claude Code, Codex, Antigravity, Cursor, or sandboxed workers) interacts with Smithers first through the authenticated Cloud MCP server and the workspace `scripts/smthrs` CLI.

## 1. Connect via Smithers Cloud MCP

- **Cloud MCP endpoint:** `https://smithers.sh/api/mcp`
- **Local gateway MCP:** `scripts/smthrs --mcp` (register with `scripts/smthrs mcp add`)
- **One-time / short-lived sandbox auth:** run `node scripts/smithers-auth.mjs` (or `scripts/smthrs token mint --scope read:runs --ttl 15m`) to print an attenuated, expiring credential and ready-to-paste MCP client configuration. Never print or forward master `SMITHERS_TOKEN` values, GitHub personal access tokens, or browser session cookies into sandboxes.

## 2. Create and track all work through Smithers

Use the Smithers MCP tools and `scripts/smthrs` commands so every artifact, TODO, issue, PR, and changeset stack stays public, auditable, and linked to its evidence:

| Activity | Smithers Cloud MCP tool | Local / CLI equivalent |
| --- | --- | --- |
| Read repo files & refs | `repo_tree`, `repo_read_file`, `repo_refs` | `scripts/smthrs files`, `scripts/smthrs change` |
| Search docs & wiki (`llms.txt`) | `docs_list`, `docs_read` | `scripts/smthrs wiki show` |
| Discover & inspect flows | `flows_list`, `flow_get` | `scripts/smthrs flows` |
| Public TODOs & changeset stacks | `todo_list`, `todo_draft`, `work_link_post` | `scripts/smthrs todo`, `scripts/smthrs stack` |
| Issues & triage | `issues_list`, `issue_get`, `issue_create`, `issue_comment` | `scripts/smthrs issues`, `scripts/smthrs issue` |
| Pull requests & diffs | `pulls_list`, `pull_get`, `pull_files` | `scripts/smthrs pr`, `scripts/smthrs diff` |
| Build artifacts & audit reports | `work_link_post` | `scripts/smthrs artifact list/download` |

Person-only actions (`pr/merge`, `todo/commit`, `todo/drop`, `release/publish`, and secret updates) are enforced server-side and never executed by agents.

## 3. Shared object store and trust boundaries

- Every cached build and test runs through `scripts/smthrs ci //...` or `scripts/smthrs affected`, backed by the shared Smithers Cloud object store at `https://build.smithers.sh`.
- **Untrusted / contributor runs** are encouraged and use read-only trunk cache (`SMITHERS_CACHE_READ_TOKEN`) with PR-scoped or local namespaces (`SMITHERS_CACHE_NAMESPACE=pr-<n>`). They never receive `SMITHERS_CACHE_WRITE_TOKEN` and never skip required gates.
- **Trusted maintainer sandboxes** (and `main` push jobs in the `cache-publish` environment) publish verified outputs to the trunk object store and satisfy merge/release gates.

## 4. Tiered backpressure and Lighthouse audit

1. **Fast check (seconds):** `scripts/smthrs ci //.smithers:hygiene //.smithers:test-js //.smithers:factory-check //.smithers:trust-check`
2. **Medium check (minutes):** `scripts/smthrs ci //.smithers:test-unit //.smithers:build //.smithers:audit //.smithers:wiki-check //.smithers:history-check`
3. **Full check (release gate):** `scripts/smthrs ci //...` + Linux coverage-guided fuzzing (`./scripts/fuzz-linux.sh`) + `CLAUDE_P_E2E=1 sh .smithers/run-zig.sh build test-integration --summary all`

Inspect the Lighthouse-style audit report at `.smithers/reports/audit.html` (and published live at `https://smithersai.github.io/claude-p/audit/`). Never lower an Uphill target to make a red score green.

## 5. Version control and repository invariants

- Use Jujutsu (`jj`) for every VCS operation. Never invoke the `git` CLI directly.
- Never mutate `~/.claude/`.
- Keep `SPEC.md`, `README.md`, `docs/`, `.smithers/wiki/`, and `.smithers/FACTORY.ts` in lockstep with code changes.
- After editing `.smithers/FACTORY.ts` or any flow, run `scripts/smthrs target //.smithers:factory-write --write` and verify `scripts/smthrs target //.smithers:factory-check`.
