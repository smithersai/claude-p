# `claude-p` — Implementation Report

This report records the original v0.1.0 implementation milestone.

## What shipped

A working CLI + Zig library that emulates `claude -p` (Claude Code's
print mode) by driving the interactive `claude` binary inside an
in-process zmux PTY session.

Verified end-to-end against the real `claude` binary (no mocks):

```
$ ./zig-out/bin/claude-p --dangerously-skip-permissions \
    "Reply with the single word OK and nothing else."
OK

$ ./zig-out/bin/claude-p --output-format json --dangerously-skip-permissions \
    "Reply with the single word OK and nothing else."
{"type":"result","subtype":"success","session_id":"...","result":"OK",
 "is_error":false,"duration_ms":2911,"duration_api_ms":0,"num_turns":1,
 "total_cost_usd":0,"usage":{"input_tokens":6,"output_tokens":6,...},
 "permission_denials":[]}

$ ./zig-out/bin/claude-p --output-format stream-json ...   # JSONL transcript replay + result
```

All three modes (`text`, `json`, `stream-json`) round-trip claude's
actual output. Exit code is `0` on success, `1` on `is_error`, `2` on
wrapper-level failure.

## Files added / changed

| File | Role |
| ---- | ---- |
| `SPEC.md` | Architecture, API, formats, exit codes, test plan. |
| `README.md` | End-user contract (CLI + library). |
| `CLAUDE.md` | Agent-facing rules: re-read SPEC/README after compaction; TDD; no global state. |
| `REPORT.md` | This file. |
| `build.zig`, `build.zig.zon` | Wires the `claude-p` module + exe; pulls zmux from GitHub. |
| `src/args.zig` | Argparse for the `claude -p` flag surface (16 tests). |
| `src/transcript.zig` | Session JSONL parser; extracts last assistant text + usage (8 tests). |
| `src/emit.zig` | text / json / stream-json formatters (5 tests). |
| `src/hook.zig` | Inline-settings JSON + FIFO + relay shell script (7 tests). |
| `src/terminal.zig` | Stateless DEC/XTerm query responder for DA1/DA2/DSR/XTVERSION/18t (6 tests). |
| `src/driver.zig` | zmux session lifecycle + FIFO poll loop + argv build + shell-quote (8 tests). |
| `src/root.zig` | Public library API (`run(allocator, opts) → Result`). |
| `src/main.zig` | CLI entry: argv → opts → `run()` → emit → exit. |
| `tests/integration.zig` | Real-claude end-to-end tests, gated on `CLAUDE_P_E2E=1`. |
| `package.json`, `bin/claude-p.js`, `scripts/install.js`, `.npmignore` | npm shim that downloads the prebuilt binary on `npm install`. |

Unit tests: **51 passing** (`zig build test`).  
Integration tests: **3 passing** against real `claude` (`CLAUDE_P_E2E=1 zig build test-integration`).

## Architectural decisions and why

### 1. Drive the interactive UI from a real PTY, not a pipe

Claude Code's TUI is built on [Ink](https://github.com/vadimdemedes/ink),
a React renderer for terminals. Ink refuses to start unless stdin is a
TTY, and at boot it issues DA1 / DA2 / DSR / XTVERSION / window-size
queries that an *actual terminal* is expected to answer. A pipe-based
spawn deadlocks at startup.

This forces the design to be: open a real `pty(7)`, fork the child onto
the slave, manage the master from the parent. Everything else follows
from that.

### 2. zmux for the PTY, not raw `forkpty`

The first iteration of this project (visible in git history before the
zmux pivot) hand-rolled a `forkpty` wrapper and a poll loop. That worked
but reinvented mechanics zmux already ships: a reader thread, bounded
scrollback, `send()`/`writeInput()`/`resize()`, an EventSink for
notifications, and lifecycle (`terminate()` with SIGTERM→SIGKILL
escalation). Switching to `zmux.NativeSession` collapsed several
hundred lines of correctness-critical platform code into one
`create()` call and made the driver's main loop trivial.

The trade-off is the reader thread runs *in parallel* with our main
loop. We resolve that with a mutex-guarded byte buffer: zmux's reader
thread calls our EventSink callback, the callback runs the DEC
responder, and pushes any response bytes into a shared queue. The main
loop drains the queue and calls `session.writeInput`. This avoids
re-entering zmux from inside its own callback.

Pulled as a Zig package via `zig fetch` (not `../zmux` path), per spec:
```toml
.zmux = .{
    .url = "git+https://github.com/smithersai/zmux#9c581d5a4dfc14053177e27f5e98c0ab13ce3768",
    .hash = "zmux-0.1.0-...",
},
```

### 3. Why a tiny DEC responder lives alongside zmux

zmux is a PTY + scrollback + reader-thread library. It does **not** parse
or interpret terminal escape sequences — its scrollback is a raw byte
ring buffer. So even with zmux, the queries Ink issues at boot still
need to be answered by *us*.

`src/terminal.zig` is ~50 lines of state-free ANSI scanning that
recognises the five queries Ink asks at boot and synthesizes the right
response. Pure function; trivial to test (6 unit tests).

If a future Claude release adds a new probe, the failure mode is "the
wrapper hangs at boot" and the fix is "add a case to
`respondToDecQueries`" — one diff, no upstream dependency.

### 4. Stop hook for completion, not screen-scraping

The wrapper needs to know when the assistant has finished its turn.
Three options were on the table:

- **Watch the rendered screen for a prompt indicator.** Fragile —
  cosmetic UI changes between Claude versions would silently break us.
- **Poll the transcript file** for a new `assistant` line. Works, but
  spammy and fragile around partial writes.
- **Register a `Stop` hook via `--settings '<inline-json>'`.** Claude
  Code's hook system fires on lifecycle events and the Stop event
  carries `transcript_path` (and, in recent versions,
  `last_assistant_message` directly). This is the *intended* extension
  point.

We chose Stop, plus SessionStart as a "UI ready to accept keystrokes"
signal:

```json
{ "hooks": {
  "SessionStart": [{ "matcher": "*", "hooks": [...]}],
  "Stop":         [{ "matcher": "*", "hooks": [...]}]
}}
```

The hooks are passed inline on the command line; the user's
`~/.claude/settings.json` is *not* modified. A relay shell script in a
per-run `$TMPDIR/claude-p-<pid>/` reads stdin and appends one line
(`<event>\t<json>\n`) to a named pipe (FIFO) that the wrapper polls.

### 5. FIFO opened before child spawn

A FIFO with no readers blocks writers. If we opened the FIFO *after*
`claude` started, the first hook fire would block on `>> "$fifo"` until
we caught up. Opening O_RDONLY|O_NONBLOCK *before* spawn keeps a reader
on the FIFO at all times, so writers never block.

### 6. Transcript race + payload fallback

Empirically the Stop hook can fire a few milliseconds *before* the
assistant message is flushed to the transcript JSONL — caught this in
the first end-to-end run when `transcript.parse` returned
`NoAssistantMessage` despite the file later containing the right
content. Fix:

1. Retry `parseFile` up to 20× with 50 ms backoff. Catches the race in
   practice (the file is fully written within a single retry tick).
2. If the retry loop exhausts, fall back to the Stop payload's
   `last_assistant_message` field directly. Recent Claude Code versions
   include this string in the payload, so we can synthesize a
   `Summary` with just the final text and session id — enough for
   `--output-format text`.

This makes the wrapper robust against transient transcript-write
latency *and* against the transcript file not existing (e.g. some
sandboxed-config edge cases).

### 7. Field-name flexibility on the transcript

The real Claude transcript JSONL uses `sessionId` (camelCase). The
documented stream-json format uses `session_id`. We accept both, but
prefer `sessionId`. Caught this in the first real run when the JSON
output had `"session_id":""`.

### 8. Tear-down is unconditional

After we have the answer we don't care about a graceful shutdown —
emit the result, then call `session.terminate()`. zmux issues SIGTERM,
waits 200 ms, escalates to SIGKILL. Reap is bounded.

An earlier iteration tried `/exit\r` followed by a blocking `waitpid`.
That hung — `claude` doesn't recognise `/exit` and the blocking wait
sat forever. The current approach is bounded under all conditions.

### 9. TDD-first, then real-claude end-to-end (no mocks)

Original plan included a mock `claude.sh` script for fast integration
tests. We built one, but the user explicitly objected: *"when you
write tests with mocks you aren't testing it just run tests with 0
mocks"*. Removed the mock; the only integration test runs real claude,
gated on `CLAUDE_P_E2E=1`:

```bash
CLAUDE_P_E2E=1 zig build test-integration
```

This is the right call. A mock that the wrapper passes is a mock that
mirrors *our assumptions* about claude, not claude itself — exactly the
class of test that hides real bugs (and exactly how the
sessionId-vs-session_id bug above would have hidden if we'd asserted
the wrong shape on a mock).

Unit tests (51 of them) cover each module's contract in isolation;
integration tests cover the contract against the real binary.

### 10. NPM shim layers cleanly on top

The Zig binary is the source of truth. `npx claude-p` is a Node shim
(`bin/claude-p.js`) that:

1. Computes `prebuilt/<platform>-<arch>/claude-p`.
2. Execs it with `process.argv.slice(2)`.
3. Forwards stdio, exit codes, and signals.

`scripts/install.js` runs as `postinstall` and downloads the right
prebuilt binary from a GitHub release. If the download fails, install
still succeeds (the shim prints a clear error at runtime if the binary
is missing). `CLAUDE_P_SKIP_DOWNLOAD=1` opts out for monorepo
bootstraps.

The `os`/`cpu`/`engines` fields in `package.json` let npm reject
unsupported platforms (no Windows).

## What I had to throw away

- **Self-rolled `forkpty` wrapper** (`src/pty.zig`). Worked, but
  replaced by `zmux.NativeSession` when the user pivoted to zmux.
- **libghostty submodule.** Original spec was libghostty-vt for VT
  state. After research I realised we don't actually *need* a screen
  model — we read the final message from the transcript JSONL, not from
  the rendered terminal. The DEC responder in `terminal.zig` is the
  only piece of "terminal emulation" we kept. When the user switched to
  zmux, dropping libghostty was free.
- **Mock claude.sh.** See decision #9 above.

## Known limitations

- macOS / Linux only (no Windows; zmux doesn't support it either).
- Single-turn print-mode emulation: we tear down after the first `Stop`.
  Multi-turn driving is out of scope.
- Streaming is *buffered*: stream-json mode emits all events from the
  transcript at once after the turn completes, not as they arrive. (Use
  the real `claude -p --output-format stream-json` for true streaming.)
- We don't currently surface tool-approval prompts. Pass
  `--dangerously-skip-permissions` or `--allowedTools`.
- We don't trap SIGINT to clean up the child — relies on zmux's `defer
  session.destroy()` to run. If the parent is SIGKILL'd, the child PTY
  process group survives until its own descendant cleanup.

## Build & run

```bash
git clone https://github.com/smithersai/claude-p
cd claude-p
zig build                            # Debug build
zig build -Doptimize=ReleaseSafe     # Release build
zig build test                       # 51 unit tests
CLAUDE_P_E2E=1 zig build test-integration  # real-claude tests

./zig-out/bin/claude-p --dangerously-skip-permissions "say hi"
```

Or via npm once published:

```bash
npx claude-p --dangerously-skip-permissions "say hi"
```
