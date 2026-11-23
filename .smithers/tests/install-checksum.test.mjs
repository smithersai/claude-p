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
