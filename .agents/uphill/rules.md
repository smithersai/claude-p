# Rules

Uphill writes these rules from each metric's `description`. Write code that meets them. `uphill` scores each metric against its target, and `uphill --compare HEAD --compact` lists what a change made worse.

## Footprint

Keep Zig PTY/daemon modules and JS supply-chain scripts small, modular, and dependency-minimal.

- Keep each Zig source module under 500 production lines by factoring state machines into cohesive files. At most 500.
- Keep each Zig source file and JS installer/launcher script lean and free of duplicated logic. At most 20 kB.
- Avoid adding unnecessary Zig package dependencies in build.zig.zon.
- Keep package.json free of runtime npm dependencies so npx claude-p stays fast and auditable.

## Style & TigerStyle

Enforce zig fmt and TigerStyle limits on function length, line width, and assertion density.

- Format all Zig source and property-test files with `zig fmt`.
- Keep every Zig function at or under 70 lines (TigerStyle rule); split event loops and parsers into helpers. At most 70.
- Wrap Zig lines at or under 120 columns for readability.
- Assert protocol, offset, and PTY state invariants with `std.debug.assert` (target >= 15 per kLOC). At least 15.

## Correctness

Enforce version lockstep, release script syntax, Smithers factory projection freshness, and panic-free Zig code.

- Keep package.json, build.zig.zon, and src/root.zig versions identical; verify with `node scripts/publish.mjs --check-versions`.
- Keep bin/claude-p.js and scripts/* syntactically valid under node/sh/bash.
- Keep Smithers factory projections fresh (`smthrs target //.smithers:factory-write --write`).
- Return typed Zig errors instead of `@panic`, `unreachable`, or `catch unreachable` in production code.
- Handle errors explicitly instead of silently swallowing them with `catch {}`.
- Resolve TODO/FIXME markers instead of leaving them in production Zig modules.

## Testing

Verify installer supply-chain tests pass and every Zig module has deep unit and property/fuzz coverage.

- Keep all JS installer checksum and supply-chain property tests passing.
- Keep thorough inline unit tests in every src/*.zig module (target >= 20 tests per module). At least 20.
- Pair every core src/*.zig module with property or fuzz tests under `tests/prop/`.

## Documentation

Keep Zig public declarations documented, Markdown links valid, and Astro docs frontmatter complete.

- Document public Zig functions and constants with `///` doc comments (target >= 90%). At least 90.
- Keep relative links in README.md, SPEC.md, CLAUDE.md, and AGENTS.md valid.
- Include both `title` and `description` frontmatter in every docs page under `docs/src/content/docs/`.

## Factory & Trust

Enforce Smithers Cloud shared object-store caching, non-poisoning trust boundaries, personalized 3-audience UI, wiki freshness, mythical history, and one-time MCP sandbox auth.

- Configure .smithers/WORKSPACE.ts with https://build.smithers.sh and separate SMITHERS_CACHE_READ_TOKEN and SMITHERS_CACHE_WRITE_TOKEN secrets.
- Pass .smithers/tests/trust-boundaries.test.mjs to prevent cache poisoning and untrusted gate bypasses.
- Keep .smithers/home.json personalized across maintainer, contributor, and everyone audiences with an https:// docs llms.txt URL.
- Keep all Engineering Wiki citations and source digests fresh (`node .smithers/flows/wiki/sync-wiki.mjs --write`).
- Keep Mythical History generated and verified (`node .smithers/flows/mythical-history/generate.mjs --write`).
- Keep scripts/smithers-auth.mjs valid and able to print attenuated sandbox and Cloud MCP bootstrap config.
