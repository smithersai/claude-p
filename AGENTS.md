# AGENTS.md — Smithers Cloud agent instructions for `smithersai/claude-p`

Follow the [Uphill rules](.agents/uphill/rules.md), which `uphill rules --write` rewrites from each metric's description: @.agents/uphill/rules.md

Read [CLAUDE.md](./CLAUDE.md), [SPEC.md](./SPEC.md), and [.smithers/instructions/agent.md](./.smithers/instructions/agent.md) before modifying code.

## Smithers Cloud First (MCP & Factory)

`smithersai/claude-p` runs publicly on Smithers Cloud (`https://smithers.sh/smithersai/claude-p`) and mirrors to GitHub (`https://github.com/smithersai/claude-p`).

- **Authenticated Cloud MCP:** Connect your agent to `https://smithers.sh/api/mcp` (and register the local gateway via `scripts/smthrs mcp add`) to read repo files/docs (`repo_tree`, `repo_read_file`, `docs_list`, `docs_read`), discover flows (`flows_list`), draft public TODOs (`todo_list`, `todo_draft`), file or comment on issues (`issue_create`, `issue_comment`), inspect PRs (`pulls_list`, `pull_get`), and link verified artifacts (`work_link_post`).
- **One-time sandbox auth:** Run `node scripts/smithers-auth.mjs` (or `scripts/smthrs token mint --scope read:runs --ttl 15m`) to print short-lived, attenuated credentials for ephemeral sandboxes and BYOA agents. Never copy master tokens or cookies into sandboxes.
- **Shared object store & trust boundaries:** Run `scripts/smthrs ci //...` or `scripts/smthrs affected` (backed by `https://build.smithers.sh`). Non-maintainer and untrusted runs are encouraged and receive read-only trunk cache hits, but never write trunk keys or bypass maintainer sandbox gates.
- **Lighthouse-style backpressure:** Run `uphill --compact` and `node .smithers/audit/generate-lighthouse.mjs --no-run` to inspect `.smithers/reports/audit.html` (published live at `https://smithersai.github.io/claude-p/audit/`).
- **Engineering Wiki & Mythical History:** Update `.smithers/wiki/pages/*.md` when subsystem architecture or invariants change, then sync with `node .smithers/flows/wiki/sync-wiki.mjs --write` and `node .smithers/flows/mythical-history/generate.mjs --write`.
- **Version control:** Use Jujutsu (`jj`) exclusively. Never invoke `git` directly. Person-only actions (`pr/merge`, `todo/commit`, `release/publish`, secrets) stay with the maintainer (`roninjin10`).
