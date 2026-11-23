// Property and fuzz tests for the npm supply-chain surface:
//   scripts/install.js  (parseSha256Sums, verifyChecksum)
//   bin/claude-p.js     (launcher: exit codes, argv, signals)
//
// Run:  node --test tests/prop/js_supplychain_prop.mjs
//
// Zero npm dependencies. Every random choice comes from a seeded PRNG, so a
// failure reproduces exactly. Override the seed with PROP_SEED=<uint32>; each
// assertion message carries the seed and trial number.

import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const inst = require(path.join(repoRoot, "scripts", "install.js"));
const { parseSha256Sums, verifyChecksum, sha256, ChecksumError } = inst;
const launcherSource = path.join(repoRoot, "bin", "claude-p.js");

const BASE_SEED = process.env.PROP_SEED ? Number(process.env.PROP_SEED) >>> 0 : 0xc1a0de5;

// ---------------------------------------------------------------------------
// Seeded PRNG (sfc32) and generator helpers
// ---------------------------------------------------------------------------

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

class Rng {
  constructor(label) {
    this.label = label;
    this.a = 0x9e3779b9;
    this.b = 0x243f6a88;
    this.c = 0xb7e15162;
    this.d = (BASE_SEED ^ fnv1a(label)) >>> 0;
    for (let i = 0; i < 16; i++) this.u32();
  }
  u32() {
    const t = (((this.a + this.b) | 0) + this.d) | 0;
    this.d = (this.d + 1) | 0;
    this.a = this.b ^ (this.b >>> 9);
    this.b = (this.c + (this.c << 3)) | 0;
    this.c = (this.c << 21) | (this.c >>> 11);
    this.c = (this.c + t) | 0;
    return t >>> 0;
  }
  // Uniform integer in [0, n).
  below(n) {
    return Math.floor((this.u32() / 0x100000000) * n);
  }
  // Uniform integer in [lo, hi].
  int(lo, hi) {
    return lo + this.below(hi - lo + 1);
  }
  bool(p = 0.5) {
    return this.u32() / 0x100000000 < p;
  }
  pick(arr) {
    return arr[this.below(arr.length)];
  }
  bytes(n) {
    const buf = Buffer.allocUnsafe(n);
    let i = 0;
    for (; i + 4 <= n; i += 4) buf.writeUInt32LE(this.u32(), i);
    for (; i < n; i++) buf[i] = this.u32() & 0xff;
    return buf;
  }
  ctx(trial) {
    return `[${this.label} seed=${BASE_SEED} trial=${trial}]`;
  }
}

const LOWER_HEX = "0123456789abcdef";

function randHex(rng, n) {
  let s = "";
  for (let i = 0; i < n; i++) s += LOWER_HEX[rng.below(16)];
  return s;
}

// Re-case a lowercase digest: lower, upper, or per-character mixed.
function recase(rng, hex) {
  switch (rng.below(3)) {
    case 0:
      return hex;
    case 1:
      return hex.toUpperCase();
    default: {
      let s = "";
      for (const ch of hex) s += rng.bool() ? ch.toUpperCase() : ch;
      return s;
    }
  }
}

function blanks(rng, min, max) {
  let s = "";
  const n = rng.int(min, max);
  for (let i = 0; i < n; i++) s += rng.bool(0.7) ? " " : "\t";
  return s;
}

const FIXED_NAMES = [
  "claude-p-darwin-arm64.gz",
  "claude-p-darwin-x64.gz",
  "claude-p-linux-arm64.gz",
  "claude-p-linux-x64.gz",
  "../evil",
  "../../etc/passwd",
  "..\\..\\windows\\system32\\evil.exe",
  "/absolute/path/claude-p.gz",
  "./claude-p-darwin-arm64.gz",
  "name with  inner   spaces.gz",
  "tab\tinside.gz",
  "-rf",
  "--flag=value",
  "#not-a-comment",
  "a",
  "ünïcödé-✓-名前.gz",
  "emoji-🚀.gz",
  "nul\u0000byte",
  "CLAUDE-P-DARWIN-ARM64.GZ",
  "constructor",
  "__proto__",
  "toString",
];
const NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.+/@~=:,()[]{}";

// A name the parser must return unchanged: no leading or trailing whitespace,
// no line terminators, and no leading `*` (which is the binary-mode marker).
function randName(rng) {
  if (rng.bool(0.5)) return rng.pick(FIXED_NAMES);
  let s = "";
  const n = rng.int(1, 24);
  for (let i = 0; i < n; i++) {
    const inner = i > 0 && i < n - 1;
    if (inner && rng.bool(0.08)) s += " ";
    else if (rng.bool(0.05)) s += String.fromCodePoint(rng.int(0xa1, 0x24f));
    else s += NAME_CHARS[rng.below(NAME_CHARS.length)];
  }
  return s;
}

function mapEntries(map) {
  return [...map.entries()];
}

// ---------------------------------------------------------------------------
// Independent reference parser (no regular expressions for the match)
// ---------------------------------------------------------------------------

const isWs = (ch) => ch !== undefined && ch.trim() === "";
const LINE_TERMINATORS = ["\n", "\r", " ", " "];

function refParse(text) {
  const out = new Map();
  for (let seg of text.split("\n")) {
    if (seg.endsWith("\r")) seg = seg.slice(0, -1);
    const line = seg.trim();
    if (line.length < 66) continue; // 64 hex + 1 separator + 1 name char
    let hexOk = true;
    for (let i = 0; i < 64; i++) {
      if (!"0123456789abcdefABCDEF".includes(line[i])) {
        hexOk = false;
        break;
      }
    }
    if (!hexOk || !isWs(line[64])) continue;
    let i = 64;
    while (isWs(line[i])) i++;
    const rest = line.slice(i);
    const cand = rest[0] === "*" && rest.length > 1 ? rest.slice(1) : rest;
    if (LINE_TERMINATORS.some((t) => cand.includes(t))) continue;
    out.set(cand.trim(), line.slice(0, 64).toLowerCase());
  }
  return out;
}

// Invariants that hold for every input, whatever it is.
function assertParseInvariants(text, map, ctx) {
  assert.ok(map instanceof Map, `${ctx} result is a Map`);
  const lowerText = text.toLowerCase();
  for (const [name, digest] of map) {
    assert.match(digest, /^[0-9a-f]{64}$/, `${ctx} digest is 64 lowercase hex: ${JSON.stringify(digest)}`);
    assert.equal(typeof name, "string", `${ctx} name is a string`);
    assert.ok(name.length > 0, `${ctx} name is non-empty`);
    assert.equal(name, name.trim(), `${ctx} name carries no outer whitespace: ${JSON.stringify(name)}`);
    assert.ok(
      !LINE_TERMINATORS.some((t) => name.includes(t)),
      `${ctx} name spans one line: ${JSON.stringify(name)}`,
    );
    assert.ok(text.includes(name), `${ctx} name appears verbatim in the input: ${JSON.stringify(name)}`);
    assert.ok(lowerText.includes(digest), `${ctx} digest appears in the input`);
  }
}

// Serialize a parsed map in binary mode; parsing it again must give the same map.
function serialize(map) {
  let s = "";
  for (const [name, digest] of map) s += `${digest} *${name}\n`;
  return s;
}

// ---------------------------------------------------------------------------
// 1. parseSha256Sums
// ---------------------------------------------------------------------------

const NON_HEX = ["g", "G", "z", "Z", "x", "O", "l", "_", "-", ":", "/", "ａ", "Ａ", "０", "é", "\u0000"];

// One generated line and what the parser must do with it.
function genLine(rng) {
  const hex = randHex(rng, 64);
  const name = randName(rng);
  const sep = () => blanks(rng, 1, 4);
  const pad = () => blanks(rng, 0, 3);
  const kind = rng.below(20);
  switch (kind) {
    case 0:
    case 1:
    case 2:
    case 3:
    case 4:
      return { line: `${recase(rng, hex)}${sep()}${name}`, entry: [name, hex], kind: "text" };
    case 5:
    case 6:
    case 7:
      return { line: `${recase(rng, hex)}${sep()}*${name}`, entry: [name, hex], kind: "binary" };
    case 8:
      return { line: `${pad()}${recase(rng, hex)}${sep()}${rng.bool() ? "*" : ""}${name}${pad()}`, entry: [name, hex], kind: "padded" };
    case 9:
      return { line: pad(), entry: null, kind: "blank" };
    case 10:
      // A commented-out valid entry must stay ignored.
      return { line: `#${pad()}${recase(rng, hex)}${sep()}${name}`, entry: null, kind: "comment" };
    case 11:
      return { line: `${recase(rng, hex).slice(0, 63)}${sep()}${name}`, entry: null, kind: "short63" };
    case 12:
      return { line: `${recase(rng, hex)}${LOWER_HEX[rng.below(16)]}${sep()}${name}`, entry: null, kind: "long65" };
    case 13: {
      const at = rng.below(64);
      const bad = recase(rng, hex);
      return {
        line: `${bad.slice(0, at)}${rng.pick(NON_HEX)}${bad.slice(at + 1)}${sep()}${name}`,
        entry: null,
        kind: "nonhex",
      };
    }
    case 14:
      // No separator. The name starts with a non-hex char so it cannot extend the digest.
      return { line: `${recase(rng, hex)}:${name}`, entry: null, kind: "nosep" };
    case 15:
      return { line: `${recase(rng, hex)}${pad()}`, entry: null, kind: "hashonly" };
    case 16:
      // BSD/reversed layouts are not sha256sum format.
      return rng.bool()
        ? { line: `claude-p.gz${sep()}${recase(rng, hex)}`, entry: null, kind: "reversed" }
        : { line: `SHA256 (claude-p.gz) = ${hex}`, entry: null, kind: "bsd" };
    case 17:
      return { line: `${recase(rng, randHex(rng, rng.int(0, 62)))}${sep()}${name}`, entry: null, kind: "truncated" };
    case 18:
      // `**name` is binary mode for a file literally named `*name`.
      return { line: `${recase(rng, hex)}${sep()}**${name}`, entry: [`*${name}`, hex], kind: "starname" };
    default: {
      let g = "!";
      const n = rng.int(0, 40);
      for (let i = 0; i < n; i++) g += String.fromCharCode(rng.int(0x20, 0x7e));
      return { line: g, entry: null, kind: "garbage" };
    }
  }
}

function genSumsFile(rng) {
  const lines = [];
  const n = rng.int(0, 12);
  for (let i = 0; i < n; i++) {
    const l = genLine(rng);
    lines.push(l);
    // Duplicate filename with a different digest: the later line wins.
    if (l.entry && rng.bool(0.15)) {
      const hex2 = randHex(rng, 64);
      lines.push({ line: `${recase(rng, hex2)}  ${l.kind === "starname" ? "*" : ""}${l.entry[0]}`, entry: [l.entry[0], hex2], kind: "dup" });
    }
  }
  const eolMode = rng.below(3); // LF, CRLF, mixed
  let text = "";
  lines.forEach((l, i) => {
    const last = i === lines.length - 1;
    const eol = eolMode === 0 ? "\n" : eolMode === 1 ? "\r\n" : rng.bool() ? "\n" : "\r\n";
    text += l.line + (last && rng.bool(0.3) ? "" : eol);
  });
  const expected = new Map();
  for (const l of lines) if (l.entry) expected.set(l.entry[0], l.entry[1]);
  return { text, expected, lines };
}

test("parseSha256Sums: 2,500 structured files parse to exactly the valid entries", () => {
  const rng = new Rng("parse-structured");
  const seen = new Set();
  for (let trial = 0; trial < 2500; trial++) {
    const { text, expected, lines } = genSumsFile(rng);
    for (const l of lines) seen.add(l.kind);
    const ctx = rng.ctx(trial);
    let got;
    assert.doesNotThrow(() => {
      got = parseSha256Sums(text);
    }, `${ctx} never throws on ${JSON.stringify(text)}`);
    assert.deepEqual(mapEntries(got), mapEntries(expected), `${ctx} input ${JSON.stringify(text)}`);
    assertParseInvariants(text, got, ctx);
    assert.deepEqual(mapEntries(got), mapEntries(refParse(text)), `${ctx} agrees with the reference parser`);
  }
  // The generator must have exercised every line kind, or the test proves less than it says.
  for (const kind of [
    "text", "binary", "padded", "blank", "comment", "short63", "long65", "nonhex", "nosep",
    "hashonly", "reversed", "bsd", "truncated", "starname", "garbage", "dup",
  ]) {
    assert.ok(seen.has(kind), `generator produced a "${kind}" line`);
  }
});

const FUZZ_SINGLES = [
  " ", " ", " ", "\t", "\n", "\n", "\r\n", "\r", "\v", "\f", " ", " ", " ", "﻿",
  "　", "*", "*", "#", ".", "/", "..", "\\", "\u0000", "g", "G", "ａ", "-", "=", "\ud800", "\udc00",
  "🚀", "é",
];

function genGarbage(rng) {
  let s = "";
  const tokens = rng.int(0, 30);
  for (let i = 0; i < tokens; i++) {
    const k = rng.below(12);
    if (k < 3) s += recase(rng, randHex(rng, rng.pick([64, 64, 64, 64, 63, 65, 128, 1, 32])));
    else if (k < 7) s += rng.pick(FUZZ_SINGLES);
    else if (k < 9) s += randName(rng);
    else if (k === 9) s += String.fromCharCode(rng.below(0x10000));
    else if (k === 10) s += blanks(rng, 1, 5);
    else s += rng.bool() ? "\n" : "\r\n";
  }
  return s;
}

test("parseSha256Sums: 3,000 garbage inputs never throw and match the reference parser", () => {
  const rng = new Rng("parse-garbage");
  let accepted = 0;
  for (let trial = 0; trial < 3000; trial++) {
    const text = genGarbage(rng);
    const ctx = rng.ctx(trial);
    let got;
    assert.doesNotThrow(() => {
      got = parseSha256Sums(text);
    }, `${ctx} never throws on ${JSON.stringify(text)}`);
    assertParseInvariants(text, got, ctx);
    assert.deepEqual(mapEntries(got), mapEntries(refParse(text)), `${ctx} input ${JSON.stringify(text)}`);
    // Round trip: a parsed map, written back out, parses to itself.
    assert.deepEqual(
      mapEntries(parseSha256Sums(serialize(got))),
      mapEntries(got),
      `${ctx} serialize/parse round trip for ${JSON.stringify(text)}`,
    );
    accepted += got.size;
  }
  // Guard against a generator that only ever produces rejected lines.
  assert.ok(accepted > 100, `garbage corpus still produced accepted entries (${accepted})`);
});

test("parseSha256Sums: raw random bytes decoded as UTF-8 or latin1 never throw", () => {
  const rng = new Rng("parse-bytes");
  for (let trial = 0; trial < 500; trial++) {
    const buf = rng.bytes(rng.int(0, 512));
    for (const enc of ["utf8", "latin1"]) {
      const text = buf.toString(enc);
      let got;
      assert.doesNotThrow(() => {
        got = parseSha256Sums(text);
      }, `${rng.ctx(trial)} ${enc} bytes ${buf.toString("hex")}`);
      assertParseInvariants(text, got, rng.ctx(trial));
      assert.deepEqual(mapEntries(got), mapEntries(refParse(text)), `${rng.ctx(trial)} ${enc} bytes ${buf.toString("hex")}`);
    }
  }
});

test("parseSha256Sums: metamorphic properties (EOL, digest case, concatenation, padding)", () => {
  const rng = new Rng("parse-metamorphic");
  for (let trial = 0; trial < 1000; trial++) {
    const a = genSumsFile(rng);
    const b = genSumsFile(rng);
    const ctx = rng.ctx(trial);
    const lf = a.lines.map((l) => l.line).join("\n");
    const base = mapEntries(parseSha256Sums(lf));

    assert.deepEqual(mapEntries(parseSha256Sums(a.lines.map((l) => l.line).join("\r\n"))), base, `${ctx} CRLF equals LF`);
    assert.deepEqual(mapEntries(parseSha256Sums(`${lf}\n\n\r\n`)), base, `${ctx} trailing blank lines change nothing`);
    assert.deepEqual(
      mapEntries(parseSha256Sums(a.lines.map((l) => ` \t${l.line}\t `).join("\n"))),
      base,
      `${ctx} outer padding changes nothing`,
    );

    // Digest case never changes the result. Only fully-valid lines are re-cased,
    // so names (which are case-sensitive) stay untouched.
    const upper = a.lines.map((l) => (l.entry ? l.line.replace(/[0-9a-fA-F]{64}/, (h) => h.toUpperCase()) : l.line)).join("\n");
    assert.deepEqual(mapEntries(parseSha256Sums(upper)), base, `${ctx} uppercase digests normalize to the same map`);

    // Concatenation: later file overrides earlier file, key order is first-seen.
    const merged = new Map(a.expected);
    for (const [k, v] of b.expected) merged.set(k, v);
    const joined = `${lf}\n${b.lines.map((l) => l.line).join("\n")}`;
    assert.deepEqual(mapEntries(parseSha256Sums(joined)), mapEntries(merged), `${ctx} parse(a+b) = merge(parse(a), parse(b))`);
  }
});

test("parseSha256Sums: fixed edge cases", () => {
  const h = "0123456789abcdef".repeat(4);
  const H = h.toUpperCase();
  const cases = [
    ["", []],
    ["\n\r\n\n", []],
    [`${h}  a.gz`, [["a.gz", h]]],
    [`${H}  a.gz\r\n`, [["a.gz", h]]],
    [`${h} *a.gz`, [["a.gz", h]]],
    [`${h}\t\t*a.gz`, [["a.gz", h]]],
    [`${h}  ../evil`, [["../evil", h]]],
    [`${h}  *`, [["*", h]]],
    [`${h}  **`, [["*", h]]],
    [`${h}  * spaced`, [["spaced", h]]],
    [`${h}  a.gz  \t`, [["a.gz", h]]],
    [`﻿${h}  a.gz`, [["a.gz", h]]], // a UTF-8 BOM is whitespace to trim()
    [`${h}`, []],
    [`${h}  `, []],
    [`${h}a.gz`, []],
    [`${h.slice(0, 63)}  a.gz`, []],
    [`${h}0  a.gz`, []],
    [`${h.slice(0, 63)}g  a.gz`, []],
    [`# ${h}  a.gz`, []],
    [`${h}  a\rb`, []], // a bare CR is not a line break and not a name character
    [`${h}  a b`, []],
    [`0x${h}  a.gz`, []],
    [`${h}  a.gz\n${H.replace(/0/g, "F")}  a.gz`, [["a.gz", h.replace(/0/g, "f")]]], // last duplicate wins
    [`${h}  a.gz\n${h}  A.gz`, [["a.gz", h], ["A.gz", h]]], // names are case-sensitive
    [`${h}  __proto__\n${h}  constructor`, [["__proto__", h], ["constructor", h]]],
  ];
  for (const [text, want] of cases) {
    assert.deepEqual(mapEntries(parseSha256Sums(text)), want, `input ${JSON.stringify(text)}`);
    assert.deepEqual(mapEntries(refParse(text)), want, `reference parser on ${JSON.stringify(text)}`);
  }
  // Object-prototype names must not leak in as phantom entries.
  const empty = parseSha256Sums("");
  for (const key of ["__proto__", "constructor", "toString", "hasOwnProperty"]) {
    assert.equal(empty.get(key), undefined, `empty map has no "${key}"`);
  }
});

test("parseSha256Sums: hostile whitespace runs parse in linear time", () => {
  // `<64 hex><N blanks>a\rb` has a bare CR in the name, so it never matches.
  // A backtracking separator makes that rejection cost O(N^2): 32,000 blanks
  // took ~950 ms before the fix and under 1 ms after. The 400 ms budget sits
  // three orders of magnitude above the fixed cost.
  const h = "a".repeat(64);
  for (const [n, filler] of [[60000, " "], [60000, "\t"], [60000, " \t"]]) {
    const text = `${h}${filler.repeat(n / filler.length)}a\rb\n${h}  ok.gz\n`;
    const start = process.hrtime.bigint();
    const got = parseSha256Sums(text);
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    assert.deepEqual(mapEntries(got), [["ok.gz", h]]);
    assert.ok(ms < 400, `parse of ${n} separator chars took ${ms.toFixed(1)} ms (budget 400 ms)`);
  }
  // A long separator in a valid line still parses.
  assert.deepEqual(mapEntries(parseSha256Sums(`${h}${" ".repeat(100000)}*big.gz`)), [["big.gz", h]]);
});

// ---------------------------------------------------------------------------
// 2. verifyChecksum
// ---------------------------------------------------------------------------

// verifyChecksum logs one stderr line per success. Capture them so 1,000+
// trials stay quiet, and so the log content itself can be asserted.
function withCapturedStderr(fn) {
  const original = process.stderr.write;
  const lines = [];
  process.stderr.write = (chunk) => {
    lines.push(String(chunk));
    return true;
  };
  try {
    fn(lines);
  } finally {
    process.stderr.write = original;
  }
}

function refSha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

const ASSETS = [
  "claude-p-darwin-arm64.gz",
  "claude-p-darwin-x64.gz",
  "claude-p-linux-arm64.gz",
  "claude-p-linux-x64.gz",
];

// Payload sizes cover 0 B to 64 KiB, biased toward boundaries.
function payloadSize(rng, trial) {
  const fixed = [0, 1, 2, 55, 56, 63, 64, 65, 119, 120, 127, 128, 4095, 4096, 65535, 65536];
  if (trial < fixed.length) return fixed[trial];
  const k = rng.below(10);
  if (k < 4) return rng.int(0, 256);
  if (k < 8) return rng.int(257, 8192);
  return rng.int(8193, 65536);
}

// Build a multi-entry SHA256SUMS with `target` at a random line position.
function buildSums(rng, target, digest) {
  const eol = rng.bool() ? "\n" : "\r\n";
  const others = ASSETS.filter((a) => a !== target);
  const lines = [];
  const decoys = rng.int(0, 6);
  for (let i = 0; i < decoys; i++) {
    const k = rng.below(4);
    if (k === 0) lines.push(`# ${randHex(rng, 64)}  ${target}`); // commented-out wrong digest for the target
    else if (k === 1) lines.push("");
    else if (k === 2) lines.push(`${recase(rng, randHex(rng, 64))}  ${rng.pick(others)}`);
    else lines.push(`${recase(rng, randHex(rng, 64))} *decoy-${i}-${target}`); // name contains the target as a suffix
  }
  const entry = `${recase(rng, digest)}${blanks(rng, 1, 3)}${rng.bool() ? "*" : ""}${target}`;
  const position = rng.int(0, lines.length);
  lines.splice(position, 0, entry);
  return { text: lines.join(eol) + (rng.bool(0.8) ? eol : ""), position, lineCount: lines.length };
}

function assertChecksumError(fn, message) {
  assert.throws(fn, (err) => {
    assert.ok(err instanceof ChecksumError, `${message}: expected ChecksumError, got ${err && err.constructor.name}: ${err && err.message}`);
    assert.ok(err instanceof Error);
    return true;
  }, message);
}

test("sha256 agrees with node:crypto for 300 random buffers and the NIST vectors", () => {
  assert.equal(sha256(Buffer.alloc(0)), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert.equal(sha256(Buffer.from("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  const rng = new Rng("sha256");
  for (let trial = 0; trial < 300; trial++) {
    const buf = rng.bytes(rng.int(0, 2048));
    const got = sha256(buf);
    assert.match(got, /^[0-9a-f]{64}$/);
    assert.equal(got, refSha256(buf), rng.ctx(trial));
  }
});

test("verifyChecksum: 1,200 payloads (0 B to 64 KiB) verify, and every tamper is refused", () => {
  const rng = new Rng("verify-tamper");
  const sizes = { min: Infinity, max: 0 };
  let positions = 0;
  withCapturedStderr((logs) => {
    for (let trial = 0; trial < 1200; trial++) {
      const ctx = rng.ctx(trial);
      const size = payloadSize(rng, trial);
      sizes.min = Math.min(sizes.min, size);
      sizes.max = Math.max(sizes.max, size);
      const payload = rng.bytes(size);
      const pristine = Buffer.from(payload);
      const name = rng.pick(ASSETS);
      const digest = refSha256(payload);
      const sums = buildSums(rng, name, digest);
      if (sums.position > 0) positions++;
      const requireChecksum = rng.bool();

      // Matching payload always verifies, wherever its line sits.
      logs.length = 0;
      assert.doesNotThrow(
        () => verifyChecksum(payload, name, sums.text, requireChecksum),
        `${ctx} size=${size} line ${sums.position}/${sums.lineCount} sums=${JSON.stringify(sums.text)}`,
      );
      assert.equal(logs.length, 1, `${ctx} one log line per verification`);
      assert.ok(logs[0].includes(digest) && logs[0].includes(name), `${ctx} log names the asset and digest`);

      if (size > 0) {
        // Single bit flip at a random offset; first and last bytes get extra weight.
        const edge = rng.below(8);
        const offset = edge === 0 ? 0 : edge === 1 ? size - 1 : rng.below(size);
        const bit = rng.below(8);
        const flipped = Buffer.from(payload);
        flipped[offset] ^= 1 << bit;
        assertChecksumError(
          () => verifyChecksum(flipped, name, sums.text, requireChecksum),
          `${ctx} bit ${bit} flipped at byte ${offset} of ${size}`,
        );

        // Truncating one byte (or a random prefix) is refused.
        assertChecksumError(
          () => verifyChecksum(payload.subarray(0, size - 1), name, sums.text, requireChecksum),
          `${ctx} truncated by 1 byte from ${size}`,
        );
        const cut = rng.below(size);
        assertChecksumError(
          () => verifyChecksum(payload.subarray(0, cut), name, sums.text, requireChecksum),
          `${ctx} truncated to ${cut} of ${size} bytes`,
        );
        assertChecksumError(
          () => verifyChecksum(payload.subarray(1), name, sums.text, requireChecksum),
          `${ctx} first byte dropped from ${size}`,
        );
      }

      // Appending one byte (including a zero byte) is refused.
      const extra = rng.bool() ? 0 : rng.below(256);
      assertChecksumError(
        () => verifyChecksum(Buffer.concat([payload, Buffer.from([extra])]), name, sums.text, requireChecksum),
        `${ctx} appended byte 0x${extra.toString(16)} to ${size}`,
      );

      // Failures log nothing as "verified" and never mutate the payload.
      assert.equal(logs.length, 1, `${ctx} refused payloads are never logged as verified`);
      assert.ok(payload.equals(pristine), `${ctx} verifyChecksum does not mutate the payload`);
    }
  });
  assert.equal(sizes.min, 0, "payload sizes reached 0 B");
  assert.equal(sizes.max, 65536, "payload sizes reached 64 KiB");
  assert.ok(positions > 300, `target line sat past the first line in ${positions} trials`);
});

test("verifyChecksum: every single-bit flip of small payloads is refused (exhaustive)", () => {
  const rng = new Rng("verify-exhaustive");
  withCapturedStderr(() => {
    for (let trial = 0; trial < 40; trial++) {
      const size = rng.int(1, 48);
      const payload = rng.bytes(size);
      const name = rng.pick(ASSETS);
      const sums = `${refSha256(payload)}  ${name}\n`;
      verifyChecksum(payload, name, sums, true);
      for (let offset = 0; offset < size; offset++) {
        for (let bit = 0; bit < 8; bit++) {
          payload[offset] ^= 1 << bit;
          assertChecksumError(
            () => verifyChecksum(payload, name, sums, true),
            `${rng.ctx(trial)} size=${size} byte=${offset} bit=${bit}`,
          );
          payload[offset] ^= 1 << bit;
        }
      }
      verifyChecksum(payload, name, sums, true);
    }
  });
});

test("verifyChecksum: missing, unparseable, or foreign entries are refused (1,000 trials)", () => {
  const rng = new Rng("verify-missing");
  withCapturedStderr((logs) => {
    for (let trial = 0; trial < 1000; trial++) {
      const ctx = rng.ctx(trial);
      const payload = rng.bytes(rng.int(0, 1024));
      const other = rng.bytes(rng.int(0, 1024));
      if (payload.equals(other)) continue;
      const name = rng.pick(ASSETS);
      const otherName = rng.pick(ASSETS.filter((a) => a !== name));
      const digest = refSha256(payload);
      const otherDigest = refSha256(other);
      const eol = rng.bool() ? "\n" : "\r\n";
      const req = rng.bool();
      logs.length = 0;

      // The asset is not listed at all.
      const onlyOther = `${recase(rng, otherDigest)}  ${otherName}${eol}`;
      assertChecksumError(() => verifyChecksum(payload, name, onlyOther, req), `${ctx} asset not listed`);
      assertChecksumError(() => verifyChecksum(payload, name, "", req), `${ctx} empty SHA256SUMS`);
      assertChecksumError(() => verifyChecksum(payload, name, `${eol}# nothing here${eol}`, req), `${ctx} comment-only SHA256SUMS`);

      // The right digest is listed under a different name: near-miss names never match.
      const nearMiss = rng.pick([
        name.toUpperCase(),
        `${name}.sig`,
        `x${name}`,
        `./${name}`,
        `../${name}`,
        name.slice(0, -1),
        name.replace("-", "_"),
        `${name}\u0000`,
      ]);
      assertChecksumError(
        () => verifyChecksum(payload, name, `${digest}  ${nearMiss}${eol}`, req),
        `${ctx} digest listed under near-miss name ${JSON.stringify(nearMiss)}`,
      );

      // The asset's own line is malformed, so there is no usable entry.
      const broken = rng.pick([
        `${digest.slice(0, 63)}  ${name}`,
        `${digest}0  ${name}`,
        `${digest}${name}`,
        `# ${digest}  ${name}`,
        `${digest.slice(0, 20)}g${digest.slice(21)}  ${name}`,
        `${name}  ${digest}`,
        `SHA256 (${name}) = ${digest}`,
      ]);
      assertChecksumError(
        () => verifyChecksum(payload, name, `${onlyOther}${broken}${eol}`, req),
        `${ctx} malformed own line ${JSON.stringify(broken)}`,
      );

      // The asset is listed with another asset's valid digest (swapped entries).
      const swapped = [`${recase(rng, otherDigest)}  ${name}`, `${recase(rng, digest)}  ${otherName}`];
      if (rng.bool()) swapped.reverse();
      assertChecksumError(
        () => verifyChecksum(payload, name, swapped.join(eol) + eol, req),
        `${ctx} asset carries another asset's digest`,
      );
      // ...and that other asset's bytes do verify against the swapped file.
      assert.doesNotThrow(() => verifyChecksum(other, name, swapped.join(eol) + eol, req), `${ctx} swapped file verifies the other payload`);
      logs.length = 0;

      // A later duplicate line overrides an earlier correct one, and the reverse.
      const wrong = randHex(rng, 64);
      assertChecksumError(
        () => verifyChecksum(payload, name, `${digest}  ${name}${eol}${wrong}  ${name}${eol}`, req),
        `${ctx} later wrong duplicate wins`,
      );
      assert.doesNotThrow(
        () => verifyChecksum(payload, name, `${wrong}  ${name}${eol}${digest}  ${name}${eol}`, req),
        `${ctx} later correct duplicate wins`,
      );

      // Off-by-one-nibble digests are refused.
      const at = rng.below(64);
      const nibble = LOWER_HEX[(LOWER_HEX.indexOf(digest[at]) + 1 + rng.below(15)) % 16];
      const offByOne = `${digest.slice(0, at)}${nibble}${digest.slice(at + 1)}`;
      assert.notEqual(offByOne, digest);
      assertChecksumError(
        () => verifyChecksum(payload, name, `${recase(rng, offByOne)}  ${name}${eol}`, req),
        `${ctx} digest differs in nibble ${at}`,
      );
    }
  });
});

test("verifyChecksum: error messages and the no-SHA256SUMS policy", () => {
  const payload = Buffer.from("claude-p-test-binary");
  const name = "claude-p-darwin-arm64.gz";
  const digest = refSha256(payload);
  withCapturedStderr((logs) => {
    // SHA256SUMS absent: warn and allow, unless checksums are required.
    for (const absent of [null, undefined]) {
      logs.length = 0;
      assert.doesNotThrow(() => verifyChecksum(payload, name, absent, false));
      assert.doesNotThrow(() => verifyChecksum(payload, name, absent, undefined));
      assert.equal(logs.length, 2);
      assert.match(logs[0], /warning: SHA256SUMS not found/);
      assert.match(logs[0], /unverified/);
      assertChecksumError(() => verifyChecksum(payload, name, absent, true), "required checksum with no SHA256SUMS");
    }
    // An empty SHA256SUMS is present-but-empty: refused even when not required.
    assertChecksumError(() => verifyChecksum(payload, name, "", false), "empty string is not 'absent'");

    assert.throws(
      () => verifyChecksum(Buffer.from("tampered"), name, `${digest}  ${name}\n`, false),
      (err) =>
        err instanceof ChecksumError &&
        err.message.includes("SHA-256 mismatch") &&
        err.message.includes(name) &&
        err.message.includes(digest) &&
        err.message.includes(refSha256(Buffer.from("tampered"))),
    );
    assert.throws(
      () => verifyChecksum(payload, "claude-p-linux-x64.gz", `${digest}  ${name}\n`, false),
      (err) => err instanceof ChecksumError && err.message.includes("no entry for claude-p-linux-x64.gz"),
    );
  });
});

// ---------------------------------------------------------------------------
// 3. bin/claude-p.js launcher
// ---------------------------------------------------------------------------

// One POSIX stub stands in for the prebuilt binary. STUB_MODE selects behavior.
const STUB = `#!/bin/sh
case "$STUB_MODE" in
  exit)
    exit "$STUB_EXIT" ;;
  argv)
    printf '%s\\0' "$#"
    for a in "$@"; do printf '%s\\0' "$a"; done
    exit 0 ;;
  die)
    # Default disposition: the forwarded signal kills this process.
    echo ready
    exec sleep 30 ;;
  trap)
    sleep 30 &
    pid=$!
    trap 'kill $pid 2>/dev/null; echo "got:$STUB_SIGNAL"; exit "$STUB_EXIT"' "$STUB_SIGNAL"
    echo ready
    wait $pid
    exit 99 ;;
  selfkill)
    kill -"$STUB_SIGNAL" $$
    sleep 30 ;;
  *)
    exit 98 ;;
esac
`;

const posix = process.platform !== "win32";
const skip = posix ? false : "launcher stub is a POSIX shell script";

// Copy the launcher beside a stub `prebuilt/<platform>-<arch>/claude-p` in a
// fresh temp directory, run `fn`, and always remove the directory.
async function withLauncher(fn, { installStub = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claude-p-prop-"));
  try {
    fs.mkdirSync(path.join(dir, "bin"));
    const launcher = path.join(dir, "bin", "claude-p.js");
    fs.copyFileSync(launcherSource, launcher);
    if (installStub) {
      const prebuilt = path.join(dir, "prebuilt", `${process.platform}-${process.arch}`);
      fs.mkdirSync(prebuilt, { recursive: true });
      fs.writeFileSync(path.join(prebuilt, "claude-p"), STUB, { mode: 0o755 });
    }
    return await fn(launcher);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
    assert.equal(fs.existsSync(dir), false, "temp directory removed");
  }
}

const SIGNAL_NUMBERS = os.constants.signals;

// Launcher scenarios start when this module loads, so their child processes
// run while the CPU-bound parser and checksum tests hold the event loop. Each
// test awaits its scenario and reports its assertions. The no-op catch keeps
// an early rejection from surfacing as "unhandled" before its test awaits it.
function eager(fn) {
  if (skip) return null;
  const p = fn();
  p.catch(() => {});
  return p;
}

// Run the launcher. `onReady` fires once the stub prints "ready".
function runLauncher(launcher, args, env, { onReady } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [launcher, ...args], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const out = [];
    const err = [];
    let ready = false;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`launcher timed out; stdout=${Buffer.concat(out)} stderr=${Buffer.concat(err)}`));
    }, 30000);
    child.stdout.on("data", (c) => {
      out.push(c);
      if (!ready && onReady && Buffer.concat(out).includes("ready\n")) {
        ready = true;
        onReady(child);
      }
    });
    child.stderr.on("data", (c) => err.push(c));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout: Buffer.concat(out), stderr: Buffer.concat(err) });
    });
  });
}

const exitScenario = eager(async () => {
  const rng = new Rng("launcher-exit");
  const codes = [0, 1, 2, 42, 124, 130, 255];
  for (let i = 0; i < 5; i++) codes.push(rng.int(0, 255));
  // Seeded shuffle so launch order varies with the seed.
  for (let i = codes.length - 1; i > 0; i--) {
    const j = rng.below(i + 1);
    [codes[i], codes[j]] = [codes[j], codes[i]];
  }
  await withLauncher(async (launcher) => {
    const results = await Promise.all(
      codes.map((code) => runLauncher(launcher, [], { STUB_MODE: "exit", STUB_EXIT: String(code) })),
    );
    results.forEach((r, i) => {
      assert.equal(r.signal, null, `exit ${codes[i]}: launcher was not signalled`);
      assert.equal(r.code, codes[i], `exit ${codes[i]} forwarded; stderr=${r.stderr}`);
      assert.equal(r.stdout.length, 0);
      assert.equal(r.stderr.length, 0, `exit ${codes[i]}: launcher adds no stderr noise`);
    });
  });
});
test("launcher: exit codes are forwarded verbatim", { skip }, () => exitScenario);

const ARG_POOL = [
  "", "", " ", "  two  spaces  ", "-p", "--print", "--output-format", "stream-json", "--model=opus",
  "--", "-", "--flag with space", "a b c", "'single'", '"double"', "it's", 'say "hi"', "`backtick`",
  "$HOME", "$(echo pwned)", "${IFS}", "a;b", "a|b", "a&b", "a>b", "<in", "*", "?", "~", "!", "#",
  "back\\slash", "trail\\", "\\n", "line\nbreak", "tab\there", "cr\rhere", "\u001b[31mred\u001b[0m",
  "ünïcödé", "日本語のプロンプト", "🚀🔥", "é", "‮RTL", "﻿bom", "a b", "%s%d%n", "--help", "-v",
  "-e", "--eval", "--inspect", "=", "k=v=w",
];

function randArg(rng) {
  const k = rng.below(10);
  if (k < 6) return rng.pick(ARG_POOL);
  if (k < 8) {
    // Random printable ASCII, shell metacharacters included.
    let s = "";
    const n = rng.int(0, 40);
    for (let i = 0; i < n; i++) s += String.fromCharCode(rng.int(0x20, 0x7e));
    return s;
  }
  if (k === 8) {
    // Random Unicode scalar values (no NUL, no surrogates).
    let s = "";
    const n = rng.int(1, 12);
    for (let i = 0; i < n; i++) {
      let cp = rng.int(1, 0x1ffff);
      if (cp >= 0xd800 && cp <= 0xdfff) cp += 0x1000;
      s += String.fromCodePoint(cp);
    }
    return s;
  }
  return "x".repeat(rng.int(1000, 6000)); // long prompt-sized argument
}

const argvScenario = eager(async () => {
  const rng = new Rng("launcher-argv");
  const argvs = [
    [],
    [""],
    ["", "", ""],
    ["-p", "hello world", "--output-format", "json"],
    [...ARG_POOL],
  ];
  while (argvs.length < 16) {
    const argv = [];
    const n = rng.int(0, 12);
    for (let i = 0; i < n; i++) argv.push(randArg(rng));
    argvs.push(argv);
  }
  await withLauncher(async (launcher) => {
    const results = await Promise.all(argvs.map((argv) => runLauncher(launcher, argv, { STUB_MODE: "argv" })));
    results.forEach((r, i) => {
      const argv = argvs[i];
      const ctx = `[launcher-argv seed=${BASE_SEED} case=${i}] argv=${JSON.stringify(argv)}`;
      assert.equal(r.code, 0, `${ctx} stderr=${r.stderr}`);
      assert.equal(r.stderr.length, 0, ctx);
      // Expected wire format: "<argc>\0" then each argument's UTF-8 bytes + "\0".
      const want = Buffer.concat([String(argv.length), ...argv].map((a) => Buffer.concat([Buffer.from(a, "utf8"), Buffer.from([0])])));
      assert.ok(r.stdout.equals(want), `${ctx}\n got ${r.stdout.toString("hex")}\nwant ${want.toString("hex")}`);
    });
  });
});
test("launcher: argv arrives byte-for-byte unchanged (16 randomized argv arrays)", { skip }, () => argvScenario);

const signalScenario = eager(async () => {
  const rng = new Rng("launcher-signal");
  await withLauncher(async (launcher) => {
    const runs = [];
    for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
      // Child keeps the default disposition: it dies by the signal, and the
      // launcher re-raises that signal on itself.
      runs.push(
        runLauncher(launcher, [], { STUB_MODE: "die" }, { onReady: (c) => c.kill(sig) }).then((r) => {
          assert.equal(r.signal, sig, `${sig}: launcher terminates by the same signal; code=${r.code} stderr=${r.stderr}`);
          assert.equal(r.code, null);
          assert.equal(r.stdout.toString(), "ready\n");
        }),
      );
      // Child traps the signal and exits with its own code: the trap output
      // proves delivery, and the launcher reports the child's code.
      const exit = rng.int(3, 97);
      const short = sig.slice(3);
      runs.push(
        runLauncher(
          launcher,
          [],
          { STUB_MODE: "trap", STUB_SIGNAL: short, STUB_EXIT: String(exit) },
          { onReady: (c) => c.kill(sig) },
        ).then((r) => {
          assert.equal(r.stdout.toString(), `ready\ngot:${short}\n`, `${sig}: child's trap ran; stderr=${r.stderr}`);
          assert.equal(r.signal, null, `${sig}: launcher survives when the child handles the signal`);
          assert.equal(r.code, exit, `${sig}: child's exit code ${exit} forwarded`);
        }),
      );
      // Child dies by a signal nobody sent the launcher: same termination signal.
      runs.push(
        runLauncher(launcher, [], { STUB_MODE: "selfkill", STUB_SIGNAL: short }).then((r) => {
          assert.equal(r.signal, sig, `${sig}: child's own signal death is mirrored; code=${r.code}`);
          assert.ok(SIGNAL_NUMBERS[sig] > 0);
        }),
      );
    }
    await Promise.all(runs);
  });
});
test("launcher: SIGINT, SIGTERM and SIGHUP are forwarded to the child", { skip }, () => signalScenario);

const missingScenario = eager(() =>
  withLauncher(
    async (launcher) => {
      const r = await runLauncher(launcher, ["-p", "hi"], {});
      assert.equal(r.signal, null);
      assert.equal(r.code, 2, `stderr=${r.stderr}`);
      assert.match(r.stderr.toString(), /^claude-p: .*ENOENT/m);
      assert.match(r.stderr.toString(), /npm install claude-p/);
      assert.equal(r.stdout.length, 0);
    },
    { installStub: false },
  ),
);
test("launcher: missing binary exits 2 with install guidance", { skip }, () => missingScenario);
