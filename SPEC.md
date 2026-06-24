# `claude-p` — Specification

A Zig library + CLI that emulates `claude -p` (Claude Code's print mode) by
driving the `claude` binary in **interactive mode** under an in-process
[zmux] PTY session, prompting it programmatically, and capturing the
final assistant message via a `Stop` hook.

The output on stdout is byte-for-byte the same as what `claude -p` would have
emitted for the same prompt and flags.

[zmux]: https://github.com/smithersai/zmux

---

## 1. Why interactive-mode driving (premise)

Print mode (`claude -p`) is unavailable in this project's target environment.
The remaining option for non-interactive use of `claude` is to run it
interactively and pretend to be a real terminal:

1. A real PTY is required — Ink (Claude's TUI runtime) bails out on non-TTY stdin.
2. The terminal must respond to **DA1**, **DA2**, **XTVERSION**, **cursor position**,
   and **window size** queries during Ink startup, or the UI hangs forever.
3. The wrapper needs a reliable "turn finished" event — not a heuristic on screen
   contents (UI cosmetics change between Claude releases).

[zmux] solves (1) — it spawns a child on a real `openpty(3)` + `forkpty(3)`
PTY, drains output on a reader thread, exposes `send()` / `writeInput()` for
typing, and emits `pane_output` events through an EventSink callback. We
solve (2) with a tiny ANSI scanner that recognises and replies to the DEC /
XTerm queries Ink issues at boot (see `src/terminal.zig`). A `Stop` hook
solves (3).

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          claude-p (Zig CLI)                          │
│                                                                      │
│  ┌─────────┐   ┌──────────┐   ┌─────────────────┐  ┌──────────────┐  │
│  │ argparse│──▶│  driver  │──▶│ zmux.Native     │─▶│ child `claude│  │
│  └─────────┘   │  (loop)  │   │   Session       │◀─│   (Ink TUI)  │  │
│                └──────────┘   │ • forkpty       │  └──────────────┘  │
│                     ▲         │ • reader thread │                    │
│                     │         │ • scrollback    │                    │
│                     │         │ • EventSink     │                    │
│                     │         └────────┬────────┘                    │
│                     │                  │  pane_output                │
│                     │                  ▼                             │
│                     │   ┌──────────────────────────┐                 │
│                     │   │ terminal.respondToDecQ.. │  (queue resp    │
│                     │   │  on reader thread        │   bytes)        │
│                     │   └──────────┬───────────────┘                 │
│                     │              │  main loop flushes              │
│                     │              ▼                                 │
│                     │     session.writeInput(...)                    │
│                     │                                                │
│  ┌──────────────┐   │     ┌───────────────────────────────┐          │
│  │   emit.zig   │   └─────│  hook fifo  (SessionStart,    │          │
│  │ text|json|   │         │              Stop payloads)   │          │
│  │ stream-json  │         └───────────────────────────────┘          │
│  └──────┬───────┘                                                    │
│         ▼                                                            │
│      stdout (claude -p compatible)                                   │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.1 Modules (`src/`)

| File           | Responsibility                                                         |
| -------------- | ---------------------------------------------------------------------- |
| `main.zig`     | CLI entry; wires modules; exit code mapping.                           |
| `args.zig`     | Argparse for the `claude -p` surface (see §4).                         |
| `terminal.zig` | Stateless DEC/XTerm query responder (DA1, DA2, DSR, XTVERSION, 18t).   |
| `hook.zig`     | Generates `--settings` JSON + temp hook shell scripts + named pipe.    |
| `driver.zig`   | zmux session lifecycle; FIFO poll loop; argv build; tear-down.         |
| `transcript.zig`| Parses the session JSONL written by Claude; extracts last assistant message and usage. |
| `emit.zig`     | text / json / stream-json formatters; matches `claude -p` byte-for-byte. |
| `stream.zig`   | Transcript tailer: streams JSONL lines from the live transcript file to a writer as `claude` flushes them. |
| `root.zig`     | Public Zig library API.                                                |

### 2.2 zmux integration

- Pulled in via `zig fetch --save=zmux git+https://github.com/smithersai/zmux`.
- Consumed as the `zmux` module (`b.dependency("zmux", …).module("zmux")`).
- We use **only** `zmux.NativeSession` — not the JSON-RPC daemon. That gives
  us PTY + reader thread + scrollback + event sink without needing a
  separate `zmuxd` process.
- Pinned to Zig **0.15.2** (matches zmux's `comptime` pin).

Concurrency model: zmux's reader thread runs `onZmuxEvent` for every chunk
of PTY output. Our callback runs the DEC responder and queues response
bytes into a mutex-guarded buffer. The driver's main loop flushes that
buffer back to the PTY via `session.writeInput`. This avoids re-entering
zmux from inside its own reader thread.

### 2.3 Hook-driven completion signal

`claude` is launched with `--settings '<inline-json>'` registering two hooks:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "$CLAUDE_P_HOOK ready" }
    ]}],
    "Stop":         [{ "matcher": "*", "hooks": [
      { "type": "command", "command": "$CLAUDE_P_HOOK stop"  }
    ]}]
  }
}
```

A relay script in a per-run `$TMPDIR/claude-p-<pid>/` appends
`<event>\t<payload>\n` to a named pipe (FIFO) which the driver polls.

- **SessionStart payload** tells the driver claude's UI is up and ready
  to accept keystrokes. The driver then calls
  `session.send(opts.prompt, /*enter=*/true)`.
- **Stop payload** carries `transcript_path` — the driver reads that JSONL,
  extracts the last assistant message, emits in the requested format, and
  tears the session down.

We do **not** mutate the user's filesystem outside `$TMPDIR/claude-p-<pid>/`.

### 2.4 Prompt injection

`NativeSession.send(text, enter)` writes the prompt bytes followed by `\r`.
For printable UTF-8 that's all that's needed — Ink reads raw keypresses.
Multiline prompts come via `--input-file` or stdin so we don't need to
escape newlines on the CLI.

### 2.5 Termination

After emitting the result, `session.terminate()` is called. zmux issues
`SIGTERM`, waits ~200 ms for the child to exit, then escalates to
`SIGKILL`. Our exit code is derived from the transcript (`is_error`,
`subtype`), not the child's wait status.

### 2.6 Transcript race + fallback

The `Stop` hook can fire a few ms before `claude` flushes the assistant
JSONL line. The driver retries `parseFile` up to 20× with 50 ms backoff,
then falls back to constructing a `Summary` from the Stop payload's
`last_assistant_message` field. Either path produces a complete Result
for `--output-format text`; the transcript path also fills in usage,
duration_api_ms, num_turns.

### 2.7 Daemon mode (long-lived multi-turn)

`claude-p daemon` keeps one interactive `claude` session alive across many
turns instead of spawning per prompt. It reads newline-delimited JSON frames
on stdin and emits `claude -p`-compatible JSONL on stdout. The session lives
until stdin EOF (then it shuts down after the current turn) or the child exits.

**stdin frames (hub → daemon):**

| Frame | Shape | Effect |
| ----- | ----- | ------ |
| user message | `{"type":"user","message":{"role":"user","content":"…"}}` (also accepts top-level `content`, or a content-block array) | Queued; dispatched to the PTY when the session is idle. |
| ping | `{"type":"ping"}` | Health probe. Handled inline in the main event loop; answered immediately with a `pong`. Never queued, never reaches `claude`. |

**stdout frames (daemon → hub):**

| Frame | Shape | When |
| ----- | ----- | ---- |
| init | `{"type":"system","subtype":"init","session_id":"…"}` | Once, after `SessionStart` hook fires. |
| transcript lines | raw JSONL from the session transcript | Streamed live as `claude` flushes them. |
| result | per-turn result envelope (see §3 `stream-json`) | Once per finished turn (on `Stop` hook). |
| pong | `{"type":"pong","ts":<unix_ms>}` | In response to each `ping`. |

**ping/pong liveness contract.** The `pong` is produced by the daemon's main
event loop — the same loop that drains the PTY, pumps the transcript, and
dispatches prompts. A `pong` therefore proves the loop is not wedged. It does
**not** prove the child `claude` is healthy (a wedged `claude` with a live
daemon loop still answers pings); detecting a stuck *child* is the caller's job
(e.g. observing the child's API-socket / transcript activity). The daemon
answers pings in every state (`waiting_for_ready`, `idle`, `busy`) and during a
long busy turn — a healthy long turn never blocks the loop. Absence of `pong`
within the caller's timeout means the daemon loop itself is stuck.

## 3. Output format fidelity

| `--output-format` | Stdout                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `text` (default)  | Last assistant message text + `\n`.                                                                                           |
| `json`            | Single result object: `{type:"result", subtype, session_id, result, is_error, duration_ms, duration_api_ms, num_turns, total_cost_usd, usage, permission_denials}` |
| `stream-json`     | Live JSONL: transcript lines are emitted to stdout as `claude` flushes them (driver tails the transcript file). Terminated by the `result` object. |

`session_id` is read from the transcript JSONL (`sessionId` in real Claude
transcripts; `session_id` accepted too).
`duration_ms` is wall time from `run()` entry to Stop hook fired.
`duration_api_ms`, `num_turns`, `total_cost_usd`, `usage` are aggregated
from the transcript JSONL message entries (`message.usage`).

Exit codes:

| Code | Meaning |
| ---- | ------- |
| `0`  | `is_error: false`. |
| `1`  | `is_error: true` or transcript missing final result. |
| `2`  | Wrapper internal error (PTY failure, zmux init failure, etc.). |
| `124`| `--max-turns` exceeded or timeout. |
| `130`| Interrupted (SIGINT). |

## 4. CLI surface

Drop-in subset of `claude -p`:

```
claude-p [OPTIONS] [PROMPT]

  PROMPT                       Prompt text. If absent, read from stdin.
  --output-format <fmt>        text | json | stream-json   (default: text)
  --model <name>               opus | sonnet | <full-model-id>
  --max-turns <N>              Abort after N assistant turns.
  --allowedTools <list>        Permission rules.
  --dangerously-skip-permissions
  --resume <id> | --continue   Reuse a prior session.
  --session-id <uuid>          Force a specific session id.
  --cwd <path>                 Working directory for the child.
  --input-file <path>          Read prompt from file (multiline).
  --verbose                    Forwarded to `claude`.
  --timeout <seconds>          Wrapper wall-time cap (default 300s).
  --debug                      Wrapper-level debug logs to stderr.
  -h, --help                   Print help.
  -v, --version                Print version.
```

Flags not listed above are forwarded verbatim to the child `claude` so the
wrapper stays useful as Claude Code evolves.

## 5. Public Zig library API (`root.zig`)

```zig
pub const OutputFormat = enum { text, json, stream_json };

pub const Options = struct {
    prompt: []const u8,
    output_format: OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    verbose: bool = false,
    timeout_ms: u64 = 300_000,
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
};

pub const Result = struct {
    summary: transcript.Summary,
    duration_ms: u64,
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void;
    pub fn write(self: *const Result, allocator: std.mem.Allocator,
                 writer: *std.Io.Writer, fmt: OutputFormat) !void;
    pub fn exitCode(self: *const Result) u8;
};

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result;
```

## 6. Test plan (TDD order)

1. **`args.zig`** — table-driven test of every flag and its parse outcome.
2. **`transcript.zig`** — fixtures: a known session JSONL → asserted final
   message + usage totals + per-message extraction.
3. **`hook.zig`** — generated `--settings` JSON matches schema; hook script
   body executable; FIFO created; payload field extractors round-trip.
4. **`terminal.zig`** — feed recorded VT byte sequences; verify the DEC
   responder emits the right reply bytes for DA1/DA2/DSR/XTVERSION/18t.
5. **`emit.zig`** — golden tests: text, json, stream-json formats produce
   the expected stdout shapes from synthetic Summaries.
6. **`driver.zig`** — argv assembly + shell-quoting (unit-level, no PTY).
7. **`daemon.zig`** — stdin frame classification: `parseUserMessageContent`
   round-trips user frames (string / block-array / top-level content); a
   `{"type":"ping"}` frame is recognized as a ping (not a user message); a
   user frame is not misread as a ping.
8. **End-to-end against real `claude`** (gated on `CLAUDE_P_E2E=1`):
   `zig build test-integration` runs `tests/integration.zig`. These tests
   exercise the full path with no mocks.

## 7. Build & dependencies

- `build.zig.zon`: dependency `zmux` via
  `git+https://github.com/smithersai/zmux`.
- `build.zig`: imports `zmux` into `claude_p` module + exe; links libc and
  per-OS `util` (Linux) / `proc` (macOS) for zmux's PTY needs.
- Targets: native by default. CI matrix:
  `aarch64-macos`, `x86_64-macos`, `x86_64-linux-gnu`, `aarch64-linux-gnu`.

## 8. Non-goals (v1)

- Windows support (no `forkpty`; zmux doesn't support Windows either).
- Per-token streaming within a single assistant message — that requires
  `claude --print --include-partial-messages`, which isn't reachable
  through the interactive PTY path. `--output-format stream-json` does
  stream per-message: as soon as `claude` flushes a transcript line, the
  driver tails it via `src/stream.zig` and writes it to stdout.
- Tool-approval prompting — use `--dangerously-skip-permissions` or
  `--allowedTools`.

## 9. Risks / open issues

| Risk | Mitigation |
| ---- | ---------- |
| zmux API churn | Pinned by SHA in `build.zig.zon`. |
| Hook payload schema change between Claude releases | Parse defensively; fall back to `last_assistant_message` from Stop payload. |
| Ink adds a new terminal probe | Add a new case to `terminal.respondToDecQueries`. |
| Inline `--settings` not supported on user's Claude version | Currently no fallback; flag the failure in stderr. |
| Child outlives parent on crash | `session.terminate()` is invoked from `defer`; zmux escalates SIGTERM → SIGKILL. |
