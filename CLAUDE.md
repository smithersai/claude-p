# CLAUDE.md — repository instructions for agents

> **Start here on every session or after compaction.** Re-read
> [SPEC.md](./SPEC.md) and [README.md](./README.md) before modifying code. The
> source tree and `SPEC.md` are authoritative—never assume prior conversation
> notes match HEAD.

## Project

`claude-p` (`0.1.3`) — a Zig 0.15.2 library and CLI that emulates `claude -p`
by driving the interactive `claude` binary inside an in-process
[zmux][zmux] PTY session, reading lifecycle events over a per-run hook FIFO,
and emitting `claude -p`-compatible output.

[zmux]: https://github.com/smithersai/zmux

## Working rules

1. **Spec and code stay in sync.** Update `SPEC.md`, `README.md`, and `docs/`
   in the same change as any behavioral, flag, protocol, or error change. Never
   document unimplemented flags or protocol frames as shipped.
2. **TDD first.** Write a failing unit test in the owning module (`src/*.zig`)
   before implementing behavior. Keep `tests/integration.zig` mock-free—it tests
   against the real `claude` binary.
3. **Never mutate `~/.claude/`.** Every hook script, FIFO, and temporary
   directory lives under `$TMPDIR/claude-p-<pid>-<rand>/` and is removed in
   `HookHarness.deinit()`.
4. **Zig 0.15.2 pin.** `zmux` enforces `0.15.2` at comptime. Do not bump the
   `zmux` SHA in `build.zig.zon` without passing `CLAUDE_P_E2E=1 zig build test-integration`.
5. **Version lockstep.** Keep `0.1.3` identical across `package.json`,
   `build.zig.zon`, and `src/root.zig`. Verify with
   `node scripts/publish.mjs --check-versions`.

## Build and test commands

```bash
# Unit tests (113 tests, no external `claude` required; use Zig 0.15.2)
zig build test

# Release build
zig build -Doptimize=ReleaseSafe

# Version & release script hygiene (same checks as CI)
node scripts/publish.mjs --check-versions
node --check scripts/install.js && node --check scripts/publish.mjs

# End-to-end tests against the real `claude` binary on $PATH
CLAUDE_P_E2E=1 zig build test-integration

# Documentation site (Starlight)
cd docs && npm run build
```

## Module map

| Path | Role |
| --- | --- |
| `src/main.zig` | CLI entry point, one-shot vs `daemon` dispatch, exit-code mapping (`0`, `1`, `2`). |
| `src/root.zig` | Public Zig library facade and `version`. |
| `src/args.zig` | Argparse, variadic flags, boolean passthrough list, cross-flag rules. |
| `src/terminal.zig` | Stateless DEC/XTerm responder (`DA1`, `DA2`, `DSR`, `XTVERSION`, `18t`). |
| `src/hook.zig` | Inline `--settings`, `extra_hooks`, `extra_settings_json`, FIFO, `hook.sh`. |
| `src/driver.zig` | One-shot lifecycle, env filter, startup dialog state machine, `PasteChunker`, watchdog. |
| `src/daemon.zig` | Long-lived NDJSON daemon (`user`, `ping`/`pong`, `system/init`, `result`, idle watchdog, `CLAUDE_P_PTY_TRACE`). |
| `src/transcript.zig` | Session JSONL parser and offset-scoped `parseFileFromOffset`. |
| `src/stream.zig` | `pread`-based line-buffered transcript `Tailer`. |
| `src/emit.zig` | `text`, `json`, and `stream-json` formatters. |
| `tests/integration.zig` | Real-`claude` end-to-end suite (`CLAUDE_P_E2E=1`). |
| `bin/claude-p.js` | Node shim spawning `prebuilt/<platform>-<arch>/claude-p` and forwarding signals. |
| `scripts/install.js` | Postinstall binary downloader with `SHA256SUMS` verification. |
| `docs/` | Astro + Starlight documentation site. |

## Load-bearing invariants and gotchas

- **No zmux re-entrancy from `EventSink`.** `onZmuxEvent` runs on zmux's reader
  thread. Never call `session.writeInput` inside it; queue bytes in
  `shared.pending_to_pty` under `shared.write_mutex` and flush from the main
  loop (`flushPendingToPty`).
- **Ink hangs without DEC/XTerm replies.** Every `pane_output` chunk must pass
  through `terminal.respondToDecQueries`.
- **Open FIFO before spawn.** Open `events.fifo` with `O_RDONLY | O_NONBLOCK`
  before creating the `NativeSession` so `hook.sh` never blocks on write.
- **Targeted env filtering (`shouldStripChildEnv`).** Strip only nested-session
  markers (`CLAUDECODE`, `AI_AGENT`, `CLAUDE_CODE_ENTRYPOINT`,
  `CLAUDE_CODE_SSE_PORT`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`,
  and prefixes `CLAUDE_CODE_SESSION_`, `CLAUDE_CODE_PARENT_`,
  `CLAUDE_CODE_SUBAGENT_`). **Never** blanket-strip `CLAUDE_CODE_*`—that breaks
  `CLAUDE_CODE_OAUTH_TOKEN`, Bedrock, Vertex, and Foundry auth.
- **Claude Code 2.1 trust dialog defaults to "No, exit".** `maybeHandleStartupDialogs`
  must verify `❯` sits on the affirmative option on repaint before sending `\r`.
- **macOS `TTYHOG` is 1024 bytes.** Always submit one-shot prompts through
  `typePrompt` (`PasteChunker`: `<= 512` B UTF-8-safe chunks, `8 ms` gaps,
  `\x1b[201~` neutralization, `120 ms` Enter debounce).
- **Stop / transcript flush race.** `Stop` can fire before the final assistant
  line hits disk. Retry `parseFileFromOffset` up to 20×50 ms (30× on
  `last_assistant_message` mismatch), then fall back to Stop's
  `last_assistant_message`.
- **Resume offset isolation.** On `--resume`/`--continue`, wait for restored UI
  quiescence (`400 ms`, cap `6000 ms`), snapshot `pre_prompt_transcript_offset`,
  and parse only appended bytes via `parseFileFromOffset`.
- **Daemon parity caveat.** `src/daemon.zig` still has its own inline dialog
  check, `session.send`, and full env copy rather than sharing
  `driver.maybeHandleStartupDialogs`, `driver.typePrompt`, and
  `driver.buildChildEnv`. Check both files when fixing startup or paste bugs.

## Code conventions

- Allocator-per-function for every public API.
- Explicit `error{...}` unions in public APIs—never `anyerror`.
- Gate diagnostic output on `opts.debug` (or `CLAUDE_P_PTY_TRACE` in daemon).
- Fail loudly when required fields (such as `transcript_path` when fallback is
  absent) are missing.
