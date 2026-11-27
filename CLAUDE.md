# CLAUDE.md — repository instructions for agents

Follow the [Uphill rules](.agents/uphill/rules.md), which `uphill rules --write` rewrites from each metric's description: @.agents/uphill/rules.md

For Smithers Cloud MCP workflows (authenticated `https://smithers.sh/api/mcp`, one-time sandbox auth via `node scripts/smithers-auth.mjs`, shared object-store CI via `scripts/smthrs`, Engineering Wiki, Mythical History, and trust boundaries), see [AGENTS.md](./AGENTS.md) and [.smithers/instructions/agent.md](./.smithers/instructions/agent.md).

> **Start here on every session or after compaction.** Re-read
> [SPEC.md](./SPEC.md) and [README.md](./README.md) before modifying code. The
> source tree and `SPEC.md` are authoritative—never assume prior conversation
> notes match HEAD.

## Project

`claude-p` (`0.1.3`) — a Zig 0.15.2 library and CLI that emulates `claude -p`
by driving the interactive `claude` binary inside an in-process
[zmux][zmux] PTY session, reading lifecycle events over a per-run hook FIFO,
and emitting `claude -p`-shaped `text`/`json` results. `stream-json` is
filtered session-transcript JSONL plus a `claude -p`-shaped final `result`
envelope, not native `claude -p` stream-json (transcript lines use
`sessionId`, not `session_id`). Never call it wire-compatible or drop-in.

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
# Unit, property, concurrency and fuzz-corpus tests (no external `claude`
# required; use Zig 0.15.2). Includes everything in `test-prop`.
# Never hard-code test counts in docs; `--summary all` prints them.
zig build test --summary all
zig build test -Dtest-filter="daemon"

# Property + fuzz suites only (tests/prop_fuzz.zig -> tests/prop/*.zig).
# On macOS this replays every fuzz corpus; it does not mutate inputs.
zig build test-prop

# Live coverage-guided fuzzing (Linux only in Zig 0.15.2). Runs every
# std.testing.fuzz target in parallel; corpus persists in ~/.cache/claude-p-fuzz.
ZIG_BIN=~/.local/zig-0.15.2/zig FUZZ_SECONDS=600 ./scripts/fuzz-linux.sh
./scripts/fuzz-linux.sh "transcript"     # one area

# Node supply-chain property/fuzz suite (install.js, publish.mjs, launcher)
node --test tests/prop/js_supplychain_prop.mjs

# Release build
zig build -Doptimize=ReleaseSafe

# Version & release script hygiene (same checks as CI)
node scripts/publish.mjs --check-versions --expect-version=0.1.3
node --check scripts/install.js && node --check scripts/publish.mjs && node --check bin/claude-p.js
sh -n scripts/build-in-linux.sh && bash -n scripts/fuzz-linux.sh && sh -n .smithers/run-zig.sh
node --test .smithers/tests/install-checksum.test.mjs tests/prop/js_supplychain_prop.mjs
# Factory projections (.smithers/factory.json, home.json) match FACTORY.ts;
# on failure run `smthrs target //.smithers:factory-write --write`
node --test .smithers/tests/factory-projections.test.mjs

# End-to-end tests against the real `claude` binary on $PATH
CLAUDE_P_E2E=1 zig build test-integration --summary all

# Documentation site (Starlight)
cd docs && npm run build
```

## Module map

| Path | Role |
| --- | --- |
| `src/main.zig` | CLI entry point, one-shot vs `daemon` dispatch, signal handlers, exit-code mapping (`0`, `1`, `2`, `124`, `128 + sig`). |
| `src/stdin.zig` | Bounded stdin reader (`<stdin>\n\n<PROMPT>` composition with 3 s grace). |
| `src/root.zig` | Public Zig library facade and `version`. |
| `src/args.zig`, `src/args/flags.zig`, `src/args_help.txt` | Argparse (`--flag=value`, `-r`, `-c`), variadic flags, `rejected_flags`, boolean passthrough list, cross-flag rules, and embedded help text. |
| `src/terminal.zig` | Streaming `DecDecoder` DEC/XTerm responder (`DA1`, `DA2`, `DSR`, `XTVERSION`, `18t` with configured rows/cols). |
| `src/hook.zig`, `src/hook/settings.zig` | Inline `--settings` (5 relay hooks), `extra_hooks` (`--extra-hook`), `extra_settings_json` (`--setting-json`), FIFO, nonce-tagged `hook.sh`. |
| `src/driver.zig`, `src/driver/{spawn,env,stop_scan,watchdog,paste,dialog,diag,runtime,finalizer,session}.zig` | One-shot lifecycle DAG: spawn/env filtering, intent-gated startup dialog FSM, `PasteChunker`, provisional Stop scanner, watchdogs, bounded diagnostics, finalizer, and session loop. |
| `src/daemon.zig`, `src/daemon/{protocol,queue,paste,turn,runtime}.zig` | Long-lived NDJSON daemon DAG (`user`, `ping`/`pong`, `interrupt`, `system/init`, `result`, `type:"error"` protocol frames, 64-prompt / 64 MiB queue, incremental `PendingPaste`, turn transcript cursor, idle + transcript watchdogs). |
| `src/transcript.zig`, `src/transcript/file.zig` | Session JSONL parser, symlink-safe `openTranscriptRegularFile`, and offset-scoped `parseFileFromOffset`; dedups records by `uuid` and usage by `message.id`. |
| `src/stream.zig` | `pread`-based line-buffered transcript `Tailer`; discards a partial line over 16 MiB. |
| `src/emit.zig` | `text`, `json`, and `stream-json` formatters plus protocol/error helpers. |
| `tests/fixtures.zig`, `tests/{args_cli_tests,daemon_fixtures,driver_fixtures,main_launcher_test,module_fixtures}.zig` | Multi-module behavioral and launcher fixture suite run under `zig build test`. |
| `tests/integration.zig` | Real-`claude` end-to-end suite (`CLAUDE_P_E2E=1`). |
| `tests/prop_fuzz.zig`, `tests/prop/*.zig` | Property suites and `std.testing.fuzz` targets for every module, plus concurrency and mock-PTY end-to-end fuzzing. |
| `scripts/fuzz-linux.sh` | Linux coverage-guided fuzz campaign runner (all targets, one instrumented binary). |
| `bin/claude-p.js` | Node shim spawning `prebuilt/<platform>-<arch>/claude-p` and forwarding signals. |
| `scripts/install.js` | Postinstall binary downloader; verifies against bundled `checksums.json`, else required `SHA256SUMS`; reuses a binary only on exact `binSha256` match and unlinks a mismatched one before downloading; only connectivity failures (`isConnectivityError`) warn and exit `0` unless `CLAUDE_P_STRICT_INSTALL=1`; filesystem errors exit `1`. |
| `scripts/publish.mjs` | Release builder; checks tag peeled commit == `HEAD` (local and remote), writes `SHA256SUMS` + `checksums.json`, verifies existing release assets by digest, stages npm publish in a private temp dir (never writes repo-root `checksums.json`). |
| `docs/` | Astro + Starlight documentation site. |

## Load-bearing invariants and gotchas

- **No zmux re-entrancy from `EventSink`.** `onZmuxEvent` runs on zmux's reader
  thread. Never call `session.writeInput` inside it; queue bytes in
  `shared.pending_to_pty` under `shared.write_mutex` and flush from the main
  loop (`flushPendingToPty`).
- **Ink hangs without DEC/XTerm replies.** Every `pane_output` chunk must pass
  through the session's stateful `terminal.DecDecoder.feed` (`shared.dec`),
  which carries a query split across reads. Never use the one-shot
  `respondToDecQueries` on a live stream; it drops split queries.
- **Hook relay.** Five relay hooks (`SessionStart`, `UserPromptSubmit`,
  `Stop`, `StopFailure`, `PermissionRequest`) always sit at index 0. `hook.sh`
  embeds the FIFO path and a per-run nonce and writes
  `<nonce>\t<event>\t<json>`; parse with `parseLineWithNonce`.
  `CLAUDE_P_FIFO` is never exported and `buildChildEnv` drops an inherited one.
- **`PermissionRequest` fails fast.** One-shot returns
  `RunError.PermissionPromptBlocked` (exit `2`); the daemon sends ESC, emits a
  `type:"result"` frame (`subtype:"error_during_execution"`,
  `error:"permission_prompt_blocked"`), and returns to `.idle`.
  `--setting-json` rejects `"disableAllHooks": true` and nesting past 128.
- **Startup dialogs are intent-gated.** `dialogConfirmAllowed` answers
  bypass-permissions or development-channels dialogs only when this
  invocation's flags ask for them; otherwise fail with
  `UnexpectedStartupDialog` and send no key.
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
- **Provisional `Stop`.** Both modes confirm at once on a
  `stop_hook_summary` record with `preventedContinuation: false`, else wait a
  fallback window (`150 ms`, `2000 ms` with `--extra-hook Stop=`;
  `stopConfirmationNs`) so a blocking Stop hook can continue the turn. A later
  `Stop` (`stop_hook_active: true`), `preventedContinuation: true`, or new
  transcript assistant activity supersedes it.
- **Stop / transcript flush race.** `Stop` can fire before the final assistant
  line hits disk. One pump-and-parse loop retries up to `20 × 20 ms`
  (one-shot) or `30 × 25 ms` (daemon), exits early on a match with Stop's
  `last_assistant_message`, then falls back to that text.
- **`StopFailure` keeps usage.** Both modes parse the transcript first, force
  `is_error: true`, and use the hook's error text; the daemon adds
  `"error":"stop_failure"`. `synthesizeStopFailureSummary` is only the
  no-transcript fallback.
- **Daemon paste is incremental.** `PendingPaste` writes one `PasteChunker`
  chunk per loop tick so `ping`/`interrupt` stay responsive; never call the
  blocking `typePrompt` from `daemon.zig`.
- **Resume offset isolation.** On `--resume`/`--continue`, wait for restored UI
  quiescence (`400 ms`, cap `6000 ms`), snapshot `pre_prompt_transcript_offset`,
  and parse only appended bytes via `parseFileFromOffset`.
- **Daemon shares driver startup code.** `src/daemon.zig` calls
  `driver.maybeHandleStartupDialogs`, `driver.PasteChunker`, and
  `driver.buildChildEnv`. Fix startup, paste, and env bugs once in
  `src/driver.zig` and test both modes.
- **Exit codes.** `0` success, `1` `is_error` (including `StopFailure`), `2`
  usage or runtime error (including `InvalidCwd`, `UnexpectedStartupDialog`,
  `PermissionPromptBlocked`, `InvalidOptions`, and `Interrupted` without a
  caught signal), `124` every timeout in both modes including one-shot
  `TranscriptStalled` (`exitCodeForRunError` in `src/main.zig`, `daemon.run`
  for `session_start_timeout`/`idle_timeout`/`transcript_stalled`), `128 + sig`
  set by the native binary after a signal (a duplicate signal within 2 s is
  ignored so `bin/claude-p.js` process-group `SIGINT` still cleans up).
- **Rejected print-only flags.** `--max-turns`, `--fallback-model`,
  `--include-partial-messages`, `--forward-subagent-text`,
  `--replay-user-messages`, `--verbose-thinking` exit `2` (`UnsupportedFlag`
  in the CLI, `RunError.InvalidOptions` from `validateOptions`). Daemon mode
  rejects `--output-format text`/`json`.
- **Daemon frames.** Non-turn protocol rejections (`invalid_json`,
  `unsupported_frame_type`, `invalid_user_message`,
  `unsupported_content_block`, `stdin_line_too_large`, `fifo_line_too_large`,
  `queue_full`) are `{"type":"error","error":"<reason>"}`. `type:"result"` is
  reserved for turn-ending and session-ending frames (startup failures
  `claude_not_found`/`spawn_failed` included). Blank stdin lines are ignored
  silently. EOF before `SessionStart` with nothing queued exits `0`.
- **Redacted failure diagnostics.** Default stderr shows stage, cause, status,
  timings, and PTY bytes only; the screen excerpt needs `--debug` or
  `CLAUDE_P_DEBUG_SCREEN=1`.
- **Install trust root.** `checksums.json` (bundled by `publish.mjs`) wins over
  `SHA256SUMS`; `SHA256SUMS` 404 is fatal for `>= 0.1.3`. Integrity failures
  always exit `1`; only connectivity failures may exit `0`. Never add a silent
  unverified fallback.

## Code conventions

- Allocator-per-function for every public API.
- Explicit `error{...}` unions in public APIs—never `anyerror`.
- Gate diagnostic output on `opts.debug` (or `CLAUDE_P_PTY_TRACE` in daemon).
- Fail loudly when required fields (such as `transcript_path` when fallback is
  absent) are missing.
