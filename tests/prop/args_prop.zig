//! Property-based and fuzz tests for `src/args.zig` (`args.parse`,
//! `OutputFormat.fromString`).
//!
//! Every property runs under `std.testing.allocator` (or a
//! `FailingAllocator` wrapped around it), so a leak on any `.ok` or
//! `ParseError` path fails the test.
//!
//! Semantics the properties rely on (all mirror commander.js, which `claude`
//! uses):
//!   * A value-taking flag consumes the next token unconditionally, even when
//!     that token starts with `-` (`--model -p` sets `model == "-p"`).
//!   * Every value-taking flag also accepts `--flag=value`, with identical
//!     results; `-r` is a short alias for `--resume`.
//!   * A variadic flag needs a first value that does not start with `-`
//!     (else `MissingValue`), then takes every following token that does not
//!     start with `-`. `--add-dir=<v>` takes exactly one value.
//!   * `--allowedTools` / `--allowed-tools` / `--disallowedTools` /
//!     `--disallowed-tools` follow the same variadic rule, and each rule is
//!     forwarded as a canonical `<flag> <rule>` pair in `passthrough`.
//!   * `-n` / `--name` consume the next token unconditionally and forward
//!     both to `passthrough`.
//!   * An unknown `--long` flag is forwarded and greedily takes one following
//!     non-dash token, unless it is in `known_boolean_long_flags` or already
//!     carries `=value`.
//!   * Daemon mode rejects a positional prompt and `--input-file`
//!     (`UnknownFlag`), then an explicit `--output-format` whose final value
//!     is not `stream-json` (`UnsupportedFlag`).
//!   * `--dangerously-skip-permissions` is in the boolean table but has a
//!     dedicated `Options` field; it is forwarded through that field, not
//!     through `passthrough`.
const std = @import("std");
const claude_p = @import("claude_p");
const args = claude_p.args;
const testing = std.testing;

const ParseError = args.ParseError;
const Tokens = []const []const u8;

// ---------------------------------------------------------------- vocabulary

/// Flags `parse` must reject at a flag position, bare or with `=value`.
const rejected_flags = [_][]const u8{
    "-p",                       "--print",                    "--settings",              "--bare",                 "--safe-mode",
    "--no-session-persistence", "--input-format",             "--json-schema",           "--max-budget-usd",       "--max-turns",
    "--fallback-model",         "--include-partial-messages", "--forward-subagent-text", "--replay-user-messages", "--verbose-thinking",
};

/// Tokens `parse` handles itself; none may ever reach `passthrough`.
const handled_exact = [_][]const u8{
    "--",                "-h",                             "--help",
    "-v",                "--version",                      "-c",
    "--continue",        "--output-format",                "--model",
    "--allowed-tools",   "--disallowed-tools",             "--resume",
    "--session-id",      "--cwd",                          "--input-file",
    "--verbose",         "--debug",                        "--timeout",
    "--idle-timeout",    "--transcript-idle-timeout",      "--extra-hook",
    "--setting-json",    "--system-prompt",                "--append-system-prompt",
    "--permission-mode", "--setting-sources",              "--add-dir",
    "--mcp-config",      "--dangerously-skip-permissions", "-r",
};

/// Every flag that takes exactly one value, in both `f v` and `f=v` forms.
const value_flags = [_][]const u8{
    "--output-format",        "--model",
    "--permission-mode",      "--system-prompt",
    "--append-system-prompt", "--setting-sources",
    "--resume",               "-r",
    "--session-id",           "--cwd",
    "--input-file",           "--timeout",
    "--idle-timeout",         "--transcript-idle-timeout",
    "--extra-hook",           "--setting-json",
};

const variadic_flags = [_][]const u8{ "--add-dir", "--mcp-config" };

/// Variadic, repeatable; each rule lands in `passthrough` as a pair led by
/// the canonical spelling.
const tool_flags = [_][]const u8{ "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools" };

fn toolCanonical(flag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, flag, "--allowed")) args.allowed_tools_flag else args.disallowed_tools_flag;
}

fn isToolCanonical(t: []const u8) bool {
    return std.mem.eql(u8, t, args.allowed_tools_flag) or std.mem.eql(u8, t, args.disallowed_tools_flag);
}

/// Forwarded with exactly one following token, whatever it is.
const name_flags = args.forwarded_value_flags;

fn isNameFlag(t: []const u8) bool {
    for (name_flags) |f| if (std.mem.eql(u8, t, f)) return true;
    return false;
}

const handled_eq_prefixes = blk: {
    const all = value_flags ++ variadic_flags ++ tool_flags;
    var out: [all.len][]const u8 = undefined;
    for (all, 0..) |f, i| out[i] = f ++ "=";
    break :blk out;
};

/// Flags that consume exactly one following token, whatever it is.
const single_value_flags = [_][]const u8{
    "-r",
    "--model",
    "--resume",
    "--session-id",
    "--cwd",
    "--input-file",
    "--setting-json",
    "--system-prompt",
    "--append-system-prompt",
    "--permission-mode",
    "--setting-sources",
};

const integer_flag_prefixes = [_][]const u8{
    "--timeout", "--idle-timeout", "--transcript-idle-timeout",
};

const base_vocab = [_][]const u8{
    "daemon",                "--",                          "-",                           "",
    "-h",                    "--help",                      "-v",                          "--version",
    "-c",                    "--continue",                  "--verbose",                   "--debug",
    "text",                  "json",                        "stream-json",                 "yaml",
    "--output-format=text",  "--output-format=json",        "--output-format=stream-json", "--output-format=",
    "--model=",              "--model=opus",                "7",                           "0",
    "4294967295",            "4294967296",                  "-1",                          "+3",
    "seven",                 "--transcript-idle-timeout=9", "--transcript-idle-timeout=",  "--transcript-idle-timeout=x",
    "-p",                    "--print",                     "--settings",                  "--bare",
    "--safe-mode",           "-p=1",                        "--print=true",                "--settings={}",
    "--bare=true",           "--safe-mode=1",               "--bareword",                  "--printer",
    "--settingsx",           "-pc",                         "-x",                          "-xyz",
    "Stop=echo hi",          "PreToolUse=env A=1 true",     "=x",                          "x=",
    "=",                     "==",                          "nope",                        "a=b=c",
    "--extra-hook=Stop=a=b", "--extra-hook=",               "--extra-hook==",              "--extra-hook=Stop",
    "--setting-json={}",     "--system-prompt=be terse",    "{\"env\":{}}",                "/a",
    "/b c",                  "hello world",                 "--frobnitz",                  "--frobnitz=1",
    "--x",                   "---",                         "\xff\xfe",                    "h\xc3\xa9llo",
    "-r",                    "-r=abc",                      "--resume=abc",                "--add-dir=-x",
    "--mcp-config=--",       "--foo=bar",                   "--input-file=/p",             "--no-session-persistence",
    "--input-format",        "--json-schema={}",            "--max-budget-usd=1",          "--timeout=0",
};

const vocab = base_vocab ++ handled_exact ++ args.known_boolean_long_flags ++
    [_][]const u8{ "--allowedTools", "--disallowedTools", "--allowedTools=Bash", "-n", "--name", "--name=x", "--max-turns", "--fallback-model=x" };

fn isRejectedLike(t: []const u8) bool {
    const flag = std.mem.sliceTo(t, '=');
    if (flag.len > 2 and flag[0] == '-' and flag[1] != '-' and std.mem.indexOfScalar(u8, flag[1..], 'p') != null) return true;
    for (rejected_flags) |name| {
        if (std.mem.eql(u8, t, name)) return true;
        if (t.len > name.len and std.mem.startsWith(u8, t, name) and t[name.len] == '=') return true;
    }
    return false;
}

fn isKnownBoolean(t: []const u8) bool {
    for (args.known_boolean_long_flags) |b| if (std.mem.eql(u8, b, t)) return true;
    return false;
}

fn isDsp(t: []const u8) bool {
    return std.mem.eql(u8, t, "--dangerously-skip-permissions");
}

fn anyStartsWith(argv: Tokens, prefixes: []const []const u8) bool {
    for (argv) |t| for (prefixes) |p| if (std.mem.startsWith(u8, t, p)) return true;
    return false;
}

// ---------------------------------------------------------------- generators

const Argv = struct {
    buf: [160][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Argv, t: []const u8) void {
        self.buf[self.len] = t;
        self.len += 1;
    }
    fn pushAll(self: *Argv, ts: Tokens) void {
        for (ts) |t| self.push(t);
    }
    fn slice(self: *const Argv) Tokens {
        return self.buf[0..self.len];
    }
};

fn join(parts: []const Tokens) Argv {
    var av: Argv = .{};
    for (parts) |p| av.pushAll(p);
    return av;
}

const UnitCfg = struct {
    /// May emit one positional prompt (tracked across calls on the same Gen).
    prompt: bool = false,
    /// May emit `--output-format text|json` (never stream-json).
    format: bool = true,
    /// May emit `--verbose`, `--help`, `--version` and short forms.
    verbose_help: bool = true,
};

const Gen = struct {
    rand: std.Random,
    arena: std.mem.Allocator,
    has_prompt: bool = false,

    fn below(self: *Gen, n: usize) usize {
        return self.rand.uintLessThan(usize, n);
    }

    fn bytes(self: *Gen, max_len: usize) ![]u8 {
        const b = try self.arena.alloc(u8, self.rand.uintAtMost(usize, max_len));
        self.rand.bytes(b);
        return b;
    }

    fn printable(self: *Gen, min_len: usize, max_len: usize) ![]u8 {
        const alphabet = "abcXYZ019 =-_/.:{}\"'\\$\t\n,";
        const b = try self.arena.alloc(u8, self.rand.intRangeAtMost(usize, min_len, max_len));
        for (b) |*c| c.* = alphabet[self.below(alphabet.len)];
        return b;
    }

    /// Any string that does not start with `-` (may be empty, may hold
    /// arbitrary bytes, `=`, or interior dashes).
    fn nonDash(self: *Gen) ![]const u8 {
        const s = if (self.rand.boolean()) try self.bytes(12) else try self.printable(0, 12);
        if (s.len > 0 and s[0] == '-') s[0] = '_';
        return s;
    }

    fn alnum(self: *Gen, min_len: usize, max_len: usize) ![]u8 {
        const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
        const b = try self.arena.alloc(u8, self.rand.intRangeAtMost(usize, min_len, max_len));
        for (b) |*c| c.* = alphabet[self.below(alphabet.len)];
        return b;
    }

    fn concat(self: *Gen, parts: []const []const u8) ![]const u8 {
        return std.mem.concat(self.arena, u8, parts);
    }

    /// Arbitrary token: vocabulary, `flag=value`, printable noise, raw bytes.
    fn token(self: *Gen) ![]const u8 {
        return switch (self.below(20)) {
            0...10 => vocab[self.below(vocab.len)],
            11...13 => try self.concat(&.{ vocab[self.below(vocab.len)], "=", try self.printable(0, 6) }),
            14...16 => try self.printable(0, 10),
            17, 18 => try self.bytes(12),
            else => try self.concat(&.{ "-", try self.printable(0, 6) }),
        };
    }

    /// A rejected flag, bare or with a random `=value`.
    fn rejected(self: *Gen) ![]const u8 {
        const base = rejected_flags[self.below(rejected_flags.len)];
        if (self.rand.boolean()) return base;
        return self.concat(&.{ base, "=", try self.bytes(8) });
    }

    /// An unknown long flag that collides with nothing `parse` knows.
    fn unknownLong(self: *Gen) ![]const u8 {
        return self.concat(&.{ "--x-", try self.alnum(1, 8) });
    }

    fn boolFlag(self: *Gen) []const u8 {
        while (true) {
            const f = args.known_boolean_long_flags[self.below(args.known_boolean_long_flags.len)];
            if (!isRejectedLike(f)) return f;
        }
    }

    fn shortFlag(self: *Gen) ![]const u8 {
        const letters = "abdefgijklmoqstuwxyz"; // no c, h, n, p, r, v
        const s = try self.arena.alloc(u8, 2 + self.below(3));
        s[0] = '-';
        for (s[1..]) |*c| c.* = letters[self.below(letters.len)];
        return s;
    }

    fn hookValue(self: *Gen) ![]const u8 {
        return self.concat(&.{ try self.alnum(1, 10), "=", try self.printable(1, 12) });
    }

    /// Append one self-contained unit that parses without error wherever a
    /// flag is expected, and leaves the parser at a flag position.
    fn unit(self: *Gen, av: *Argv, cfg: UnitCfg) !void {
        switch (self.below(16)) {
            14 => {
                // Tool rules: variadic run, or one `=` rule.
                const flag = tool_flags[self.below(tool_flags.len)];
                if (self.rand.boolean()) {
                    av.push(flag);
                    for (0..1 + self.below(3)) |_| av.push(try self.nonDash());
                } else {
                    av.push(try self.concat(&.{ flag, "=", try self.printable(0, 6) }));
                }
            },
            15 => {
                av.push(name_flags[self.below(name_flags.len)]);
                // Consumes anything, including rejected flags and `--`.
                av.push(if (self.rand.boolean()) try self.token() else try self.nonDash());
            },
            0 => {
                av.push(single_value_flags[self.below(single_value_flags.len)]);
                // Value flags consume anything, including rejected flags.
                av.push(if (self.rand.boolean()) try self.token() else try self.nonDash());
            },
            1 => av.push(if (cfg.verbose_help)
                ([_][]const u8{ "--verbose", "--help", "-h", "--version", "-v" })[self.below(5)]
            else
                "--debug"),
            2, 3 => {
                av.push(if (self.rand.boolean()) "--add-dir" else "--mcp-config");
                for (0..1 + self.below(3)) |_| av.push(try self.nonDash());
            },
            4 => {
                av.push(try self.unknownLong());
                if (self.rand.boolean()) av.push(try self.nonDash());
            },
            5 => av.push(try self.concat(&.{ try self.unknownLong(), "=", try self.printable(0, 6) })),
            6 => av.push(self.boolFlag()),
            7 => av.push(try self.shortFlag()),
            8 => {
                if (self.rand.boolean()) {
                    av.push("--extra-hook");
                    av.push(try self.hookValue());
                } else {
                    av.push(try self.concat(&.{ "--extra-hook=", try self.hookValue() }));
                }
            },
            9 => {
                const n = try std.fmt.allocPrint(self.arena, "{d}", .{self.rand.int(u32)});
                switch (self.below(4)) {
                    0 => av.push(try self.concat(&.{ "--idle-timeout=", n })),
                    1 => av.pushAll(&.{ "--timeout", n }),
                    2 => av.pushAll(&.{ "--idle-timeout", n }),
                    else => av.push(try self.concat(&.{ "--transcript-idle-timeout=", n })),
                }
            },
            10 => if (cfg.format) {
                if (self.rand.boolean()) {
                    av.pushAll(&.{ "--output-format", if (self.rand.boolean()) "json" else "text" });
                } else {
                    av.push(if (self.rand.boolean()) "--output-format=json" else "--output-format=text");
                }
            } else av.push("-c"),
            11 => av.push(([_][]const u8{ "--continue", "-c", "--debug", "--dangerously-skip-permissions" })[self.below(4)]),
            12 => av.push(try self.concat(&.{
                ([_][]const u8{ "--model=", "--setting-json=", "--system-prompt=" })[self.below(3)],
                try self.bytes(8),
            })),
            else => if (cfg.prompt and !self.has_prompt) {
                self.has_prompt = true;
                av.push(try self.nonDash());
            } else av.push("--debug"),
        }
    }

    fn units(self: *Gen, av: *Argv, max: usize, cfg: UnitCfg) !void {
        for (0..self.below(max + 1)) |_| try self.unit(av, cfg);
    }
};

const Harness = struct {
    prng: std.Random.DefaultPrng,
    arena_state: std.heap.ArenaAllocator,

    fn init(seed: u64) Harness {
        return .{
            .prng = std.Random.DefaultPrng.init(seed),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }
    fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }
    /// Fresh generator for one trial; tokens from the previous trial die.
    fn trial(self: *Harness) Gen {
        _ = self.arena_state.reset(.retain_capacity);
        return .{ .rand = self.prng.random(), .arena = self.arena_state.allocator() };
    }
};

fn dumpArgv(label: []const u8, trial: usize, argv: Tokens) void {
    std.debug.print("\n{s}: trial {d} failed, argv ({d} tokens):\n", .{ label, trial, argv.len });
    for (argv, 0..) |t, i| std.debug.print("  [{d}] \"{f}\"\n", .{ i, std.zig.fmtString(t) });
}

// ---------------------------------------------------------------- observation

/// Everything observable about one `parse` call. Slices compare by identity
/// (`std.meta.eql` compares ptr+len), which is the right notion because
/// `Options` borrows from argv.
const Outcome = struct {
    err: ?anyerror = null,
    is_daemon: bool = false,
    prompt: ?[]const u8 = null,
    output_format: args.OutputFormat = .text,
    format_explicit: bool = false,
    verbose: bool = false,
    debug: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    cont: bool = false,
    dsp: bool = false,
    max_turns: ?u32 = null,
    timeout: u32 = 0,
    idle: u32 = 0,
    transcript_idle: u32 = 0,
    n_pass: usize = 0,
    n_dirs: usize = 0,
    n_mcp: usize = 0,
    n_hooks: usize = 0,
    has_input_file: bool = false,
    /// Identity hash over every borrowed string, in order.
    strings: u64 = 0,
};

fn mix(h: *std.hash.Wyhash, s: ?[]const u8) void {
    if (s) |v| {
        h.update(std.mem.asBytes(&@intFromPtr(v.ptr)));
        h.update(std.mem.asBytes(&v.len));
    } else h.update("\x00null");
}

fn outcomeOf(opts: *const args.Options) Outcome {
    var h = std.hash.Wyhash.init(0);
    for ([_]?[]const u8{
        opts.input_file,          opts.model,                opts.allowed_tools,
        opts.resume_session,      opts.session_id,           opts.cwd,
        opts.system_prompt,       opts.append_system_prompt, opts.permission_mode,
        opts.disallowed_tools,    opts.fallback_model,       opts.setting_sources,
        opts.extra_settings_json,
    }) |s| mix(&h, s);
    for (opts.passthrough.items) |s| mix(&h, s);
    h.update("|");
    for (opts.add_dirs.items) |s| mix(&h, s);
    h.update("|");
    for (opts.mcp_configs.items) |s| mix(&h, s);
    h.update("|");
    for (opts.extra_hooks.items) |x| {
        mix(&h, x.event);
        mix(&h, x.command);
    }
    return .{
        .is_daemon = opts.is_daemon,
        .prompt = opts.prompt,
        .output_format = opts.output_format,
        .format_explicit = opts.output_format_explicit,
        .verbose = opts.verbose,
        .debug = opts.debug,
        .show_help = opts.show_help,
        .show_version = opts.show_version,
        .cont = opts.cont,
        .dsp = opts.dangerously_skip_permissions,
        .max_turns = opts.max_turns,
        .timeout = opts.timeout_seconds,
        .idle = opts.idle_timeout_seconds,
        .transcript_idle = opts.transcript_idle_timeout_seconds,
        .n_pass = opts.passthrough.items.len,
        .n_dirs = opts.add_dirs.items.len,
        .n_mcp = opts.mcp_configs.items.len,
        .n_hooks = opts.extra_hooks.items.len,
        .has_input_file = opts.input_file != null,
        .strings = h.final(),
    };
}

fn borrowedFrom(argv: Tokens, s: []const u8) bool {
    const lo = @intFromPtr(s.ptr);
    for (argv) |t| {
        const tlo = @intFromPtr(t.ptr);
        if (lo >= tlo and lo + s.len <= tlo + t.len) return true;
    }
    return false;
}

fn sameSlice(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

/// `items` must be whole argv tokens, in argv order.
fn expectTokenSubsequence(argv: Tokens, items: []const []const u8) !void {
    var j: usize = 0;
    for (items) |it| {
        while (j < argv.len and !sameSlice(argv[j], it)) j += 1;
        try testing.expect(j < argv.len);
        j += 1;
    }
}

fn hasToken(argv: Tokens, t: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, t)) return true;
    return false;
}

/// Structural invariants of every successful parse.
fn checkOk(argv: Tokens, opts: *const args.Options) !void {
    const daemon = argv.len > 0 and std.mem.eql(u8, argv[0], "daemon");
    try testing.expectEqual(daemon, opts.is_daemon);
    if (daemon) {
        try testing.expect(opts.prompt == null);
        try testing.expect(opts.input_file == null);
    }

    // Cross-flag rule can never be violated by an `.ok` result.
    if (!opts.show_help and !opts.show_version and !opts.is_daemon) {
        try testing.expect(!(opts.output_format == .stream_json and !opts.verbose));
    }

    // Every string borrows from argv; nothing is copied or invented.
    for ([_]?[]const u8{
        opts.prompt,          opts.input_file,          opts.model,
        opts.allowed_tools,   opts.resume_session,      opts.session_id,
        opts.cwd,             opts.system_prompt,       opts.append_system_prompt,
        opts.permission_mode, opts.disallowed_tools,    opts.fallback_model,
        opts.setting_sources, opts.extra_settings_json,
    }) |maybe| if (maybe) |s| try testing.expect(borrowedFrom(argv, s));

    // The CLI never fills the scalar library fields for rejected or
    // pair-forwarded flags.
    try testing.expect(opts.allowed_tools == null and opts.disallowed_tools == null);
    try testing.expect(opts.max_turns == null and opts.fallback_model == null);
    if (daemon and opts.output_format_explicit) try testing.expect(opts.output_format == .stream_json);

    // Variadic values are whole tokens, or the tail of a `--flag=` token.
    for (opts.add_dirs.items) |d| try testing.expect(borrowedFrom(argv, d));
    for (opts.mcp_configs.items) |m| try testing.expect(borrowedFrom(argv, m));

    // Passthrough, walked head-first. A canonical tool flag leads a
    // `<flag> <rule>` pair; `-n`/`--name` leads a `<flag> <value>` pair whose
    // value may be any token. Everything else is a forwarded argv token:
    // never a rejected or wrapper-handled flag, and a non-dash item is
    // always the greedy value of a non-boolean unknown long flag.
    var forwarded: Argv = .{};
    var n_rules: usize = 0;
    {
        const items = opts.passthrough.items;
        var j: usize = 0;
        while (j < items.len) {
            const it = items[j];
            if (isToolCanonical(it)) {
                try testing.expect(j + 1 < items.len);
                try testing.expect(borrowedFrom(argv, items[j + 1]));
                n_rules += 1;
                j += 2;
                continue;
            }
            if (isNameFlag(it)) {
                try testing.expect(j + 1 < items.len);
                forwarded.push(it);
                forwarded.push(items[j + 1]);
                j += 2;
                continue;
            }
            try testing.expect(!isRejectedLike(it));
            for (handled_exact) |h| try testing.expect(!std.mem.eql(u8, it, h));
            for (handled_eq_prefixes) |h| try testing.expect(!std.mem.startsWith(u8, it, h));
            if (std.mem.startsWith(u8, it, "-")) {
                try testing.expect(it.len > 1);
            } else {
                try testing.expect(j > 0);
                const prev = items[j - 1];
                try testing.expect(std.mem.startsWith(u8, prev, "--"));
                try testing.expect(!isKnownBoolean(prev));
                try testing.expect(std.mem.indexOfScalar(u8, prev, '=') == null);
            }
            forwarded.push(it);
            j += 1;
        }
    }
    try expectTokenSubsequence(argv, forwarded.slice());

    const consumed = forwarded.len + n_rules + opts.add_dirs.items.len +
        opts.mcp_configs.items.len + opts.extra_hooks.items.len +
        @intFromBool(opts.prompt != null);
    try testing.expect(consumed <= argv.len);

    // Prompt: a whole token; dash-led only when `--` made it positional.
    if (opts.prompt) |p| {
        try expectTokenSubsequence(argv, &.{p});
        if (p.len > 1 and p[0] == '-') try testing.expect(hasToken(argv, "--"));
    }

    // Extra hooks: split on the FIRST `=`, both sides non-empty.
    for (opts.extra_hooks.items) |x| {
        try testing.expect(x.event.len > 0 and x.command.len > 0);
        try testing.expect(std.mem.indexOfScalar(u8, x.event, '=') == null);
        try testing.expect(borrowedFrom(argv, x.event) and borrowedFrom(argv, x.command));
        try testing.expectEqual(@intFromPtr(x.event.ptr) + x.event.len + 1, @intFromPtr(x.command.ptr));
        try testing.expectEqual(@as(u8, '='), (x.event.ptr + x.event.len)[0]);
    }
}

/// Each error implies a visible cause in argv.
fn checkErr(argv: Tokens, err: ParseError) !void {
    switch (err) {
        ParseError.OutOfMemory, ParseError.BadFloat => return error.TestUnexpectedResult,
        ParseError.UnsupportedFlag => {
            var found = false;
            for (argv) |t| found = found or isRejectedLike(t);
            // Daemon mode also refuses `--output-format text|json`.
            if (argv.len > 0 and std.mem.eql(u8, argv[0], "daemon"))
                found = found or anyStartsWith(argv, &.{"--output-format"});
            try testing.expect(found);
        },
        ParseError.MissingValue => {
            var found = false;
            for (argv) |t| {
                for (value_flags ++ variadic_flags ++ tool_flags ++ name_flags) |f| found = found or std.mem.eql(u8, t, f);
            }
            try testing.expect(found);
        },
        ParseError.BadOutputFormat => try testing.expect(anyStartsWith(argv, &.{"--output-format"})),
        ParseError.BadExtraHook => try testing.expect(anyStartsWith(argv, &.{"--extra-hook"})),
        ParseError.BadInteger => try testing.expect(anyStartsWith(argv, &integer_flag_prefixes)),
        ParseError.UnknownFlag => try testing.expect(argv.len >= 2),
        ParseError.StreamJsonRequiresVerbose => {
            try testing.expect(!(argv.len > 0 and std.mem.eql(u8, argv[0], "daemon")));
            try testing.expect(hasToken(argv, "stream-json") or hasToken(argv, "--output-format=stream-json"));
        },
    }
}

/// Parse under a leak-checking allocator, validate, and return the outcome.
/// `fail_index == null` means allocations never fail.
fn observe(argv: Tokens, fail_index: ?usize) !Outcome {
    var fa = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = fail_index orelse std.math.maxInt(usize),
    });
    var out: Outcome = .{};
    if (args.parse(fa.allocator(), argv)) |parsed| {
        var opts = parsed;
        defer opts.deinit(fa.allocator());
        try checkOk(argv, &opts);
        out = outcomeOf(&opts);
    } else |err| {
        if (err == ParseError.OutOfMemory) {
            try testing.expect(fa.has_induced_failure);
        } else {
            try checkErr(argv, err);
        }
        out.err = err;
    }
    // Zero leaks on the `.ok` path AND on every error path.
    try testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    try testing.expectEqual(fa.allocations, fa.deallocations);
    return out;
}

/// Diagnostics agree with parse and omit surplus positional text.
fn checkDiag(argv: Tokens, base: Outcome) !void {
    var diag: args.ParseDiag = .{ .offending = "stale" };
    if (args.parseWithDiag(testing.allocator, argv, &diag)) |parsed| {
        var opts = parsed;
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(?anyerror, null), base.err);
        try testing.expectEqual(@as(?[]const u8, null), diag.offending);
    } else |err| {
        try testing.expectEqual(base.err, @as(?anyerror, err));
        const tok = diag.offending orelse {
            try testing.expectEqual(ParseError.UnknownFlag, err);
            return;
        };
        if (err == ParseError.UnknownFlag) try testing.expectEqualStrings("--input-file", tok);
        if (err == ParseError.UnsupportedFlag) try testing.expect(std.mem.indexOfScalar(u8, tok, '=') == null);
        const static_names = [_][]const u8{ "--input-file", "--output-format", "stream-json" };
        var known = borrowedFrom(argv, tok);
        for (static_names) |n| known = known or std.mem.eql(u8, tok, n);
        try testing.expect(known);
        switch (err) {
            ParseError.UnsupportedFlag => try testing.expect(isRejectedLike(tok) or std.mem.eql(u8, tok, "--output-format")),
            ParseError.MissingValue => {
                var is_flag = false;
                for (value_flags ++ variadic_flags ++ tool_flags ++ name_flags) |f| is_flag = is_flag or std.mem.eql(u8, tok, f);
                try testing.expect(is_flag);
            },
            ParseError.BadInteger => try testing.expect(std.fmt.parseInt(u32, tok, 10) == error.Overflow or
                std.fmt.parseInt(u32, tok, 10) == error.InvalidCharacter),
            ParseError.BadOutputFormat => try testing.expect(args.OutputFormat.fromString(tok) == null),
            else => {},
        }
    }
}

/// Invariants that hold for ANY argv: no panic, no leak, determinism,
/// OOM-safety, and the daemon-prefix metamorphic relation.
fn checkUniversal(argv: Tokens, salt: usize) !void {
    const base = try observe(argv, null);
    try testing.expect(std.meta.eql(base, try observe(argv, null)));
    try checkDiag(argv, base);

    // One injected allocation failure: either OOM, or the same answer.
    const oom = try observe(argv, salt % 6);
    if (oom.err == null or oom.err.? != ParseError.OutOfMemory) {
        try testing.expect(std.meta.eql(base, oom));
    }

    // Prefixing `daemon` changes only `is_daemon`, lifts the
    // stream-json/--verbose rule, and refuses a prompt, `--input-file`, or
    // an explicit non-stream-json `--output-format`.
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "daemon")) {
        const d_argv = try testing.allocator.alloc([]const u8, argv.len + 1);
        defer testing.allocator.free(d_argv);
        d_argv[0] = "daemon";
        @memcpy(d_argv[1..], argv);
        const d = try observe(d_argv, null);
        if (base.err) |e| {
            if (e == ParseError.StreamJsonRequiresVerbose) {
                // A leading `--verbose` lifts the rule without changing
                // anything else, exposing whether a prompt was given.
                const v_argv = try testing.allocator.alloc([]const u8, argv.len + 1);
                defer testing.allocator.free(v_argv);
                v_argv[0] = "--verbose";
                @memcpy(v_argv[1..], argv);
                const v = try observe(v_argv, null);
                try testing.expectEqual(@as(?anyerror, null), v.err);
                if (v.prompt != null or v.has_input_file) {
                    try testing.expectEqual(@as(?anyerror, ParseError.UnknownFlag), d.err);
                } else {
                    try testing.expectEqual(@as(?anyerror, null), d.err);
                    try testing.expect(d.is_daemon);
                    try testing.expectEqual(args.OutputFormat.stream_json, d.output_format);
                    try testing.expect(!d.verbose);
                }
            } else {
                try testing.expectEqual(@as(?anyerror, e), d.err);
            }
        } else if (base.prompt != null or base.has_input_file) {
            try testing.expectEqual(@as(?anyerror, ParseError.UnknownFlag), d.err);
        } else if (base.format_explicit and base.output_format != .stream_json) {
            try testing.expectEqual(@as(?anyerror, ParseError.UnsupportedFlag), d.err);
        } else {
            var expected = base;
            expected.is_daemon = true;
            try testing.expect(std.meta.eql(expected, d));
        }
    }
}

fn parseOk(argv: Tokens) !args.Options {
    return args.parse(testing.allocator, argv);
}

fn expectParseError(expected: ParseError, argv: Tokens) !void {
    if (args.parse(testing.allocator, argv)) |parsed| {
        var opts = parsed;
        opts.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |err| try testing.expectEqual(@as(anyerror, expected), @as(anyerror, err));
}

// ---------------------------------------------------------------- 1. fuzz + PRNG

fn splitNul(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .{};
    errdefer list.deinit(allocator);
    if (input.len > 0) {
        var it = std.mem.splitScalar(u8, input, 0);
        while (it.next()) |tok| try list.append(allocator, tok);
    }
    return list.toOwnedSlice(allocator);
}

fn fuzzParseOne(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    const argv = try splitNul(testing.allocator, input);
    defer testing.allocator.free(argv);
    try checkUniversal(argv, input.len);
}

const parse_corpus = [_][]const u8{
    "hello world",
    "daemon",
    "daemon\x00daemon",
    "--",
    "--\x00--",
    "--\x00-p",
    "--\x00--bare\x00extra",
    "-",
    "\x00",
    "\x00\x00\x00",
    "-p\x00hi",
    "--print=1",
    "-p=1",
    "--settings={}",
    "--settings\x00{}",
    "daemon\x00--safe-mode=1",
    "--bare",
    "--bareword\x00x\x00hi",
    "--model\x00-p\x00hi",
    "--model",
    "--model=",
    "--output-format\x00stream-json\x00hi",
    "--output-format=stream-json\x00--verbose",
    "daemon\x00--output-format\x00stream-json",
    "--output-format=stream-json\x00--help",
    "--output-format\x00yaml",
    "--output-format=",
    "--output-format\x00stream-json\x00--output-format\x00json",
    "--max-turns\x004294967296",
    "--timeout\x004294967296",
    "--timeout\x00-1",
    "--disallowedTools\x00Bash\x00--disallowedTools\x00Edit",
    "--disallowedTools\x00Bash\x00Edit\x00--\x00do thing",
    "--allowed-tools=Bash(git *)\x00hi",
    "--allowedTools\x00--\x00hi",
    "daemon\x00--allowedTools\x00Read\x00Grep",
    "-n\x00sample-session\x00--\x00hello",
    "-n\x00sample-session\x00hello",
    "-n\x00-p",
    "--name",
    "daemon\x00--output-format\x00json",
    "daemon\x00--output-format=text\x00--output-format=stream-json",
    "--fallback-model\x00sonnet\x00hi",
    "--include-partial-messages",
    "--timeout\x00+7",
    "--transcript-idle-timeout=",
    "--idle-timeout",
    "--add-dir",
    "--add-dir\x00--",
    "--add-dir\x00--bare",
    "--add-dir\x00/a\x00/b\x00--\x00what",
    "hi\x00--add-dir\x00/a\x00--mcp-config\x00x\x00y\x00--add-dir\x00/b",
    "--mcp-config\x00a\x00-\x00b",
    "--extra-hook\x00Stop=echo a=b\x00--extra-hook=Pre=x\x00--extra-hook\x00nope",
    "--extra-hook==",
    "--extra-hook=\x00",
    "--add-dir\x00/a\x00--frob\x00v\x00--extra-hook\x00A=b\x00--settings",
    "--add-dir\x00/a\x00--frob\x00v\x00--extra-hook\x00A=b\x00one\x00two",
    "--brief\x00hi",
    "--frobnitz\x00bar\x00hello",
    "--frobnitz\x00--brief\x00hello",
    "-x\x00-yz\x00hi",
    "-h\x00-v\x00-c",
    "--dangerously-skip-permissions\x00hi",
    "--setting-json\x00{\"env\":{}}\x00--system-prompt=be terse\x00hi",
    "a\x00b",
    "\xff\xfe\x00--\x00\xff",
};

test "fuzz: parse never panics, leaks, or breaks structural invariants" {
    try testing.fuzz({}, fuzzParseOne, .{ .corpus = &parse_corpus });
}

test "prop: parse universal invariants over 3000 structured random argvs" {
    var hz = Harness.init(0xA26_5EED_0001);
    defer hz.deinit();
    for (0..3000) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        if (g.below(8) == 0) av.push("daemon");
        // Half the trials start from a well-formed prefix so parsing reaches
        // deep states (populated lists) before the arbitrary tokens.
        if (g.rand.boolean()) try g.units(&av, 5, .{ .prompt = true });
        for (0..g.below(9)) |_| av.push(try g.token());
        checkUniversal(av.slice(), trial) catch |e| {
            dumpArgv("universal", trial, av.slice());
            return e;
        };
    }
}

// ---------------------------------------------------------------- 2. booleans

test "prop: known boolean flags are forwarded and never swallow the prompt" {
    var hz = Harness.init(0xA26_5EED_0002);
    defer hz.deinit();
    var covered: usize = 0;
    for (args.known_boolean_long_flags) |flag| {
        if (isRejectedLike(flag)) continue;
        covered += 1;
        for (0..150) |trial| {
            var g = hz.trial();
            const prompt = try g.nonDash();
            const other = g.boolFlag();
            var av: Argv = .{};
            var flags: Argv = .{};
            switch (g.below(5)) {
                0 => av.pushAll(&.{ flag, prompt }),
                1 => av.pushAll(&.{ "daemon", flag, prompt }),
                2 => av.pushAll(&.{ flag, other, prompt }),
                3 => av.pushAll(&.{ other, flag, prompt }),
                else => av.pushAll(&.{ prompt, flag }),
            }
            // `daemon` as the first token is the subcommand, not a prompt.
            if (std.mem.eql(u8, av.buf[0], "daemon") and av.len == 2) continue;
            for (av.slice()) |t| if (isKnownBoolean(t) and !sameSlice(t, prompt)) flags.push(t);

            errdefer dumpArgv("boolean", trial, av.slice());
            if (std.mem.eql(u8, av.buf[0], "daemon")) {
                // Daemon mode takes no positional prompt.
                try expectParseError(ParseError.UnknownFlag, av.slice());
                continue;
            }
            var opts = try parseOk(av.slice());
            defer opts.deinit(testing.allocator);
            try testing.expect(opts.prompt != null);
            try testing.expect(sameSlice(prompt, opts.prompt.?));

            // Forwarded exactly once each, in order. The one flag with a
            // dedicated field is forwarded through that field instead.
            var want: Argv = .{};
            var want_dsp = false;
            for (flags.slice()) |f| {
                if (isDsp(f)) want_dsp = true else want.push(f);
            }
            try testing.expectEqual(want_dsp, opts.dangerously_skip_permissions);
            try testing.expectEqual(want.len, opts.passthrough.items.len);
            for (want.slice(), opts.passthrough.items) |w, got| try testing.expect(sameSlice(w, got));
        }
    }
    try testing.expectEqual(args.known_boolean_long_flags.len - 2, covered);
}

test "prop: unknown non-boolean long flags DO take the next non-dash token (control)" {
    // Proves the boolean table is load-bearing: without it the prompt is lost.
    var hz = Harness.init(0xA26_5EED_0003);
    defer hz.deinit();
    for (0..1000) |trial| {
        var g = hz.trial();
        const flag = try g.unknownLong();
        const value = try g.nonDash();
        const prompt = try g.nonDash();
        const argv: Tokens = &.{ flag, value, prompt };
        errdefer dumpArgv("greedy", trial, argv);
        var opts = try parseOk(argv);
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), opts.passthrough.items.len);
        try testing.expect(sameSlice(flag, opts.passthrough.items[0]));
        try testing.expect(sameSlice(value, opts.passthrough.items[1]));
        try testing.expect(sameSlice(prompt, opts.prompt.?));
    }
}

// ---------------------------------------------------------------- 3. rejected

test "prop: rejected flags always return UnsupportedFlag at a flag position" {
    var hz = Harness.init(0xA26_5EED_0004);
    defer hz.deinit();
    for (0..3000) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        if (g.rand.boolean()) av.push("daemon");
        try g.units(&av, 5, .{ .prompt = true });
        av.push(try g.rejected());
        // Whatever follows (even `--`, `--help`, garbage) cannot rescue it.
        for (0..g.below(5)) |_| av.push(try g.token());
        expectParseError(ParseError.UnsupportedFlag, av.slice()) catch |e| {
            dumpArgv("rejected", trial, av.slice());
            return e;
        };
    }
}

test "prop: rejected flags after `--` become the positional prompt" {
    var hz = Harness.init(0xA26_5EED_0005);
    defer hz.deinit();
    for (0..2000) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        if (g.rand.boolean()) av.push("daemon");
        try g.units(&av, 5, .{});
        const rej = try g.rejected();
        av.pushAll(&.{ "--", rej });
        errdefer dumpArgv("rejected-after-sep", trial, av.slice());
        if (std.mem.eql(u8, av.buf[0], "daemon")) {
            try expectParseError(ParseError.UnknownFlag, av.slice());
            continue;
        }
        var opts = try parseOk(av.slice());
        defer opts.deinit(testing.allocator);
        try testing.expect(sameSlice(rej, opts.prompt.?));
        for (opts.passthrough.items) |it| try testing.expect(!sameSlice(it, rej));
    }
}

test "prop: every exact rejected spelling, one-shot and daemon, each position" {
    const spellings = [_][]const u8{
        "-p",                       "--print",                    "--settings",           "--bare",                     "--safe-mode",
        "-p=",                      "--print=",                   "--settings=",          "--bare=",                    "--safe-mode=",
        "-p=x",                     "--print=x",                  "--settings={}",        "--bare=1",                   "--safe-mode=true",
        "-p==",                     "--print=a=b",                "--settings=a b",       "--bare=--",                  "--safe-mode=\x00",
        "--no-session-persistence", "--no-session-persistence=1", "--input-format",       "--input-format=stream-json", "--json-schema",
        "--json-schema={}",         "--max-budget-usd",           "--max-budget-usd=0.5",
    };
    for (spellings) |s| {
        const cases = [_]Tokens{
            &.{s},
            &.{ s, "hi" },
            &.{ "hi", s },
            &.{ s, "--help" },
            &.{ "--help", s },
            &.{ "--verbose", "--add-dir", "/a", s },
            &.{ "--frobnitz", s },
            &.{ s, "--", "hi" },
            &.{ "daemon", s },
            &.{ "daemon", "--brief", s, "--version" },
        };
        for (cases) |argv| {
            errdefer dumpArgv("rejected-exact", 0, argv);
            try expectParseError(ParseError.UnsupportedFlag, argv);
        }
        // After `--` the same token is a prompt (daemon mode takes none).
        try expectParseError(ParseError.UnknownFlag, &.{ "daemon", "--", s });
        for ([_]Tokens{ &.{ "--", s }, &.{ "--brief", "--", s } }) |argv| {
            var opts = try parseOk(argv);
            defer opts.deinit(testing.allocator);
            try testing.expectEqualStrings(s, opts.prompt.?);
            try testing.expect(!opts.show_help);
        }
        // Boundary (commander semantics): a value-taking flag consumes it.
        for (single_value_flags) |vf| {
            var opts = try parseOk(&.{ vf, s });
            defer opts.deinit(testing.allocator);
            try testing.expectEqual(@as(?[]const u8, null), opts.prompt);
            try testing.expectEqual(@as(usize, 0), opts.passthrough.items.len);
        }
    }
    // Lookalikes are not rejected.
    for ([_][]const u8{ "--printer", "--settingsx", "--bareword", "--safe-modes", "--prin", "--input-formats", "--json-schemas" }) |s| {
        var opts = try parseOk(&.{s});
        defer opts.deinit(testing.allocator);
        try testing.expectEqualStrings(s, opts.passthrough.items[0]);
    }
}

// ---------------------------------------------------------------- 4. `--`

test "prop: one token after `--` is the prompt verbatim; a second is UnknownFlag" {
    var hz = Harness.init(0xA26_5EED_0006);
    defer hz.deinit();
    for (0..3000) |trial| {
        var g = hz.trial();
        var pre: Argv = .{};
        if (g.below(4) == 0) pre.push("daemon");
        try g.units(&pre, 5, .{});
        const t = switch (g.below(4)) {
            0 => ([_][]const u8{ "-p", "--bare", "--help", "--settings", "--", "-h", "--version", "--add-dir", "--output-format=stream-json", "daemon", "" })[g.below(11)],
            1 => try g.rejected(),
            else => try g.token(),
        };
        const one = join(&.{ pre.slice(), &.{ "--", t } });
        errdefer dumpArgv("separator", trial, one.slice());

        const before = try observe(pre.slice(), null);
        // Daemon mode rejects a generated `--input-file` (UnknownFlag) or
        // `--output-format text|json` (UnsupportedFlag); nothing to test.
        if (before.err != null and pre.len > 0 and std.mem.eql(u8, pre.buf[0], "daemon")) {
            try testing.expect(before.err.? == ParseError.UnknownFlag or before.err.? == ParseError.UnsupportedFlag);
            continue;
        }
        try testing.expectEqual(@as(?anyerror, null), before.err);
        try testing.expectEqual(@as(?[]const u8, null), before.prompt);

        // The token is the prompt, and nothing else about the parse changed:
        // it was not interpreted as a flag. Daemon mode takes no prompt.
        const after = try observe(one.slice(), null);
        if (before.is_daemon) {
            try testing.expectEqual(@as(?anyerror, ParseError.UnknownFlag), after.err);
        } else {
            var expected = before;
            expected.prompt = t;
            try testing.expect(std.meta.eql(expected, after));
        }

        // A second token after `--` is rejected, whatever it is.
        const two = join(&.{ one.slice(), &.{try g.token()} });
        try expectParseError(ParseError.UnknownFlag, two.slice());

        // So is `--` + token when a prompt was already given.
        const dup = join(&.{ pre.slice(), &.{ "--debug", try g.nonDash(), "--", t } });
        try expectParseError(ParseError.UnknownFlag, dup.slice());

        // A bare trailing `--` is a no-op.
        const bare = join(&.{ pre.slice(), &.{"--"} });
        try testing.expect(std.meta.eql(before, try observe(bare.slice(), null)));
    }
}

// ---------------------------------------------------------------- 5. variadic

test "prop: variadic flags collect exactly their values and stop at `-...` or `--`" {
    var hz = Harness.init(0xA26_5EED_0007);
    defer hz.deinit();
    for (0..3000) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        var dirs: Argv = .{};
        var mcps: Argv = .{};
        var pass: Argv = .{};
        var prompt: ?[]const u8 = null;
        var model: ?[]const u8 = null;
        var verbose = false;

        if (g.below(3) == 0) {
            prompt = try g.nonDash();
            av.push(prompt.?);
            if (std.mem.eql(u8, prompt.?, "daemon")) continue;
        }
        const groups = 1 + g.below(4);
        var ended = false;
        for (0..groups) |_| {
            const is_dir = g.rand.boolean();
            av.push(if (is_dir) "--add-dir" else "--mcp-config");
            for (0..1 + g.below(4)) |_| {
                const v = try g.nonDash();
                av.push(v);
                if (is_dir) dirs.push(v) else mcps.push(v);
            }
            // Terminator: what stops the variadic run.
            switch (g.below(6)) {
                0 => {}, // next group's flag (or end of argv) terminates
                1 => {
                    av.push("--verbose");
                    verbose = true;
                },
                2 => {
                    const s = try g.shortFlag();
                    av.push(s);
                    pass.push(s);
                },
                3 => {
                    model = try g.nonDash();
                    av.pushAll(&.{ "--model", model.? });
                },
                4 => {
                    const b = g.boolFlag();
                    av.push(b);
                    if (!isDsp(b)) pass.push(b);
                },
                else => if (prompt == null) {
                    // `--` ends the list; the next token is the prompt even
                    // when it looks like a flag.
                    prompt = try g.token();
                    av.pushAll(&.{ "--", prompt.? });
                    ended = true;
                },
            }
            if (ended) break;
        }

        errdefer dumpArgv("variadic", trial, av.slice());
        var opts = try parseOk(av.slice());
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(dirs.len, opts.add_dirs.items.len);
        for (dirs.slice(), opts.add_dirs.items) |w, got| try testing.expect(sameSlice(w, got));
        try testing.expectEqual(mcps.len, opts.mcp_configs.items.len);
        for (mcps.slice(), opts.mcp_configs.items) |w, got| try testing.expect(sameSlice(w, got));
        try testing.expectEqual(pass.len, opts.passthrough.items.len);
        for (pass.slice(), opts.passthrough.items) |w, got| try testing.expect(sameSlice(w, got));
        try testing.expectEqual(verbose, opts.verbose);
        try testing.expectEqual(prompt == null, opts.prompt == null);
        if (prompt) |p| try testing.expect(sameSlice(p, opts.prompt.?));
        try testing.expectEqual(model == null, opts.model == null);
        if (model) |m| try testing.expect(sameSlice(m, opts.model.?));
    }
}

test "prop: variadic flags need a non-dash first value; `=` form takes exactly one" {
    var hz = Harness.init(0xA26_5EED_0008);
    defer hz.deinit();
    for (variadic_flags) |flag| {
        try expectParseError(ParseError.MissingValue, &.{flag});
        try expectParseError(ParseError.MissingValue, &.{ "hi", "--brief", flag });
        try expectParseError(ParseError.MissingValue, &.{ "--add-dir", "/a", "--mcp-config", "m", flag });
        for (0..500) |trial| {
            var g = hz.trial();
            const first = try g.token(); // may be `--`, `-p`, `--bare`, ...
            const rest = try g.shortFlag();
            const argv: Tokens = &.{ flag, first, rest };
            errdefer dumpArgv("variadic-first", trial, argv);
            if (std.mem.startsWith(u8, first, "-")) {
                // Never swallow a flag or `--` as the first value.
                try expectParseError(ParseError.MissingValue, argv);
            } else {
                var opts = try parseOk(argv);
                defer opts.deinit(testing.allocator);
                const list = if (std.mem.eql(u8, flag, "--add-dir")) opts.add_dirs else opts.mcp_configs;
                try testing.expectEqual(@as(usize, 1), list.items.len);
                try testing.expect(sameSlice(first, list.items[0]));
                try testing.expectEqual(@as(usize, 1), opts.passthrough.items.len);
                try testing.expectEqual(@as(?[]const u8, null), opts.prompt);
            }

            // `flag=<any>` takes exactly that one value, dash-led or not, and
            // the next non-dash token is the prompt, not a second value.
            const eq = try g.concat(&.{ flag, "=", first });
            const prompt = try g.nonDash();
            var opts = try parseOk(&.{ eq, prompt });
            defer opts.deinit(testing.allocator);
            const list = if (std.mem.eql(u8, flag, "--add-dir")) opts.add_dirs else opts.mcp_configs;
            try testing.expectEqual(@as(usize, 1), list.items.len);
            try testing.expectEqualSlices(u8, first, list.items[0]);
            try testing.expect(sameSlice(prompt, opts.prompt.?));
        }
    }
}

// ---------------------------------------------------------------- 5a. tool rules, -n

test "prop: tool-rule flags forward every rule as a canonical pair, one-shot and daemon" {
    var hz = Harness.init(0xA26_5EED_000D);
    defer hz.deinit();
    for (0..3000) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        var want: Argv = .{}; // expected passthrough
        var prompt: ?[]const u8 = null;
        var verbose = false;
        const daemon = g.below(3) == 0;
        if (daemon) av.push("daemon");

        if (!daemon and g.below(3) == 0) {
            prompt = try g.nonDash();
            if (std.mem.eql(u8, prompt.?, "daemon")) continue;
            av.push(prompt.?);
        }
        var ended = false;
        for (0..1 + g.below(5)) |_| {
            const flag = tool_flags[g.below(tool_flags.len)];
            const canonical = toolCanonical(flag);
            if (g.below(3) == 0) {
                // Attached form: exactly one rule, dash-led or not. Use a
                // distinct pointer so the expected slice is the token tail.
                const rule = try g.token();
                const eq = try g.concat(&.{ flag, "=", rule });
                av.push(eq);
                want.push(canonical);
                want.push(eq[flag.len + 1 ..]);
                // The next token is not a second rule.
                switch (g.below(3)) {
                    0 => {
                        av.push("--verbose");
                        verbose = true;
                    },
                    1 => if (!daemon and prompt == null) {
                        prompt = try g.nonDash();
                        av.push(prompt.?);
                    },
                    else => {},
                }
                continue;
            }
            av.push(flag);
            for (0..1 + g.below(4)) |_| {
                const rule = try g.nonDash();
                av.push(rule);
                want.push(canonical);
                want.push(rule);
            }
            // Terminator: what stops the variadic run.
            switch (g.below(6)) {
                0 => {}, // the next tool flag (or end of argv)
                1 => {
                    av.push("--verbose");
                    verbose = true;
                },
                2 => {
                    const s = try g.shortFlag();
                    av.push(s);
                    want.push(s);
                },
                3 => {
                    const name = try g.token();
                    av.pushAll(&.{ "-n", name });
                    want.pushAll(&.{ "-n", name });
                },
                4 => {
                    const b = g.boolFlag();
                    av.push(b);
                    if (!isDsp(b)) want.push(b);
                },
                else => if (!daemon and prompt == null) {
                    // `--` ends the run; the next token is the prompt even
                    // when it looks like a flag.
                    prompt = try g.token();
                    av.pushAll(&.{ "--", prompt.? });
                    ended = true;
                },
            }
            if (ended) break;
        }

        errdefer dumpArgv("tool-rules", trial, av.slice());
        var opts = try parseOk(av.slice());
        defer opts.deinit(testing.allocator);
        try testing.expectEqual(daemon, opts.is_daemon);
        try testing.expectEqual(want.len, opts.passthrough.items.len);
        for (want.slice(), opts.passthrough.items) |w, got| try testing.expect(sameSlice(w, got));
        try testing.expect(opts.allowed_tools == null and opts.disallowed_tools == null);
        try testing.expectEqual(verbose, opts.verbose);
        try testing.expectEqual(prompt == null, opts.prompt == null);
        if (prompt) |p| try testing.expect(sameSlice(p, opts.prompt.?));
        try checkUniversal(av.slice(), trial);
    }
}

test "prop: tool-rule flags need a non-dash first rule" {
    var hz = Harness.init(0xA26_5EED_000E);
    defer hz.deinit();
    for (tool_flags) |flag| {
        try expectParseError(ParseError.MissingValue, &.{flag});
        try expectParseError(ParseError.MissingValue, &.{ "hi", "--brief", flag });
        try expectParseError(ParseError.MissingValue, &.{ "daemon", "--allowedTools", "Bash", flag });
        for (0..300) |trial| {
            var g = hz.trial();
            const first = try g.token();
            const argv: Tokens = &.{ flag, first, "--debug" };
            errdefer dumpArgv("tool-first", trial, argv);
            if (std.mem.startsWith(u8, first, "-")) {
                // Never swallow a flag or `--` as the first rule.
                try expectParseError(ParseError.MissingValue, argv);
            } else {
                var opts = try parseOk(argv);
                defer opts.deinit(testing.allocator);
                try testing.expectEqual(@as(usize, 2), opts.passthrough.items.len);
                try testing.expect(sameSlice(toolCanonical(flag), opts.passthrough.items[0]));
                try testing.expect(sameSlice(first, opts.passthrough.items[1]));
                try testing.expect(opts.debug);
            }
        }
    }
}

test "prop: -n/--name forward one value of any shape and never take the prompt" {
    var hz = Harness.init(0xA26_5EED_000F);
    defer hz.deinit();
    for (0..2000) |trial| {
        var g = hz.trial();
        const flag = name_flags[g.below(name_flags.len)];
        const value = try g.token(); // may be `--`, `-p`, `--bare`, a flag...
        const prompt = try g.nonDash();
        const with_sep = g.rand.boolean();
        var pre: Argv = .{};
        try g.units(&pre, 3, .{});
        const before = try observe(pre.slice(), null);
        try testing.expectEqual(@as(?anyerror, null), before.err);

        // `--debug` first: a variadic unit must not absorb the name flag's
        // neighbours; a dash-led token ends any open run.
        const argv = join(&.{
            pre.slice(),                                                   &.{ flag, value },
            if (with_sep) &.{ "--", prompt } else &.{ "--debug", prompt },
        });
        errdefer dumpArgv("name", trial, argv.slice());
        if (std.mem.eql(u8, prompt, "daemon") and argv.len == 0) continue;
        var opts = try parseOk(argv.slice());
        defer opts.deinit(testing.allocator);
        try testing.expect(sameSlice(prompt, opts.prompt.?));
        const items = opts.passthrough.items;
        try testing.expectEqual(before.n_pass + 2, items.len);
        try testing.expect(sameSlice(flag, items[items.len - 2]));
        try testing.expect(sameSlice(value, items[items.len - 1]));

        // Missing value: the flag is the last token.
        const cut = join(&.{ pre.slice(), &.{flag} });
        try expectParseError(ParseError.MissingValue, cut.slice());
        // Daemon mode forwards the pair too.
        const d = join(&.{ &.{"daemon"}, pre.slice(), &.{ flag, value } });
        const dobs = try observe(d.slice(), null);
        if (dobs.err) |e| {
            // Only a generated `--input-file` or `--output-format text|json`.
            try testing.expect(e == ParseError.UnknownFlag or e == ParseError.UnsupportedFlag);
        } else try testing.expectEqual(before.n_pass + 2, dobs.n_pass);
    }
}

test "prop: daemon mode refuses an explicit non-stream-json --output-format" {
    var hz = Harness.init(0xA26_5EED_0010);
    defer hz.deinit();
    const cfg: UnitCfg = .{ .format = false };
    for (0..2000) |trial| {
        var g = hz.trial();
        var pre: Argv = .{};
        var post: Argv = .{};
        try g.units(&pre, 3, cfg);
        try g.units(&post, 3, cfg);
        const name = ([_][]const u8{ "text", "json" })[g.below(2)];
        const bad: Tokens = if (g.rand.boolean())
            &.{ "--output-format", name }
        else
            &.{if (name[0] == 't') "--output-format=text" else "--output-format=json"};
        const argv = join(&.{ &.{"daemon"}, pre.slice(), &.{"--debug"}, bad, post.slice() });
        errdefer dumpArgv("daemon-format", trial, argv.slice());
        const plain = try observe(join(&.{ &.{"daemon"}, pre.slice(), &.{"--debug"}, post.slice() }).slice(), null);
        const got = try observe(argv.slice(), null);
        if (plain.err) |e| {
            // A generated `--input-file` already fails; that error wins.
            try testing.expectEqual(@as(?anyerror, ParseError.UnknownFlag), @as(?anyerror, e));
            try testing.expectEqual(plain.err, got.err);
            continue;
        }
        try testing.expectEqual(@as(?anyerror, ParseError.UnsupportedFlag), got.err);

        // A later stream-json wins and is accepted; one-shot never refuses.
        const fixed = join(&.{ argv.slice(), &.{"--output-format=stream-json"} });
        const f = try observe(fixed.slice(), null);
        try testing.expectEqual(@as(?anyerror, null), f.err);
        try testing.expectEqual(args.OutputFormat.stream_json, f.output_format);
        const one_shot = try observe(argv.slice()[1..], null);
        try testing.expectEqual(@as(?anyerror, null), one_shot.err);
    }
}

// ---------------------------------------------------------------- 5b. `=` forms

fn expectEqualOptStr(a: ?[]const u8, b: ?[]const u8) !void {
    try testing.expectEqual(a == null, b == null);
    if (a) |x| try testing.expectEqualSlices(u8, x, b.?);
}

fn expectEqualStrList(a: []const []const u8, b: []const []const u8) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualSlices(u8, x, y);
}

/// Content equality of two parses (slices compare by bytes, not identity,
/// because the `=` form borrows a substring of a different token).
fn expectSameContent(a: *const args.Options, b: *const args.Options) !void {
    inline for (@typeInfo(args.Options).@"struct".fields) |f| {
        const x = @field(a, f.name);
        const y = @field(b, f.name);
        switch (f.type) {
            ?[]const u8 => try expectEqualOptStr(x, y),
            std.ArrayList([]const u8) => try expectEqualStrList(x.items, y.items),
            std.ArrayList(claude_p.hook.ExtraHook) => {
                try testing.expectEqual(x.items.len, y.items.len);
                for (x.items, y.items) |p, q| {
                    try testing.expectEqualSlices(u8, p.event, q.event);
                    try testing.expectEqualSlices(u8, p.command, q.command);
                }
            },
            else => try testing.expectEqual(x, y),
        }
    }
}

fn valueFor(g: *Gen, flag: []const u8) ![]const u8 {
    if (std.mem.eql(u8, flag, "--output-format"))
        return ([_][]const u8{ "text", "json", "stream-json", "yaml", "", "JSON" })[g.below(6)];
    for (integer_flag_prefixes) |p| if (std.mem.eql(u8, flag, p)) {
        return switch (g.below(4)) {
            0 => "seven",
            1 => "-1",
            else => try std.fmt.allocPrint(g.arena, "{d}", .{g.rand.int(u32)}),
        };
    };
    if (std.mem.eql(u8, flag, "--extra-hook"))
        return if (g.below(4) == 0) try g.printable(0, 8) else try g.hookValue();
    // String flags consume any token, dash-led or not.
    return if (g.rand.boolean()) try g.token() else try g.nonDash();
}

test "prop: `--flag val` and `--flag=val` parse identically for every value flag" {
    var hz = Harness.init(0xA26_5EED_000C);
    defer hz.deinit();
    for (value_flags) |flag| {
        for (0..300) |trial| {
            var g = hz.trial();
            const value = try valueFor(&g, flag);
            const eq = try g.concat(&.{ flag, "=", value });
            var pre: Argv = .{};
            var post: Argv = .{};
            if (g.below(4) == 0) pre.push("daemon");
            try g.units(&pre, 3, .{ .prompt = true });
            try g.units(&post, 3, .{ .prompt = true });

            const spaced = join(&.{ pre.slice(), &.{ flag, value }, post.slice() });
            const joined = join(&.{ pre.slice(), &.{eq}, post.slice() });
            errdefer {
                dumpArgv("eq-form spaced", trial, spaced.slice());
                dumpArgv("eq-form joined", trial, joined.slice());
            }

            const ra = args.parse(testing.allocator, spaced.slice());
            const rb = args.parse(testing.allocator, joined.slice());
            if (ra) |pa| {
                var a = pa;
                defer a.deinit(testing.allocator);
                var b = try rb;
                defer b.deinit(testing.allocator);
                try expectSameContent(&a, &b);
                // The `=` value is never forwarded to claude.
                for (b.passthrough.items) |it| try testing.expect(!sameSlice(it, eq));
            } else |ea| {
                if (rb) |pb| {
                    var b = pb;
                    b.deinit(testing.allocator);
                    return error.TestExpectedError;
                } else |eb| try testing.expectEqual(ea, eb);
            }
            // Both spellings also pass the universal invariants.
            try checkUniversal(joined.slice(), trial);
        }
    }
}

/// Reference model for `--extra-hook` values.
fn hookModel(value: []const u8) ?struct { event: []const u8, command: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return null;
    if (eq == 0 or eq + 1 == value.len) return null;
    return .{ .event = value[0..eq], .command = value[eq + 1 ..] };
}

fn checkHookValue(g: *Gen, value: []const u8) !void {
    const eq_form = try g.concat(&.{ "--extra-hook=", value });
    const forms = [_]Tokens{
        &.{ "--extra-hook", value },
        &.{eq_form},
        // Earlier allocations in every list must not leak on a late error.
        &.{ "--add-dir", "/a", "/b", "--mcp-config", "m", "--frob", "v", "--extra-hook", "Stop=ok", "--extra-hook", value },
        &.{ "daemon", "--extra-hook=Pre=x=y", eq_form, "-x" },
    };
    for (forms, 0..) |argv, fi| {
        errdefer dumpArgv("extra-hook", fi, argv);
        if (hookModel(value)) |want| {
            var opts = try parseOk(argv);
            defer opts.deinit(testing.allocator);
            const got = opts.extra_hooks.items[opts.extra_hooks.items.len - 1];
            try testing.expectEqualSlices(u8, want.event, got.event);
            try testing.expectEqualSlices(u8, want.command, got.command);
            try testing.expectEqual(@as(usize, if (fi < 2) 1 else 2), opts.extra_hooks.items.len);
        } else {
            try expectParseError(ParseError.BadExtraHook, argv);
        }
    }
}

test "prop: --extra-hook splits on the first `=` and rejects malformed values" {
    var hz = Harness.init(0xA26_5EED_0009);
    defer hz.deinit();
    for (0..2000) |_| {
        var g = hz.trial();
        const event = try g.alnum(1, 12);
        const value = switch (g.below(8)) {
            // Well-formed; the command keeps every later `=`.
            0, 1 => try g.concat(&.{ event, "=", try g.printable(1, 16) }),
            2 => try g.concat(&.{ event, "=", try g.printable(0, 4), "=", try g.printable(0, 4), "=" }),
            3 => event, // no `=`
            4 => try g.concat(&.{ "=", try g.printable(0, 8) }), // empty event
            5 => try g.concat(&.{ event, "=" }), // empty command
            6 => try g.bytes(16),
            else => try g.printable(0, 16),
        };
        try checkHookValue(&g, value);
    }
    var g = hz.trial();
    for ([_][]const u8{ "", "=", "==", "a", "a=", "=a", "a==", "a=b", "a=b=c", "a= ", " =b", "-=-", "--=--" }) |v| {
        try checkHookValue(&g, v);
    }
    try expectParseError(ParseError.MissingValue, &.{"--extra-hook"});
    try expectParseError(ParseError.MissingValue, &.{ "--extra-hook", "A=b", "--extra-hook" });
}

fn fuzzExtraHookOne(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0);
    var g: Gen = .{ .rand = prng.random(), .arena = arena.allocator() };
    try checkHookValue(&g, input);
}

test "fuzz: --extra-hook value matches the first-`=` split model" {
    try testing.fuzz({}, fuzzExtraHookOne, .{ .corpus = &.{
        "= ",       "==",           "Stop",                     "Stop=",
        "=echo hi", "Stop=echo hi", "PostToolUse=env A=1 true", "a=b=c=d",
        "a==",      "\x00=\x00",    "Stop=\n",                  "--=--",
        "=\xff",    "\xff=\xff",    "Stop =x",
    } });
}

// ---------------------------------------------------------------- 6. stream-json

test "prop: one-shot stream-json without --verbose is always rejected; daemon is exempt" {
    var hz = Harness.init(0xA26_5EED_000A);
    defer hz.deinit();
    const cfg: UnitCfg = .{ .prompt = true, .format = false, .verbose_help = false };
    for (0..3000) |trial| {
        var g = hz.trial();
        var pre: Argv = .{};
        var post: Argv = .{};
        try g.units(&pre, 4, cfg);
        try g.units(&post, 4, cfg);
        const sj: Tokens = if (g.rand.boolean())
            &.{ "--output-format", "stream-json" }
        else
            &.{"--output-format=stream-json"};

        const one_shot = join(&.{ pre.slice(), sj, post.slice() });
        if (one_shot.len > 0 and std.mem.eql(u8, one_shot.buf[0], "daemon")) continue;
        errdefer dumpArgv("stream-json", trial, one_shot.slice());

        try expectParseError(ParseError.StreamJsonRequiresVerbose, one_shot.slice());
        // Leak-checked and structurally validated as well.
        try testing.expectEqual(
            @as(?anyerror, ParseError.StreamJsonRequiresVerbose),
            (try observe(one_shot.slice(), null)).err,
        );

        // Daemon mode is exempt (but takes no positional prompt).
        const daemon = join(&.{ &.{"daemon"}, one_shot.slice() });
        const d = try observe(daemon.slice(), null);
        // The generated prompt may have been absorbed by a variadic flag, so
        // ask the parser (with the rule lifted) whether one survived.
        const lifted = join(&.{ &.{"--verbose"}, one_shot.slice() });
        const v = try observe(lifted.slice(), null);
        try testing.expectEqual(@as(?anyerror, null), v.err);
        if (v.prompt != null or v.has_input_file) {
            try testing.expectEqual(@as(?anyerror, ParseError.UnknownFlag), d.err);
        } else {
            try testing.expectEqual(@as(?anyerror, null), d.err);
            try testing.expect(d.is_daemon and !d.verbose);
            try testing.expectEqual(args.OutputFormat.stream_json, d.output_format);
        }

        // `--verbose` anywhere at a flag position satisfies the rule.
        const escape = ([_][]const u8{ "--verbose", "--help", "-h", "--version", "-v" })[g.below(5)];
        const fixed = switch (g.below(3)) {
            0 => join(&.{ &.{escape}, one_shot.slice() }),
            1 => join(&.{ pre.slice(), &.{escape}, sj, post.slice() }),
            else => join(&.{ one_shot.slice(), &.{escape} }),
        };
        const f = try observe(fixed.slice(), null);
        try testing.expectEqual(@as(?anyerror, null), f.err);
        try testing.expectEqual(args.OutputFormat.stream_json, f.output_format);
        try testing.expect(f.verbose or f.show_help or f.show_version);

        // The LAST --output-format wins, so a later json/text lifts the rule
        // and a later stream-json reinstates it.
        const later = join(&.{ one_shot.slice(), &.{ "--output-format", if (g.rand.boolean()) "json" else "text" } });
        const l = try observe(later.slice(), null);
        try testing.expectEqual(@as(?anyerror, null), l.err);
        try testing.expect(l.output_format != .stream_json);
        const again = join(&.{ later.slice(), &.{"--output-format=stream-json"} });
        try expectParseError(ParseError.StreamJsonRequiresVerbose, again.slice());

        // `--verbose` after `--` is a prompt, not the flag: still rejected.
        if (!g.has_prompt) {
            const fake = join(&.{ pre.slice(), sj, &.{ "--", "--verbose" } });
            try expectParseError(ParseError.StreamJsonRequiresVerbose, fake.slice());
        }
    }
}

// ---------------------------------------------------------------- 7. OOM sweeps

/// Runs `parse`; succeeds when the result is `expected` (`null` = ok).
/// Only `OutOfMemory` escapes, as `checkAllAllocationFailures` requires.
fn parseExpecting(allocator: std.mem.Allocator, argv: Tokens, expected: ?ParseError) !void {
    if (args.parse(allocator, argv)) |parsed| {
        var opts = parsed;
        opts.deinit(allocator);
        if (expected != null) return error.TestExpectedError;
    } else |err| {
        if (err == ParseError.OutOfMemory) return error.OutOfMemory;
        if (expected == null or expected.? != err) return error.TestUnexpectedResult;
    }
}

const oom_prefix = [_][]const u8{
    "--add-dir",      "/a",                           "/b",           "/c",                       "/d",
    "/e",             "--mcp-config",                 "x.json",       "y.json",                   "--extra-hook",
    "Stop=echo a=b",  "--extra-hook=PreToolUse=true", "--frob",       "val",                      "--brief",
    "-x",             "--add-dir",                    "/f",           "--mcp-config",             "{\"mcpServers\":{}}",
    "--fork-session", "--other=1",                    "--extra-hook", "PostToolUse=env A=1 true", "-yz",
};

test "oom: checkAllAllocationFailures on complex multi-flag argvs (ok and every error)" {
    const Case = struct { tail: Tokens, daemon: bool = false, expected: ?ParseError };
    const cases = [_]Case{
        .{ .tail = &.{}, .expected = null },
        .{ .tail = &.{ "--", "-p" }, .expected = null },
        .{ .tail = &.{ "--output-format", "stream-json", "--verbose", "hi" }, .expected = null },
        .{ .tail = &.{ "--output-format", "stream-json" }, .daemon = true, .expected = null },
        .{ .tail = &.{ "--output-format", "stream-json", "hi" }, .expected = ParseError.StreamJsonRequiresVerbose },
        .{ .tail = &.{"--settings"}, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{"--settings={}"}, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{ "-p", "hi" }, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{"--print=1"}, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{"--bare"}, .daemon = true, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{"--safe-mode=1"}, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{ "--timeout", "x" }, .expected = ParseError.BadInteger },
        .{ .tail = &.{ "--max-turns", "3" }, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{ "--disallowedTools", "Bash", "Edit", "--allowed-tools=Read", "-n", "s", "--", "hi" }, .expected = null },
        .{ .tail = &.{ "--allowedTools", "Bash", "--allowedTools" }, .expected = ParseError.MissingValue },
        .{ .tail = &.{ "--disallowedTools", "Bash", "-n" }, .expected = ParseError.MissingValue },
        .{ .tail = &.{ "--output-format", "json" }, .daemon = true, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{"--transcript-idle-timeout=-1"}, .expected = ParseError.BadInteger },
        .{ .tail = &.{ "--extra-hook", "nope" }, .expected = ParseError.BadExtraHook },
        .{ .tail = &.{"--extra-hook==x"}, .expected = ParseError.BadExtraHook },
        .{ .tail = &.{"--model"}, .expected = ParseError.MissingValue },
        .{ .tail = &.{"--add-dir"}, .expected = ParseError.MissingValue },
        .{ .tail = &.{ "one", "two" }, .expected = ParseError.UnknownFlag },
        .{ .tail = &.{ "--", "one", "two" }, .expected = ParseError.UnknownFlag },
        .{ .tail = &.{ "--output-format", "yaml" }, .expected = ParseError.BadOutputFormat },
        .{ .tail = &.{"--output-format="}, .expected = ParseError.BadOutputFormat },
        .{ .tail = &.{ "--add-dir", "--", "hi" }, .expected = ParseError.MissingValue },
        .{ .tail = &.{"--no-session-persistence"}, .expected = ParseError.UnsupportedFlag },
        .{ .tail = &.{ "--foo=bar", "hi" }, .expected = null },
        .{ .tail = &.{ "-r=sid", "--add-dir=-x" }, .expected = null },
        .{ .tail = &.{"hi"}, .daemon = true, .expected = ParseError.UnknownFlag },
        .{ .tail = &.{"--input-file=/p"}, .daemon = true, .expected = ParseError.UnknownFlag },
    };
    for (cases) |c| {
        const av = join(&.{ if (c.daemon) &.{"daemon"} else &.{}, &oom_prefix, c.tail });
        errdefer dumpArgv("oom", 0, av.slice());
        try testing.checkAllAllocationFailures(testing.allocator, parseExpecting, .{ av.slice(), c.expected });
    }
}

test "oom: checkAllAllocationFailures over 300 random argvs" {
    var hz = Harness.init(0xA26_5EED_000B);
    defer hz.deinit();
    for (0..300) |trial| {
        var g = hz.trial();
        var av: Argv = .{};
        if (g.below(6) == 0) av.push("daemon");
        try g.units(&av, 8, .{ .prompt = true });
        for (0..g.below(6)) |_| av.push(try g.token());
        const base = try observe(av.slice(), null);
        const expected: ?ParseError = if (base.err) |e| @as(ParseError, @errorCast(e)) else null;
        testing.checkAllAllocationFailures(testing.allocator, parseExpecting, .{ av.slice(), expected }) catch |e| {
            dumpArgv("oom-random", trial, av.slice());
            return e;
        };
    }
}

// ---------------------------------------------------------------- OutputFormat

fn formatModel(s: []const u8) ?args.OutputFormat {
    const names = [_][]const u8{ "text", "json", "stream-json" };
    const values = [_]args.OutputFormat{ .text, .json, .stream_json };
    for (names, values) |n, v| if (s.len == n.len and std.mem.eql(u8, s, n)) return v;
    return null;
}

/// `fromString` is exact-match only, and `parse` agrees with it in both the
/// space and `=` forms.
fn checkFormat(scratch: std.mem.Allocator, s: []const u8) !void {
    const got = args.OutputFormat.fromString(s);
    try testing.expectEqual(formatModel(s), got);

    const eq_form = try std.mem.concat(scratch, u8, &.{ "--output-format=", s });
    for ([_]Tokens{ &.{ "daemon", "--output-format", s }, &.{ "daemon", eq_form }, &.{ "--verbose", eq_form } }, 0..) |argv, ai| {
        if (got) |fmt| {
            if (ai < 2 and fmt != .stream_json) {
                // Daemon output is always stream-json.
                try expectParseError(ParseError.UnsupportedFlag, argv);
                continue;
            }
            var opts = try parseOk(argv);
            defer opts.deinit(testing.allocator);
            try testing.expectEqual(fmt, opts.output_format);
            try testing.expectEqual(@as(usize, 0), opts.passthrough.items.len);
        } else {
            try expectParseError(ParseError.BadOutputFormat, argv);
        }
    }
}

test "prop: OutputFormat.fromString accepts exactly text|json|stream-json" {
    var hz = Harness.init(0xA26_5EED_000C);
    defer hz.deinit();
    const names = [_][]const u8{ "text", "json", "stream-json" };
    for (names) |n| {
        const g = hz.trial();
        try checkFormat(g.arena, n);
    }
    for (0..3000) |_| {
        var g = hz.trial();
        const name = names[g.below(names.len)];
        const m = try g.arena.dupe(u8, name);
        const s: []const u8 = switch (g.below(9)) {
            0 => blk: { // flip one byte
                m[g.below(m.len)] ^= @as(u8, 1) << g.rand.int(u3);
                break :blk m;
            },
            1 => blk: { // change case of one letter
                const i = g.below(m.len);
                m[i] = std.ascii.toUpper(m[i]);
                break :blk m;
            },
            2 => m[0..g.below(m.len)], // strict prefix
            3 => m[1 + g.below(m.len - 1) ..], // strict suffix
            4 => try g.concat(&.{ name, try g.printable(1, 3) }),
            5 => try g.concat(&.{ try g.printable(1, 3), name }),
            6 => try g.concat(&.{ name, "\x00" }),
            7 => try g.bytes(12),
            else => blk: { // `_` vs `-`, the enum tag spelling
                std.mem.replaceScalar(u8, m, '-', '_');
                break :blk m;
            },
        };
        try checkFormat(g.arena, s);
    }
}

fn fuzzFormatOne(_: void, input: []const u8) anyerror!void {
    // Zig 0.15.2 lib/fuzzer.zig crashes if an empty slice overwrites a corpus slot.
    if (input.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try checkFormat(arena.allocator(), input);
}

test "fuzz: OutputFormat.fromString exact-match model and parse agreement" {
    try testing.fuzz({}, fuzzFormatOne, .{ .corpus = &.{
        "text",     "json",       "stream-json",  "stream_json",
        "Text",     "JSON",       "stream-json ", " json",
        "json\x00", "streamjson", "stream-jsonl", "tex",
        "yaml",     "--verbose",  "- ",           "--",
        "\xff\xff", "text\n",     "stream-",
    } });
}
