import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const inst = require(path.join(repoRoot, "scripts", "install.js"));

test("parseSha256Sums parses standard sha256sum lines", () => {
  const data = Buffer.from("claude-p-test-binary");
  const digest = crypto.createHash("sha256").update(data).digest("hex");
  const text = `${digest}  claude-p-darwin-arm64.gz\n# comment\n\n${"0".repeat(64)}  claude-p-linux-x64.gz\n`;
  const map = inst.parseSha256Sums(text);
  assert.equal(map.get("claude-p-darwin-arm64.gz"), digest);
  assert.equal(map.get("claude-p-linux-x64.gz"), "0".repeat(64));
});

test("verifyChecksum accepts matching digest and rejects tampering or missing entries", () => {
  const data = Buffer.from("claude-p-test-binary");
  const digest = crypto.createHash("sha256").update(data).digest("hex");
  const sums = `${digest}  claude-p-darwin-arm64.gz\n`;

  assert.doesNotThrow(() => inst.verifyChecksum(data, "claude-p-darwin-arm64.gz", sums));
  assert.throws(
    () => inst.verifyChecksum(Buffer.from("tampered"), "claude-p-darwin-arm64.gz", sums),
    inst.ChecksumError,
  );
  assert.throws(
    () => inst.verifyChecksum(data, "claude-p-linux-x64.gz", sums),
    inst.ChecksumError,
  );
});

test("publish.mjs --check-versions verifies LICENSE and version alignment", () => {
  const out = execFileSync(
    process.execPath,
    [path.join(repoRoot, "scripts", "publish.mjs"), "--check-versions"],
    { cwd: repoRoot, encoding: "utf8" },
  );
  assert.match(out, /versions agree/);
});

// Install invariants (H14, M23, M24, L03, L8). The property suite in
// tests/prop/js_supplychain_prop.mjs covers each one with randomized trials.

import fs from "node:fs";
import os from "node:os";
import zlib from "node:zlib";

const PLAT = `${process.platform}-${process.arch}`;
const ASSET = `claude-p-${PLAT}.gz`;
const version = JSON.parse(fs.readFileSync(path.join(repoRoot, "package.json"), "utf8")).version;
const hex = (b) => crypto.createHash("sha256").update(b).digest("hex");
const quiet = async (fn) => {
  const w = process.stderr.write;
  process.stderr.write = () => true;
  try {
    return await fn();
  } finally {
    process.stderr.write = w;
  }
};
const serve = (files, calls) => async (url) => {
  calls.push(String(url));
  const name = String(url).split("/").pop();
  if (files[name]) return files[name];
  throw Object.assign(new Error(`HTTP 404 for ${url}`), { statusCode: 404 });
};

async function withRoot(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claude-p-smithers-"));
  try {
    return await fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test("H14: an existing binary is reused only on an exact binSha256 match", async () => {
  await withRoot(async (dir) => {
    const bin = Buffer.from("#!/bin/sh\necho ok\n");
    const gz = zlib.gzipSync(bin);
    const manifest = { version, assets: { [ASSET]: hex(gz) }, binSha256: { [PLAT]: hex(bin) } };
    fs.writeFileSync(path.join(dir, "checksums.json"), JSON.stringify(manifest));
    const dest = path.join(dir, "prebuilt", PLAT, "claude-p");
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, "#!/bin/sh\necho tampered\n", { mode: 0o755 });
    const calls = [];
    await quiet(() => inst.install({ root: dir, version, fetch: serve({ [ASSET]: gz }, calls) }));
    assert.equal(calls.length, 1, "tampered executable is not reused");
    assert.ok(fs.readFileSync(dest).equals(bin));
    calls.length = 0;
    await quiet(() => inst.install({ root: dir, version, fetch: serve({ [ASSET]: gz }, calls) }));
    assert.equal(calls.length, 0, "verified executable is reused");
    assert.equal(inst.existingInstallOk(dest, null), false, "no manifest, no reuse");
  });
});

test("M23: a symlinked prebuilt/ directory is refused", async () => {
  await withRoot(async (dir) => {
    const victim = path.join(dir, "victim");
    fs.mkdirSync(victim);
    const root = path.join(dir, "pkg");
    fs.mkdirSync(root);
    fs.symlinkSync(victim, path.join(root, "prebuilt"));
    assert.throws(() => inst.prepareInstallDir(root), inst.UnsafePathError);
    assert.deepEqual(fs.readdirSync(victim), []);
  });
});

test("M24: get() ends at the overall deadline", async () => {
  const { EventEmitter } = await import("node:events");
  const hang = () => Object.assign(new EventEmitter(), { destroy() {} });
  await assert.rejects(inst.get("https://github.com/x", { request: hang, deadline: inst.monotonicNow() + 30 }), /deadline/);
});

test("L03: a failed rename leaves no staging file of ours", async () => {
  await withRoot(async (dir) => {
    const dest = path.join(dir, "claude-p");
    assert.throws(() => inst.writeAtomic(dest, Buffer.from("x"), { rename: () => { throw new Error("boom"); } }), /boom/);
    assert.deepEqual(fs.readdirSync(dir), []);
  });
});

test("L8: ChecksumError exits 1; offline exits 0 unless CLAUDE_P_STRICT_INSTALL=1", async () => {
  const fail = (err) => async () => { throw err; };
  const offline = () => Object.assign(new Error("getaddrinfo ENOTFOUND github.com"), { code: "ENOTFOUND" });
  await quiet(async () => {
    assert.equal(await inst.main({ env: {}, supported: true, run: fail(new inst.ChecksumError("x")) }), 1);
    assert.equal(await inst.main({ env: {}, supported: true, run: fail(offline()) }), 0);
    assert.equal(await inst.main({ env: { CLAUDE_P_STRICT_INSTALL: "1" }, supported: true, run: fail(offline()) }), 1);
  });
});

test("D21: local filesystem errors exit 1, never the offline exit 0", async () => {
  const fail = (code) => async () => { throw Object.assign(new Error(`${code}: write failed`), { code }); };
  await quiet(async () => {
    for (const code of ["ENOSPC", "EACCES", "EPERM", "EISDIR", "EROFS"]) {
      assert.equal(await inst.main({ env: {}, supported: true, run: fail(code) }), 1, code);
    }
    assert.equal(await inst.main({ env: {}, supported: true, run: async () => { throw new Error("unclassified"); } }), 1);
  });
});

test("D21: ENOSPC while writing the binary exits 1 through the real installer", async () => {
  await withRoot(async (dir) => {
    const bin = Buffer.from("#!/bin/sh\necho ok\n");
    const gz = zlib.gzipSync(bin);
    fs.writeFileSync(path.join(dir, "checksums.json"), JSON.stringify({ version, assets: { [ASSET]: hex(gz) }, binSha256: { [PLAT]: hex(bin) } }));
    const writeSync = fs.writeSync;
    fs.writeSync = () => { throw Object.assign(new Error("ENOSPC: no space left on device"), { code: "ENOSPC" }); };
    let code;
    try {
      code = await quiet(() => inst.main({ env: {}, supported: true, run: () => inst.install({ root: dir, version, fetch: serve({ [ASSET]: gz }, []) }) }));
    } finally {
      fs.writeSync = writeSync;
    }
    assert.equal(code, 1);
    assert.deepEqual(fs.readdirSync(path.join(dir, "prebuilt", PLAT)), [], "no staging file or binary left");
  });
});

test("D21: an incomplete checksums.json fails before reuse or download", async () => {
  await withRoot(async (dir) => {
    const bin = Buffer.from("#!/bin/sh\necho ok\n");
    const gz = zlib.gzipSync(bin);
    for (const manifest of [
      { version, assets: { [ASSET]: hex(gz) } },
      { version, assets: {}, binSha256: { [PLAT]: hex(bin) } },
    ]) {
      fs.writeFileSync(path.join(dir, "checksums.json"), JSON.stringify(manifest));
      const calls = [];
      await quiet(() => assert.rejects(inst.install({ root: dir, version, fetch: serve({ [ASSET]: gz }, calls) }), inst.ChecksumError));
      assert.equal(calls.length, 0, JSON.stringify(manifest));
    }
  });
});

test("D06: a rejected existing binary is unlinked before an offline exit 0", async () => {
  await withRoot(async (dir) => {
    const bin = Buffer.from("#!/bin/sh\necho ok\n");
    const gz = zlib.gzipSync(bin);
    fs.writeFileSync(path.join(dir, "checksums.json"), JSON.stringify({ version, assets: { [ASSET]: hex(gz) }, binSha256: { [PLAT]: hex(bin) } }));
    const dest = path.join(dir, "prebuilt", PLAT, "claude-p");
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, "#!/bin/sh\necho stale\n", { mode: 0o755 });
    const offline = async () => { throw Object.assign(new Error("getaddrinfo ENOTFOUND github.com"), { code: "ENOTFOUND" }); };
    const code = await quiet(() => inst.main({ env: {}, supported: true, run: () => inst.install({ root: dir, version, fetch: offline }) }));
    assert.equal(code, 0, "offline stays a soft failure");
    assert.equal(fs.existsSync(dest), false, "rejected binary removed");
  });
});
