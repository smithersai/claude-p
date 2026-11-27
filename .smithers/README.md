# claude-p factory (`smithers.sh/smithersai/claude-p`)

Public Smithers Cloud coding factory, shared object-store CI, Lighthouse-style Uphill audit backpressure, Engineering Wiki, Mythical History, and authenticated Cloud MCP workflow for `smithersai/claude-p`.

- **Workspace & Factory:** `.smithers/WORKSPACE.ts`, `.smithers/PACKAGE.ts`, `.smithers/FACTORY.ts`, `.smithers/trust-policy.json`, and projected `.smithers/factory.json` / `.smithers/home.json`.
- **Personalized 3-Audience UI:** `.smithers/home.json` tailors views for `maintainer`, `contributor`, and `everyone` (viewers), plus wires `docs` to `https://smithersai.github.io/claude-p/llms.txt`.
- **Shared Smithers Cloud Object Store:** Action results cache locally under `.smithers/cache` and sync through `https://build.smithers.sh` with strict read/write credential separation (`SMITHERS_CACHE_READ_TOKEN` for PRs and contributor runs; `SMITHERS_CACHE_WRITE_TOKEN` strictly on `main` in the `cache-publish` environment).
- **Untrusted Execution Policy:** Non-maintainers are encouraged to run tests, Uphill audits, and repro flows. Untrusted runs never write to trunk cache keys and never satisfy merge or release gates.
- **Auto-Publishing on Merge to `main`:** Merging from Smithers Cloud to GitHub automatically triggers docs, Engineering Wiki, Mythical History, Lighthouse audit publishing (`.github/workflows/docs.yml`), trusted trunk cache publication (`.github/workflows/ci.yml`), and version-bump releases (`.github/workflows/auto-release.yml` -> `.github/workflows/release.yml`).
- **Cloud MCP & One-Time Sandbox Auth:** Connect agents to `https://smithers.sh/api/mcp` and mint attenuated sandbox auth via `node scripts/smithers-auth.mjs`.

## Targets (`//.smithers:<name>`)

| Target | Kind | What it runs |
| --- | --- | --- |
| `hygiene` | test | Verifies non-empty `LICENSE` and version agreement across `package.json`, `build.zig.zon`, and `src/root.zig` |
| `test-js` | test | Syntax checks for JS/shell scripts plus `install-checksum`, `factory-projections`, `trust-boundaries`, and `js_supplychain_prop` |
| `trust-check` | test | Verifies trust boundaries, cache read/write split, and `smithers-auth.mjs --dry-run` |
| `wiki-check` | test | Verifies Engineering Wiki citations, `[[wikilinks]]`, and source input digests |
| `history-check` | test | Verifies Mythical History chronicle and `history.json` integrity |
| `factory-check` | build, lint | Verifies `.smithers/factory.json` and `.smithers/home.json` match `.smithers/FACTORY.ts` and discovered flows |
| `factory-write` | build, lint | Regenerates `.smithers/factory.json` and `.smithers/home.json` (`scripts/smthrs target //.smithers:factory-write --write`) |
| `build` | build | `zig build -Doptimize=ReleaseSafe` (Zig 0.15.2 via `.smithers/run-zig.sh`) |
| `test-unit` | test | `zig build test --summary all` (unit, property, and fuzz-corpus tests; zero leaks) |
| `build-linux-x64` | build | Cross-compile `x86_64-linux-musl` (`ReleaseSafe`) |
| `build-linux-arm64` | build | Cross-compile `aarch64-linux-musl` (`ReleaseSafe`) |
| `build-darwin-arm64` | build | Cross-compile `aarch64-macos` (`ReleaseSafe`) |
| `build-darwin-x64` | build | Cross-compile `x86_64-macos` (`ReleaseSafe`) |
| `audit` | run (manual) | Runs Uphill continuous metrics and renders the Lighthouse-style audit report (`docs/public/audit/index.html`) |
| `test-e2e` | run (manual) | Real-Claude E2E suite (`CLAUDE_P_E2E=1 zig build test-integration`, zero mocks) |

## Quick commands

```sh
# Fast incremental CI (cached locally and via https://build.smithers.sh):
scripts/smthrs ci //...

# Run only targets affected by uncommitted changes:
scripts/smthrs affected

# Regenerate smithers.sh/smithersai/claude-p projections after editing FACTORY.ts:
scripts/smthrs target //.smithers:factory-write --write

# Run Uphill Lighthouse backpressure audit:
scripts/smthrs run //.smithers:audit

# Mint attenuated one-time sandbox / Cloud MCP bootstrap auth:
node scripts/smithers-auth.mjs

# Sync Engineering Wiki and Mythical History:
node .smithers/flows/wiki/sync-wiki.mjs --write
node .smithers/flows/mythical-history/generate.mjs --write

# Run live real-Claude E2E suite on demand:
scripts/smthrs run //.smithers:test-e2e
```
