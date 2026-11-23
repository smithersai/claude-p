# claude-p

> **Use at your own risk.** This package and repository exist for
> **educational purposes** and demonstrates why client-side restrictions
> on how a product is used are fundamentally unenforceable.

A drop-in replacement for `claude -p` that drives the interactive
`claude` UI inside an in-process [zmux][zmux] PTY session.

Built using [smithers][smithers] self-improving harness.

[zmux]: https://github.com/smithersai/zmux
[smithers]: https://github.com/smithersai/smithers

---

## Quick start

Requires `claude` on `$PATH`, Node `>= 18` (for `npx`), and macOS or Linux (`arm64` or `x64`).

```bash
# Plain text (default)
npx claude-p "Reply with the single word OK."

# Pipe stdin and return a structured JSON result
git diff HEAD~1 | npx claude-p --output-format json "Summarize this diff."

# Stream transcript JSONL live as messages flush (--verbose required)
npx claude-p --output-format stream-json --verbose "Audit src/" | jq .

# Long-lived multi-turn daemon over stdin/stdout NDJSON
printf '%s\n' \
  '{"type":"user","message":{"role":"user","content":"Summarize this repo."}}' \
  | npx claude-p daemon
```

On install, `scripts/install.js` fetches the prebuilt binary from GitHub Releases and verifies its SHA-256 digest against `SHA256SUMS`. Set `CLAUDE_P_REQUIRE_CHECKSUM=1` to fail hard if a release lacks `SHA256SUMS`, or `CLAUDE_P_SKIP_DOWNLOAD=1` to skip downloading.

---

## Architecture

`claude-p` never modifies `~/.claude/`. For each run it spawns `claude` on a real PTY, answers the terminal queries Ink issues at boot, passes inline `--settings` hooks wired to a per-run FIFO, and reads the session transcript JSONL.

```mermaid
flowchart LR
    CLI["CLI / Zig caller"] --> Driver["driver / daemon loop"]
    Driver -->|"typePrompt (paced bracketed paste)"| PTY["zmux NativeSession PTY"]
    PTY <-->|"forkpty"| Claude["claude (Ink TUI)"]
    PTY -->|"pane_output (reader thread)"| DEC["terminal.zig<br/>DA1 · DA2 · DSR · XTVERSION · 18t"]
    DEC -.->|"mutex queue → main loop"| PTY
    Claude -->|"inline --settings hooks"| FIFO["$TMPDIR/.../events.fifo<br/>SessionStart · UserPromptSubmit · Stop"]
    FIFO --> Driver
    Claude -->|"appends JSONL"| Transcript["session transcript (.jsonl)"]
    Transcript -->|"pread tailer / offset parser"| Emit["emit.zig → stdout<br/>text · json · stream-json"]
```

1. **Real PTY.** `zmux.NativeSession` forks `claude` onto a real PTY (`openpty`/`forkpty`) with a background reader thread. Ink refuses to start on plain pipes.
2. **Terminal handshake.** `src/terminal.zig` scans PTY output and replies to five DEC/XTerm queries (`DA1`, `DA2`, `DSR`, `XTVERSION`, `18t`). Without replies, Ink hangs at startup.
3. **Startup dialogs.** Before `SessionStart`, the driver handles Claude Code 2.1 workspace-trust, bypass-permissions, and development-channels modals—verifying the `❯` cursor landed on the affirmative option before pressing Enter.
4. **Paced bracketed paste.** After `SessionStart`, one-shot mode pastes the prompt inside `\x1b[200~`…`\x1b[201~` in UTF-8-safe chunks of at most 512 bytes spaced 8 ms apart (staying under macOS's 1024-byte `TTYHOG`), pauses 120 ms for Ink's Enter debounce, and sends `\r`.
5. **Delivery check & completion.** One-shot mode verifies acceptance via `UserPromptSubmit` (including a truncation check for prompts over 64 non-whitespace bytes) or transcript growth. If neither arrives within 4 s, it sends `Ctrl-U` and retries up to 4 injections total. When `Stop` fires, the wrapper parses the transcript (retrying while Claude flushes, falling back to `last_assistant_message`), prints the result, and terminates the child.

---

## Daemon mode

`claude-p daemon [OPTIONS]` keeps one interactive `claude` session alive across multiple turns. It speaks newline-delimited JSON (NDJSON) on stdin and stdout, compatible with `claude -p --input-format stream-json --output-format stream-json --verbose`.

### Stdin frames

| Frame | Effect |
| --- | --- |
| `{"type":"user","message":{"role":"user","content":"…"}}` | Queues a prompt and submits it when idle. Also accepts an array of `{"type":"text","text":"…"}` blocks or top-level `{"type":"user","content":"…"}`. |
| `{"type":"ping"}` | Answered immediately by the main event loop in any state with `{"type":"pong","ts":<unix_ms>}`. |

Closing stdin (EOF) drains the active turn and any queued prompts, terminates `claude`, and exits `0`.

### Stdout frames

| Frame | Emitted when |
| --- | --- |
| `{"type":"system","subtype":"init","session_id":"…"}` | Once, when `SessionStart` fires. |
| Raw transcript JSONL lines | Live, as `claude` flushes them (`--resume`/`--continue` skips to existing EOF first). |
| `{"type":"result", ...}` | On each `Stop`, scoped to the transcript byte range of that turn. |
| `{"type":"pong","ts":<unix_ms>}` | Immediately on each `ping`. |

### Watchdogs and PTY telemetry

- `--timeout <sec>` (default `300`): deadline for initial `SessionStart`.
- `--idle-timeout <sec>` (default `180`, `0` disables): kills the session if busy with no PTY output for that long. Resets on idle → busy and never fires while idle.
- `CLAUDE_P_PTY_TRACE`: controls periodic `[pty-trace]` stderr diagnostics (default `60` seconds; set `0`, `off`, `false`, or `no` to disable, or a positive integer for interval seconds).

---

## CLI reference

```text
claude-p [OPTIONS] [PROMPT]
claude-p daemon [OPTIONS]
```

If `PROMPT` is omitted in one-shot mode, `claude-p` reads from `--input-file` or stdin (up to 16 MiB).

| Flag | Default | Description |
| --- | --- | --- |
| `--output-format <fmt>` | `text` | `text`, `json`, or `stream-json`. `stream-json` requires `--verbose` in one-shot mode. |
| `--model <name>` | — | Forwarded to `claude --model`. |
| `--fallback-model <name>` | — | Forwarded to `claude --fallback-model`. |
| `--max-turns <N>` | — | Forwarded to `claude --max-turns`. |
| `--allowedTools`, `--allowed-tools <list>` | — | Permission allow list. |
| `--disallowedTools`, `--disallowed-tools <list>` | — | Permission deny list. |
| `--permission-mode <mode>` | — | `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`, etc. |
| `--dangerously-skip-permissions` | `false` | Bypass permission prompts. |
| `--system-prompt <text>` | — | Override the default system prompt. |
| `--append-system-prompt <text>` | — | Append to the default system prompt. |
| `--add-dir <dir>...` | — | Additional directories (repeatable, variadic). |
| `--mcp-config <cfg>...` | — | MCP config paths or JSON (repeatable, variadic). |
| `--setting-sources <list>` | — | Comma-separated setting sources (`user,project,local`). |
| `--resume <id>` | — | Resume a prior session by ID. |
| `--continue`, `-c` | `false` | Continue the most recent session. |
| `--session-id <uuid>` | — | Force a specific session UUID. |
| `--cwd <path>` | current dir | Working directory for `claude`. |
| `--input-file <path>` | — | Read prompt from file (one-shot mode). |
| `--verbose` | `false` | Forwarded to `claude`; required with `--output-format stream-json`. |
| `--timeout <sec>` | `300` | One-shot wall-time cap, or daemon `SessionStart` deadline. |
| `--idle-timeout <sec>` | `180` | Daemon busy-turn PTY silence watchdog (`0` disables). |
| `--debug` | `false` | Emit timestamped driver diagnostics to stderr. |
| `--` | — | End of options; remaining token goes to `PROMPT`. |
| `-h`, `--help` | — | Print help and exit `0`. |
| `-v`, `--version` | — | Print version (`0.1.3`) and exit `0`. |

**Forwarded and rejected flags:** Unrecognized flags are forwarded verbatim to `claude` (known boolean flags such as `--bare`, `--fork-session`, and `--strict-mcp-config` do not consume the following argument). `-p` / `--print` and `--settings` are rejected with exit code `2` because `claude-p` emulates print mode and injects its own inline `--settings` for hooks.

---

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (`is_error: false`), or daemon shut down cleanly. |
| `1` | Assistant returned an error (`is_error: true`). |
| `2` | Invalid arguments, empty prompt, missing binary, or wrapper/driver/daemon error (timeouts, `PromptNotAccepted`, `PromptTruncated`, `TranscriptUnavailable`, `SpawnFailed`, `InvalidExtraSettings`). |
| `128 + sig` | Terminated by signal via the npm shim (e.g., `130` for `SIGINT`). |

---

## As a Zig library

Requires Zig **0.15.2** (matching `zmux`'s `comptime` version pin).

```bash
zig fetch --save=claude_p git+https://github.com/smithersai/claude-p
```

```zig
const std = @import("std");
const claude_p = @import("claude_p");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var result = try claude_p.run(alloc, .{
        .prompt = "What is the capital of France?",
        .output_format = .text,
        .skip_permissions = true,
    });
    defer result.deinit(alloc);

    std.debug.print("{s}\n", .{result.summary.final_text});
}
```

The Zig API (`claude_p.Options`) also supports library-only hook/settings composition via `extra_hooks` (`[]const hook.ExtraHook`) and `extra_settings_json` (`?[]const u8`), live streaming via `stream_writer`, and multi-turn driving via `claude_p.daemon.run`.

---

## Build and test from source

```bash
git clone https://github.com/smithersai/claude-p
cd claude-p
zig build -Doptimize=ReleaseSafe   # requires Zig 0.15.2
zig build test                     # 113 unit tests (no external claude needed)
CLAUDE_P_E2E=1 zig build test-integration  # 4 real-claude end-to-end tests
```

---

## Caveats

- **macOS and Linux only.** No Windows support (`forkpty` is POSIX-only).
- **Requires `claude` on `$PATH`.** `claude-p` drives the real installed binary.
- **Per-message streaming, not per-token.** `--output-format stream-json --verbose` tails the session JSONL as `claude` flushes complete lines; token-by-token deltas require native `claude -p --include-partial-messages`.
- **Startup overhead.** Expect ~50–200 ms over native `claude -p` for PTY allocation and Ink boot.
- **Upstream coupling.** `claude` is not designed to be driven through its TUI. New startup dialogs, terminal probes, or hook schema changes in future Claude Code releases can break the wrapper; failures surface explicitly rather than silently.

---

## Documentation

- **Full documentation site (Starlight):** [`docs/`](./docs) — run `cd docs && npm install && npm run dev` to browse locally.
- **Technical specification:** [`SPEC.md`](./SPEC.md) — module contracts, wire formats, state machines, and test matrix.
- **Agent guide:** [`CLAUDE.md`](./CLAUDE.md) — invariants and gotchas for contributors and coding agents.

## License

MIT. See [`LICENSE`](./LICENSE).
