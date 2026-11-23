#!/usr/bin/env node
// Postinstall: download the prebuilt `claude-p` binary for the current
// platform/arch from a GitHub release and drop it into prebuilt/<plat>-<arch>/.
//
// Strategy:
//   1. If a binary already exists at the expected path (e.g. installed from
//      cache or a previous run), do nothing.
//   2. Otherwise, try `prebuilt/<plat>-<arch>/claude-p` shipped in the
//      package (publishers can pre-bundle for the most common targets).
//   3. Failing that, download from
//      https://github.com/smithersai/claude-p/releases/download/v<version>/claude-p-<plat>-<arch>.gz
//      verify its SHA-256 against SHA256SUMS from the same release, gunzip,
//      and write it with mode 0755.
//
// Checksums:
//   - SHA256SUMS present and the digest matches  -> install.
//   - SHA256SUMS present and the digest mismatches (or the asset is not
//     listed) -> hard fail: nothing is written and the install exits 1.
//   - SHA256SUMS missing (HTTP 404; releases before v0.1.3) -> warn and
//     install, unless CLAUDE_P_REQUIRE_CHECKSUM=1, which makes it a hard fail.
//
// If `CLAUDE_P_SKIP_DOWNLOAD=1` is set, exit 0 without doing anything (useful
// for monorepo bootstraps where the binary is provided out-of-band).

const fs = require("node:fs");
const path = require("node:path");
const https = require("node:https");
const zlib = require("node:zlib");
const crypto = require("node:crypto");

const pkg = require("../package.json");

function log(msg) {
  process.stderr.write(`claude-p (install): ${msg}\n`);
}

function platformDir() {
  return `${process.platform}-${process.arch}`;
}

function exeName() {
  return process.platform === "win32" ? "claude-p.exe" : "claude-p";
}

function targetPath() {
  return path.join(__dirname, "..", "prebuilt", platformDir(), exeName());
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function alreadyInstalled() {
  try {
    const stat = fs.statSync(targetPath());
    return stat.isFile() && stat.size > 0;
  } catch {
    return false;
  }
}

function isSupported() {
  const okPlatform = ["darwin", "linux"].includes(process.platform);
  const okArch = ["x64", "arm64"].includes(process.arch);
  return okPlatform && okArch;
}

function get(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        if (
          res.statusCode &&
          res.statusCode >= 300 &&
          res.statusCode < 400 &&
          res.headers.location
        ) {
          // Follow redirect (GitHub release assets do this).
          resolve(get(res.headers.location));
          return;
        }
        if (res.statusCode !== 200) {
          res.resume();
          const err = new Error(`HTTP ${res.statusCode} for ${url}`);
          err.statusCode = res.statusCode;
          reject(err);
          return;
        }
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

// Integrity failures abort the install instead of degrading to "no binary".
class ChecksumError extends Error {}

const RELEASE_BASE = `https://github.com/smithersai/claude-p/releases/download/v${pkg.version}`;

function assetName() {
  return `claude-p-${platformDir()}.gz`;
}

// Parse `<sha256>  <name>` lines (sha256sum text or binary `*name` mode).
function parseSha256Sums(text) {
  const sums = new Map();
  for (const line of text.split(/\r?\n/)) {
    const m = line.trim().match(/^([0-9a-fA-F]{64})\s+\*?(.+)$/);
    if (m) sums.set(m[2].trim(), m[1].toLowerCase());
  }
  return sums;
}

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

// Throws ChecksumError unless `gz` is safe to install. `sumsText` is null
// when the release has no SHA256SUMS.
function verifyChecksum(gz, name, sumsText, requireChecksum) {
  if (sumsText == null) {
    if (requireChecksum) {
      throw new ChecksumError(
        `SHA256SUMS not found for v${pkg.version} and CLAUDE_P_REQUIRE_CHECKSUM=1`,
      );
    }
    log(`warning: SHA256SUMS not found for v${pkg.version}; installing ${name} unverified`);
    return;
  }
  const expected = parseSha256Sums(sumsText).get(name);
  if (!expected) {
    throw new ChecksumError(`SHA256SUMS for v${pkg.version} has no entry for ${name}`);
  }
  const actual = sha256(gz);
  if (actual !== expected) {
    throw new ChecksumError(
      `SHA-256 mismatch for ${name}: expected ${expected}, got ${actual}`,
    );
  }
  log(`verified ${name} sha256 ${actual}`);
}

async function fetchSha256Sums() {
  const url = `${RELEASE_BASE}/SHA256SUMS`;
  try {
    return (await get(url)).toString("utf8");
  } catch (err) {
    if (err.statusCode === 404) return null;
    throw err;
  }
}

async function download() {
  const name = assetName();
  const url = `${RELEASE_BASE}/${name}`;
  log(`downloading ${url}`);
  const [gz, sumsText] = await Promise.all([get(url), fetchSha256Sums()]);
  verifyChecksum(gz, name, sumsText, process.env.CLAUDE_P_REQUIRE_CHECKSUM === "1");
  const bin = zlib.gunzipSync(gz);
  const dest = targetPath();
  ensureDir(path.dirname(dest));
  fs.writeFileSync(dest, bin, { mode: 0o755 });
  log(`installed ${dest} (${bin.length} bytes)`);
}

async function main() {
  if (process.env.CLAUDE_P_SKIP_DOWNLOAD === "1") {
    log("CLAUDE_P_SKIP_DOWNLOAD set; skipping");
    return;
  }
  if (!isSupported()) {
    log(`platform ${platformDir()} not supported; skipping`);
    return;
  }
  if (alreadyInstalled()) {
    log(`already installed at ${targetPath()}`);
    return;
  }
  try {
    await download();
  } catch (err) {
    if (err instanceof ChecksumError) {
      log(`checksum verification failed: ${err.message}`);
      log("refusing to install an unverified binary");
      process.exitCode = 1;
      return;
    }
    log(`download failed: ${err.message}`);
    log("you can build from source with: zig build -Doptimize=ReleaseSafe");
    // Don't fail the install — leave the binary missing; the shim will
    // print a clear error if the user runs `claude-p` later.
  }
}

module.exports = { parseSha256Sums, verifyChecksum, sha256, ChecksumError };

if (require.main === module) {
  main().catch((err) => {
    log(`unexpected error: ${err.stack || err.message}`);
    // Same as above: don't break the npm install.
  });
}
