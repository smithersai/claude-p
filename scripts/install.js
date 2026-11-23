#!/usr/bin/env node
// Postinstall: download the prebuilt `claude-p` binary for the current
// platform/arch from a GitHub release, verify it, and install it at
// prebuilt/<plat>-<arch>/claude-p.
//
// Trust root:
//   1. checksums.json in the package root (written by scripts/publish.mjs
//      before `npm publish`, so the npm tarball and its provenance
//      attestation authenticate the per-platform SHA-256 digests). When it
//      exists it is the ONLY source of truth: a missing entry or a mismatch
//      is a hard failure. SHA256SUMS is not consulted.
//   2. No checksums.json (source checkout): fetch SHA256SUMS from the same
//      GitHub release. For versions >= 0.1.3 it is required; an HTTP 404 is
//      a hard failure, never a silent downgrade to "unverified".
//      CLAUDE_P_REQUIRE_CHECKSUM=1 also requires it for older versions.
//
// Download hardening: https only, hosts github.com and *.githubusercontent.com,
// at most 5 redirects, 30 s socket inactivity timeout, one 30 s overall
// monotonic deadline per install (DNS, connect, redirects, and body), 32 MiB
// compressed and 64 MiB decompressed caps.
//
// Filesystem hardening: the package root, prebuilt/, and
// prebuilt/<plat>-<arch>/ must be real directories (lstat; symlinks are
// refused). The binary is staged at a random <dest>.tmp.<pid>.<hex> created
// with O_CREAT|O_EXCL|O_NOFOLLOW, written and fchmod-ed to 0755 through that
// fd, and renamed into place. Only a staging file this process created is
// ever unlinked. A symlink or non-file at the destination is refused.
//
// Manifest entries: when checksums.json exists it must record both the
// gzip `assets` digest and the raw `binSha256` digest for this platform. A
// missing entry is a ChecksumError before any reuse check or download.
//
// Reuse: an existing binary is reused only when checksums.json records a
// `binSha256` for this platform and the file is a regular, executable file no
// larger than 64 MiB whose SHA-256 (hashed through the opened fd) matches
// exactly. Otherwise the rejected file is unlinked before the download starts,
// so a later offline exit 0 never leaves an unverified executable behind for
// bin/claude-p.js to run. The new binary is downloaded, verified, and
// atomically renamed into place.
//
// Exit codes: 0 on success or when skipped. 1 on any integrity failure
// (ChecksumError: digest mismatch, missing entry, missing SHA256SUMS, bad
// gzip), unsafe install path (UnsafePathError), or local filesystem error
// (ENOSPC, EACCES, EPERM, EROFS, ...). Only a connectivity failure
// (NetworkError: DNS, offline, refused or reset connection, HTTP error,
// timeout, deadline) prints a warning and exits 0 so that `npm install`
// succeeds offline; CLAUDE_P_STRICT_INSTALL=1 makes it exit 1.
// CLAUDE_P_SKIP_DOWNLOAD=1 skips everything (for monorepo bootstraps where
// the binary is provided out-of-band, or proxy-only networks).

const fs = require("node:fs");
const path = require("node:path");
const https = require("node:https");
const zlib = require("node:zlib");
const crypto = require("node:crypto");

const pkg = require("../package.json");

const PKG_ROOT = path.join(__dirname, "..");
const MAX_REDIRECTS = 5;
const REQUEST_TIMEOUT_MS = 30_000;
const DOWNLOAD_DEADLINE_MS = 30_000;
const MAX_COMPRESSED_BYTES = 32 * 1024 * 1024;
const MAX_BINARY_BYTES = 64 * 1024 * 1024;

function log(msg) {
  process.stderr.write(`claude-p (install): ${msg}\n`);
}

function platformDir() {
  return `${process.platform}-${process.arch}`;
}

function targetPath(root = PKG_ROOT) {
  return path.join(root, "prebuilt", platformDir(), "claude-p");
}

function isSupported() {
  return ["darwin", "linux"].includes(process.platform) && ["x64", "arm64"].includes(process.arch);
}

// Integrity failures abort the install instead of degrading to "no binary".
class ChecksumError extends Error {}

// A symlinked or non-directory install path. Fatal like ChecksumError.
class UnsafePathError extends Error {}

// A connectivity failure: the only error class main() may soften to exit 0.
class NetworkError extends Error {}

// Socket and DNS error codes that mean "could not reach the release host".
const CONNECTIVITY_CODES = new Set([
  "ENOTFOUND",
  "EAI_AGAIN",
  "ECONNREFUSED",
  "ECONNRESET",
  "ECONNABORTED",
  "ETIMEDOUT",
  "EHOSTUNREACH",
  "EHOSTDOWN",
  "ENETUNREACH",
  "ENETDOWN",
  "EPIPE",
  "ABORT_ERR",
]);

// True only for errors classified as connectivity failures. Local
// filesystem errors (ENOSPC, EACCES, EPERM, EISDIR, EROFS, ...), integrity
// errors, and unclassified errors are never connectivity failures.
function isConnectivityError(err) {
  if (!err || err instanceof ChecksumError || err instanceof UnsafePathError) return false;
  if (err instanceof NetworkError) return true;
  if (typeof err.statusCode === "number") return true;
  if (err.name === "AbortError") return true;
  return typeof err.code === "string" && CONNECTIVITY_CODES.has(err.code);
}

function networkError(message, extra = {}) {
  return Object.assign(new NetworkError(message), extra);
}

// Monotonic milliseconds; immune to wall-clock jumps.
function monotonicNow() {
  return Number(process.hrtime.bigint() / 1_000_000n);
}

function releaseBase(version = pkg.version) {
  return `https://github.com/smithersai/claude-p/releases/download/v${version}`;
}

function assetName() {
  return `claude-p-${platformDir()}.gz`;
}

// ---------------------------------------------------------------------------
// Checksum policy
// ---------------------------------------------------------------------------

// SHA256SUMS ships with every release from v0.1.3 on.
function checksumRequiredFor(version) {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(version));
  if (!m) return true;
  const [maj, min, pat] = m.slice(1).map(Number);
  if (maj !== 0) return maj > 0;
  if (min !== 1) return min > 1;
  return pat >= 3;
}

function requireChecksumDefault(version = pkg.version, env = process.env) {
  return env.CLAUDE_P_REQUIRE_CHECKSUM === "1" || checksumRequiredFor(version);
}

// Parse `<sha256>  <name>` lines (sha256sum text or binary `*name` mode).
function parseSha256Sums(text) {
  const sums = new Map();
  for (const line of text.split(/\r?\n/)) {
    // `(?!\s)` pins the separator to the whole whitespace run. Without it a
    // line that cannot match re-scans the name once per separator character,
    // which is quadratic in a hostile SHA256SUMS line.
    const m = line.trim().match(/^([0-9a-fA-F]{64})\s+(?!\s)\*?(.+)$/);
    if (m) sums.set(m[2].trim(), m[1].toLowerCase());
  }
  return sums;
}

function sha256(buf) {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function compareDigest(gz, name, expected, source) {
  const actual = sha256(gz);
  if (actual !== expected) {
    throw new ChecksumError(`SHA-256 mismatch for ${name}: expected ${expected}, got ${actual} (${source})`);
  }
  log(`verified ${name} sha256 ${actual} (${source})`);
}

// Throws ChecksumError unless `gz` matches SHA256SUMS. `sumsText` is null or
// undefined when the release has no SHA256SUMS; that is only tolerated when
// `requireChecksum` is explicitly false. When `requireChecksum` is undefined
// the version policy decides (required for >= 0.1.3).
function verifyChecksum(gz, name, sumsText, requireChecksum) {
  const required = requireChecksum === undefined ? requireChecksumDefault() : requireChecksum;
  if (sumsText == null) {
    if (required) {
      throw new ChecksumError(`SHA256SUMS not found for v${pkg.version}; refusing to install ${name} unverified`);
    }
    log(`warning: SHA256SUMS not found for v${pkg.version}; installing ${name} unverified`);
    return;
  }
  const expected = parseSha256Sums(sumsText).get(name);
  if (!expected) {
    throw new ChecksumError(`SHA256SUMS for v${pkg.version} has no entry for ${name}`);
  }
  compareDigest(gz, name, expected, "SHA256SUMS");
}

// Parse and validate a bundled checksums.json manifest.
function parseChecksumsManifest(text, version = pkg.version) {
  let data;
  try {
    data = JSON.parse(text);
  } catch (err) {
    throw new ChecksumError(`checksums.json is not valid JSON: ${err.message}`);
  }
  if (!data || typeof data !== "object" || typeof data.assets !== "object" || data.assets === null) {
    throw new ChecksumError("checksums.json has no `assets` object");
  }
  if (data.version !== version) {
    throw new ChecksumError(`checksums.json is for v${data.version}, package is v${version}`);
  }
  for (const [name, digest] of Object.entries(data.assets)) {
    if (typeof digest !== "string" || !/^[0-9a-f]{64}$/.test(digest)) {
      throw new ChecksumError(`checksums.json has an invalid digest for ${name}`);
    }
  }
  return data;
}

// Throws ChecksumError unless `gz` matches the bundled manifest entry.
function verifyBundled(gz, name, manifest) {
  const expected = Object.prototype.hasOwnProperty.call(manifest.assets, name) ? manifest.assets[name] : undefined;
  if (!expected) {
    throw new ChecksumError(`checksums.json for v${manifest.version} has no entry for ${name}`);
  }
  compareDigest(gz, name, expected, "checksums.json");
}

// Returns the parsed manifest, or null when the package ships none.
function loadBundledChecksums(root = PKG_ROOT, version = pkg.version) {
  let text;
  try {
    text = fs.readFileSync(path.join(root, "checksums.json"), "utf8");
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
  return parseChecksumsManifest(text, version);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function assertAllowedUrl(url) {
  const u = url instanceof URL ? url : new URL(url);
  if (u.protocol !== "https:") throw new Error(`refusing non-https URL ${u.href}`);
  const host = u.hostname.toLowerCase();
  if (host !== "github.com" && !host.endsWith(".githubusercontent.com")) {
    throw new Error(`refusing download host ${host}`);
  }
  return u;
}

// GET `url` into a Buffer. `request` and `now` are injectable for tests.
//
// `deadline` is an absolute monotonic time (ms, from `now()`) shared by every
// redirect hop; when absent it is now() + DOWNLOAD_DEADLINE_MS. A timer and
// an AbortSignal end DNS, connect, headers, and body at the deadline, so a
// server that trickles bytes under the inactivity timeout still cannot stall
// the install.
function get(
  url,
  { maxBytes = MAX_COMPRESSED_BYTES, request = https.get, redirects = 0, deadline, now = monotonicNow } = {},
) {
  const end = deadline === undefined ? now() + DOWNLOAD_DEADLINE_MS : deadline;
  return new Promise((resolve, reject) => {
    let u;
    try {
      u = assertAllowedUrl(url);
    } catch (err) {
      reject(err);
      return;
    }
    const remaining = end - now();
    if (remaining <= 0) {
      reject(networkError(`download deadline exceeded before fetching ${u.href}`));
      return;
    }
    let settled = false;
    let req = null;
    let res = null;
    const ac = new AbortController();
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(value);
    };
    const fail = (err) => finish(reject, err);
    const timer = setTimeout(() => {
      const err = networkError(`download deadline of ${DOWNLOAD_DEADLINE_MS} ms exceeded fetching ${u.href}`);
      fail(err);
      ac.abort(err);
      if (res) res.destroy(err);
      if (req) req.destroy(err);
    }, remaining);
    try {
      req = request(u, { timeout: REQUEST_TIMEOUT_MS, signal: ac.signal }, (r) => {
        res = r;
        const status = res.statusCode || 0;
        if (status >= 300 && status < 400 && res.headers.location) {
          res.resume();
          res.destroy();
          if (redirects >= MAX_REDIRECTS) {
            fail(networkError(`too many redirects fetching ${url}`));
            return;
          }
          let next;
          try {
            next = new URL(res.headers.location, u);
          } catch {
            fail(networkError(`bad redirect Location from ${u.href}`));
            return;
          }
          finish(resolve, get(next, { maxBytes, request, redirects: redirects + 1, deadline: end, now }));
          return;
        }
        if (status !== 200) {
          res.resume();
          res.destroy();
          fail(networkError(`HTTP ${status} for ${u.href}`, { statusCode: status }));
          return;
        }
        const declared = Number(res.headers["content-length"]);
        if (Number.isFinite(declared) && declared > maxBytes) {
          res.destroy();
          fail(new Error(`${u.href} is ${declared} bytes, over the ${maxBytes}-byte limit`));
          return;
        }
        const chunks = [];
        let total = 0;
        res.on("data", (c) => {
          if (settled) return;
          total += c.length;
          if (total > maxBytes) {
            res.destroy();
            fail(new Error(`${u.href} exceeded the ${maxBytes}-byte limit`));
            return;
          }
          chunks.push(c);
        });
        res.on("end", () => finish(resolve, Buffer.concat(chunks)));
        res.on("error", fail);
      });
    } catch (err) {
      fail(err);
      return;
    }
    req.on("timeout", () => req.destroy(networkError(`timed out after ${REQUEST_TIMEOUT_MS} ms of inactivity fetching ${u.href}`)));
    req.on("error", fail);
  });
}

// Returns SHA256SUMS text, or null on 404 when checksums are not required.
// A 404 when they are required is a ChecksumError, never a downgrade.
async function fetchSha256Sums({
  version = pkg.version,
  required = requireChecksumDefault(version),
  fetch = get,
  deadline,
} = {}) {
  const url = `${releaseBase(version)}/SHA256SUMS`;
  try {
    return (await fetch(url, { maxBytes: 64 * 1024, deadline })).toString("utf8");
  } catch (err) {
    if (err.statusCode === 404) {
      if (required) {
        throw new ChecksumError(`SHA256SUMS missing (HTTP 404) for v${version}; refusing to install unverified`);
      }
      return null;
    }
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Install
// ---------------------------------------------------------------------------

function gunzipBounded(gz) {
  try {
    return zlib.gunzipSync(gz, { maxOutputLength: MAX_BINARY_BYTES });
  } catch (err) {
    throw new ChecksumError(`cannot decompress verified asset: ${err.message}`);
  }
}

// lstat-based directory check: `p` must be a real directory, never a
// symlink. With `create`, a missing directory is created (non-recursively,
// so every component gets its own check) and checked again.
function ensureRealDir(p, { create = false } = {}) {
  let st;
  try {
    st = fs.lstatSync(p);
  } catch (err) {
    if (err.code !== "ENOENT" || !create) throw err;
    try {
      fs.mkdirSync(p, { mode: 0o755 });
    } catch (mkErr) {
      if (mkErr.code !== "EEXIST") throw mkErr;
    }
    st = fs.lstatSync(p);
  }
  if (st.isSymbolicLink()) throw new UnsafePathError(`refusing to install through symlink ${p}`);
  if (!st.isDirectory()) throw new UnsafePathError(`refusing to install into ${p}: not a directory`);
}

// Validate (and create) root, root/prebuilt, root/prebuilt/<plat>-<arch>.
function prepareInstallDir(root = PKG_ROOT) {
  ensureRealDir(root);
  const prebuilt = path.join(root, "prebuilt");
  ensureRealDir(prebuilt, { create: true });
  const platDir = path.join(prebuilt, platformDir());
  ensureRealDir(platDir, { create: true });
  return platDir;
}

// lstat `dest`: null when absent; UnsafePathError when not a regular file.
function lstatDest(dest) {
  let st;
  try {
    st = fs.lstatSync(dest);
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
  if (!st.isFile()) throw new UnsafePathError(`refusing to replace ${dest}: not a regular file`);
  return st;
}

// Write `bin` to `dest` atomically. The parent directory must already be a
// real directory. The staging name is random and created with O_EXCL, so a
// pre-planted file or symlink at that name makes the open fail rather than
// be followed or clobbered; only a staging file this call created is
// unlinked on failure.
function writeAtomic(dest, bin, { rename = fs.renameSync } = {}) {
  ensureRealDir(path.dirname(dest));
  lstatDest(dest);
  const tmp = `${dest}.tmp.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  const flags = fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | (fs.constants.O_NOFOLLOW || 0);
  let ownedStagingPath = null;
  let fd = null;
  try {
    fd = fs.openSync(tmp, flags, 0o700);
    ownedStagingPath = tmp;
    let off = 0;
    while (off < bin.length) off += fs.writeSync(fd, bin, off, bin.length - off);
    fs.fchmodSync(fd, 0o755);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = null;
    lstatDest(dest);
    rename(tmp, dest);
    ownedStagingPath = null;
  } catch (err) {
    if (fd !== null) {
      try {
        fs.closeSync(fd);
      } catch {}
    }
    if (ownedStagingPath !== null) {
      try {
        fs.unlinkSync(ownedStagingPath);
      } catch {}
    }
    throw err;
  }
}

// The verified raw-binary digest for this platform, or null when the
// manifest does not record one.
function expectedBinSha256(manifest, plat = platformDir()) {
  if (!manifest || !manifest.binSha256 || typeof manifest.binSha256 !== "object") return null;
  if (!Object.prototype.hasOwnProperty.call(manifest.binSha256, plat)) return null;
  const want = manifest.binSha256[plat];
  return typeof want === "string" && /^[0-9a-f]{64}$/.test(want) ? want : null;
}

// An existing destination is reused only when the verified manifest records
// `binSha256` for this platform and the destination is a regular file (not a
// symlink), non-empty, no larger than MAX_BINARY_BYTES, executable by this
// process (access X_OK), and its SHA-256, hashed through an fd opened with
// O_NOFOLLOW and fstat-checked, matches exactly. Without a verified digest
// nothing is reused.
function existingInstallOk(dest, manifest) {
  const want = expectedBinSha256(manifest);
  if (!want) return false;
  let st;
  try {
    st = fs.lstatSync(dest);
  } catch {
    return false;
  }
  if (st.isSymbolicLink() || !st.isFile() || st.size === 0 || st.size > MAX_BINARY_BYTES) return false;
  try {
    fs.accessSync(dest, fs.constants.X_OK);
  } catch {
    return false;
  }
  let fd;
  try {
    fd = fs.openSync(dest, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  } catch {
    return false;
  }
  try {
    const fst = fs.fstatSync(fd);
    if (!fst.isFile() || fst.size === 0 || fst.size > MAX_BINARY_BYTES) return false;
    const hash = crypto.createHash("sha256");
    const buf = Buffer.allocUnsafe(1024 * 1024);
    let total = 0;
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      total += n;
      if (total > MAX_BINARY_BYTES) return false;
      hash.update(buf.subarray(0, n));
    }
    return hash.digest("hex") === want;
  } catch {
    return false;
  } finally {
    fs.closeSync(fd);
  }
}

// Throws ChecksumError unless the manifest records both digests this
// platform needs: `assets[<asset>]` (gzip) and `binSha256[<plat>]` (raw).
function requireManifestEntries(manifest, name = assetName(), plat = platformDir()) {
  if (!Object.prototype.hasOwnProperty.call(manifest.assets, name)) {
    throw new ChecksumError(`checksums.json for v${manifest.version} has no entry for ${name}`);
  }
  if (!expectedBinSha256(manifest, plat)) {
    throw new ChecksumError(`checksums.json for v${manifest.version} has no binSha256 for ${plat}`);
  }
}

async function install({ root = PKG_ROOT, version = pkg.version, fetch = get, env = process.env, now = monotonicNow } = {}) {
  const manifest = loadBundledChecksums(root, version);
  const name = assetName();
  if (manifest) requireManifestEntries(manifest, name);
  prepareInstallDir(root);
  const dest = targetPath(root);
  const existing = lstatDest(dest);
  if (existingInstallOk(dest, manifest)) {
    log(`already installed at ${dest} (sha256 verified against checksums.json)`);
    return dest;
  }
  if (existing && manifest) {
    // The file failed verification. Remove it now so that an offline exit 0
    // below never leaves it for bin/claude-p.js to execute.
    log(`removing ${dest}: it does not match binSha256 in checksums.json`);
    fs.unlinkSync(dest);
  }
  const url = `${releaseBase(version)}/${name}`;
  const deadline = now() + DOWNLOAD_DEADLINE_MS;
  log(`downloading ${url}`);
  let gz;
  if (manifest) {
    gz = await fetch(url, { maxBytes: MAX_COMPRESSED_BYTES, deadline });
    verifyBundled(gz, name, manifest);
  } else {
    const required = requireChecksumDefault(version, env);
    const [asset, sumsText] = await Promise.all([
      fetch(url, { maxBytes: MAX_COMPRESSED_BYTES, deadline }),
      fetchSha256Sums({ version, required, fetch, deadline }),
    ]);
    gz = asset;
    verifyChecksum(gz, name, sumsText, required);
  }
  const bin = gunzipBounded(gz);
  if (bin.length === 0) throw new ChecksumError(`${name} decompressed to 0 bytes`);
  const wantBin = expectedBinSha256(manifest);
  if (manifest && !wantBin) {
    throw new ChecksumError(`checksums.json for v${manifest.version} has no binSha256 for ${platformDir()}`);
  }
  if (wantBin) {
    const got = sha256(bin);
    if (got !== wantBin) {
      throw new ChecksumError(`decompressed ${name} sha256 ${got} does not match binSha256 ${wantBin}`);
    }
  }
  writeAtomic(dest, bin);
  log(`installed ${dest} (${bin.length} bytes)`);
  return dest;
}

// Returns the process exit code. `run` is injectable for tests.
async function main({ env = process.env, run = install, supported = isSupported() } = {}) {
  if (env.CLAUDE_P_SKIP_DOWNLOAD === "1") {
    log("CLAUDE_P_SKIP_DOWNLOAD set; skipping");
    return 0;
  }
  if (!supported) {
    log(`platform ${platformDir()} not supported; skipping`);
    return 0;
  }
  try {
    await run({ env });
    return 0;
  } catch (err) {
    if (err instanceof ChecksumError) {
      log(`checksum verification failed: ${err.message}`);
      log("refusing to install an unverified binary");
      return 1;
    }
    if (err instanceof UnsafePathError) {
      log(`unsafe install path: ${err.message}`);
      return 1;
    }
    if (!isConnectivityError(err)) {
      log(`error: could not install the claude-p binary: ${err.message}`);
      log("this is not a connectivity failure; fix the cause above and rerun npm rebuild claude-p");
      return 1;
    }
    const strict = env.CLAUDE_P_STRICT_INSTALL === "1";
    log(`${strict ? "error" : "warning"}: could not download the claude-p binary: ${err.message}`);
    log("the claude-p command will not work until the binary is installed");
    log("retry with network access (npm rebuild claude-p), set CLAUDE_P_SKIP_DOWNLOAD=1 to skip,");
    log("set CLAUDE_P_STRICT_INSTALL=1 to make this failure fatal, or build from source: zig build -Doptimize=ReleaseSafe");
    log("behind an HTTP(S) proxy: set NODE_USE_ENV_PROXY=1 (Node >= 22.21 or >= 24) with HTTPS_PROXY,");
    log("or set CLAUDE_P_SKIP_DOWNLOAD=1 and provide prebuilt/<platform>-<arch>/claude-p yourself");
    return strict ? 1 : 0;
  }
}

module.exports = {
  parseSha256Sums,
  verifyChecksum,
  sha256,
  ChecksumError,
  UnsafePathError,
  NetworkError,
  isConnectivityError,
  requireManifestEntries,
  monotonicNow,
  ensureRealDir,
  prepareInstallDir,
  expectedBinSha256,
  main,
  checksumRequiredFor,
  parseChecksumsManifest,
  verifyBundled,
  loadBundledChecksums,
  assertAllowedUrl,
  get,
  fetchSha256Sums,
  writeAtomic,
  existingInstallOk,
  install,
  MAX_REDIRECTS,
  MAX_COMPRESSED_BYTES,
  MAX_BINARY_BYTES,
  DOWNLOAD_DEADLINE_MS,
  REQUEST_TIMEOUT_MS,
};

if (require.main === module) {
  main().then(
    (code) => {
      process.exitCode = code;
    },
    (err) => {
      log(`unexpected error: ${err.stack || err.message}`);
      process.exitCode = 1;
    },
  );
}
