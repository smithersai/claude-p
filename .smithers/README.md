# claude-p factory (`smithers.sh/smithersai/claude-p`)

Local-first Smithers factory and incremental CI for `smithersai/claude-p`.

- **Discovery:** `.smithers/WORKSPACE.ts`, `.smithers/PACKAGE.ts`, and `.smithers/FACTORY.ts` (`WORKSPACE.smithers` re-exports `Workspace` and `Package` for compatibility).
- **Local-first cache + Cloudflare sync:** Action results cache locally under `.smithers/cache` and sync through Cloudflare (`https://build.smithers.sh`) whenever `SMITHERS_CACHE_READ_TOKEN` / `SMITHERS_CACHE_WRITE_TOKEN` are set in the environment (local or CI).
- **Fine-grained incremental invalidation:** Source closures are split across `zig-sources`, `js-sources`, `version-sources`, and `factory-sources` so doc or JS edits never invalidate Zig compilation/tests.

## Targets (`//.smithers:<name>`)

| Target | Kind | What it runs |
| --- | --- | --- |
| `hygiene` | test | Verifies non-empty `LICENSE` and version agreement across `package.json`, `build.zig.zon`, and `src/root.zig` |
| `test-js` | test | `node --check` on the JS scripts, `sh -n scripts/build-in-linux.sh`, `bash -n scripts/fuzz-linux.sh`, and `node --test` on `.smithers/tests/install-checksum.test.mjs`, `.smithers/tests/factory-projections.test.mjs`, and `tests/prop/js_supplychain_prop.mjs` |
| `factory-check` | build, lint | Verifies `.smithers/factory.json` and `.smithers/home.json` match `.smithers/FACTORY.ts` and discovered flows |
| `factory-write` | build, lint | Regenerates `.smithers/factory.json` and `.smithers/home.json` (`smthrs target //.smithers:factory-write --write`) |
| `build` | build | `zig build -Doptimize=ReleaseSafe` (Zig 0.15.2 via `.smithers/run-zig.sh`) |
| `test-unit` | test | `zig build test --summary all` (unit, property, and fuzz-corpus tests; zero leaks) |
| `build-linux-x64` | build | Cross-compile `x86_64-linux-musl` (`ReleaseSafe`) |
| `build-linux-arm64` | build | Cross-compile `aarch64-linux-musl` (`ReleaseSafe`) |
| `build-darwin-arm64` | build | Cross-compile `aarch64-macos` (`ReleaseSafe`) |
| `build-darwin-x64` | build | Cross-compile `x86_64-macos` (`ReleaseSafe`) |
| `test-e2e` | test (manual) | Real-Claude E2E suite (`CLAUDE_P_E2E=1 zig build test-integration`, zero mocks) |

## Quick commands

```sh
# Fast incremental CI (offline, cached locally & via Cloudflare remote cache):
smthrs ci //...

# Run only targets affected by uncommitted changes:
smthrs affected

# Inspect target graph and cache keys:
smthrs targets
smthrs explain //.smithers:test-unit

# Regenerate smithers.sh/smithersai/claude-p projections after editing FACTORY.ts:
smthrs target //.smithers:factory-write --write

# Run live real-Claude E2E suite on demand:
smthrs run //.smithers:test-e2e
```
