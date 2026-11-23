#!/usr/bin/env node
// Build prebuilt Zig binaries for every supported target, attach them to a
// GitHub release at the current `package.json` version, and publish the
// npm package with a bundled checksums.json.
//
// Usage:
//   npm run release                   # full release: build all + tag + GH release + npm publish
//   npm run release -- --dry-run      # everything up to (but not including) `gh release` and `npm publish`
//   npm run release -- --skip-tests   # skip `zig build test`
//   npm run release -- --skip-git     # skip clean-tree check
//   npm run release -- --otp=123456   # npm 2fa code (6-8 digits; never logged)
//   npm run release -- --local-only   # build prebuilts + SHA256SUMS + checksums.json, publish nothing
//   node scripts/publish.mjs --from-assets [--skip-git]
//                                     # skip the build; verify and publish ./release-assets/
//                                     # (the CI publish job, fed by the build job's artifact)
//   ... --only=github | --only=npm    # run just the GitHub release or just npm publish
//   node scripts/publish.mjs --check-versions [--expect-version=X.Y.Z | --expect-tag=vX.Y.Z]
//                                     # only verify package.json / build.zig.zon /
//                                     # src/root.zig versions (and LICENSE) agree; used by CI
//
// Flags are strict: unknown flags, `--flag=value` on a boolean other than
// `true`/`false`, and a bad `--otp` or version all exit 1.
//
// Every subprocess runs through spawnSync with an argument array: no shell,
// no interpolation.
//
// Outputs in release-assets/:
//   claude-p-<platform>-<arch>.gz   gzip -9 of each target binary
//   SHA256SUMS                      `<sha256>  <asset>` per line
//   checksums.json                  { version, assets: { "<asset>": sha256 },
//                                     binSha256: { "<platform>-<arch>": sha256 } }
// npm publish never touches the repo root. The package is staged in a private
// mkdtemp directory: package.json, every `files` entry, and the generated
// release-assets/checksums.json. `npm pack --dry-run --json` must list
// checksums.json, and the staged manifest must cover all 4 platforms at the
// package.json version, before `npm publish` runs from that directory. Only
// the private directory is removed afterwards.
//
// Tag identity: before building or attaching assets, the local tag
// refs/tags/v<version>^{commit} (when it exists) and the remote tag's peeled
// commit (when it exists) must both equal HEAD; in GitHub Actions HEAD must
// also equal GITHUB_SHA. Any mismatch refuses the release.
//
// Releases are immutable: when a GitHub release for v<version> already exists,
// every asset it already has (binaries, SHA256SUMS, checksums.json) is
// downloaded and its SHA-256 compared with the local file; any difference is
// fatal. Only missing assets are uploaded, and the full set is re-verified by
// digest before the step reports success. In GitHub Actions
// (GITHUB_ACTIONS=true) tag creation and push are skipped.

import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { gunzipSync, gzipSync } from "node:zlib";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const SEMVER = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;
const OTP_RE = /^\d{6,8}$/;

// ---------------------------------------------------------------------------
// Strict CLI parsing
// ---------------------------------------------------------------------------

const BOOL_FLAGS = new Set(["dry-run", "skip-tests", "skip-git", "local-only", "check-versions", "from-assets"]);
const STRING_FLAGS = new Set(["otp", "expect-version", "expect-tag", "only"]);

function parseArgs(argv) {
  const out = {};
  for (const a of argv) {
    const m = /^--([a-z][a-z-]*)(?:=(.*))?$/s.exec(a);
    if (!m) throw new Error(`unexpected argument ${JSON.stringify(a.startsWith("--otp") ? "--otp=<redacted>" : a)}`);
    const [, key, value] = m;
    if (key in out) throw new Error(`--${key} given more than once`);
    if (BOOL_FLAGS.has(key)) {
      if (value === undefined || value === "true") out[key] = true;
      else if (value === "false") out[key] = false;
      else throw new Error(`--${key} takes no value (or =true / =false), got ${JSON.stringify(value)}`);
    } else if (STRING_FLAGS.has(key)) {
      if (value === undefined || value === "") throw new Error(`--${key} needs a value: --${key}=<value>`);
      out[key] = value;
    } else {
      throw new Error(`unknown flag --${key}`);
    }
  }
  if (out.otp !== undefined && !OTP_RE.test(out.otp)) {
    throw new Error("--otp must be 6 to 8 digits");
  }
  if (out["expect-version"] !== undefined && !SEMVER.test(out["expect-version"])) {
    throw new Error(`--expect-version must be X.Y.Z (no leading v), got ${JSON.stringify(out["expect-version"])}`);
  }
  if (out["expect-tag"] !== undefined && !/^v/.test(out["expect-tag"])) {
    throw new Error(`--expect-tag must be v<version>, got ${JSON.stringify(out["expect-tag"])}`);
  }
  if (out.only !== undefined && out.only !== "github" && out.only !== "npm") {
    throw new Error(`--only must be github or npm, got ${JSON.stringify(out.only)}`);
  }
  if (out["expect-version"] !== undefined && out["expect-tag"] !== undefined) {
    throw new Error("pass --expect-version or --expect-tag, not both");
  }
  return out;
}

// CLI state, assigned by cli() only when this file is the entry point, so the
// helpers below can be imported by tests without side effects.
let args = {};
let DRY_RUN = false;
let SKIP_TESTS = false;
let SKIP_GIT = false;
let LOCAL_ONLY = false;
let FROM_ASSETS = false;
let OTP = null;
let ONLY = null;
let IN_ACTIONS = process.env.GITHUB_ACTIONS === "true";
let version;

function redact(s) {
  return OTP ? s.split(OTP).join("<redacted>") : s;
}

function log(step, msg) {
  console.log(`\n▸ [${step}] ${redact(msg)}`);
}

function display(cmd, argv) {
  return redact([cmd, ...argv].map((a) => (/^[\w./=:@%+-]+$/.test(a) ? a : JSON.stringify(a))).join(" "));
}

function run(cmd, argv, { cwd = root } = {}) {
  console.log(`  $ ${display(cmd, argv)}`);
  const r = spawnSync(cmd, argv, { stdio: "inherit", cwd });
  if (r.error) throw new Error(`${cmd}: ${r.error.message}`);
  if (r.status !== 0) throw new Error(`${display(cmd, argv)} exited ${r.status ?? r.signal}`);
}

function capture(cmd, argv, { cwd = root } = {}) {
  const r = spawnSync(cmd, argv, { cwd, encoding: "utf8" });
  if (r.error) throw new Error(`${cmd}: ${r.error.message}`);
  return r;
}

// ---------------------------------------------------------------------------
// Version agreement: package.json, build.zig.zon, src/root.zig
// ---------------------------------------------------------------------------

function readVersions() {
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;

  const zon = readFileSync(join(root, "build.zig.zon"), "utf8");
  const zonMatch = zon.match(/^\s*\.version\s*=\s*"([^"]+)"/m);
  if (!zonMatch) throw new Error("build.zig.zon: no `.version = \"...\"` field found");

  const rootZig = readFileSync(join(root, "src", "root.zig"), "utf8");
  const rootMatch = rootZig.match(
    /pub const version\s*:\s*std\.SemanticVersion\s*=\s*\.\{\s*\.major\s*=\s*(\d+)\s*,\s*\.minor\s*=\s*(\d+)\s*,\s*\.patch\s*=\s*(\d+)/,
  );
  if (!rootMatch) {
    throw new Error("src/root.zig: no `pub const version: std.SemanticVersion = .{ .major, .minor, .patch }` found");
  }

  return {
    "package.json": pkg,
    "build.zig.zon": zonMatch[1],
    "src/root.zig": `${rootMatch[1]}.${rootMatch[2]}.${rootMatch[3]}`,
  };
}

function checkVersions(expected) {
  const versions = readVersions();
  const want = expected ?? versions["package.json"];
  const bad = Object.entries(versions).filter(([, v]) => v !== want);
  for (const [file, v] of Object.entries(versions)) {
    console.log(`  ${file.padEnd(14)} ${v}${v === want ? "" : `  ✗ (want ${want})`}`);
  }
  if (bad.length) {
    throw new Error(`version mismatch: expected ${want} everywhere, got ` + bad.map(([f, v]) => `${f}=${v}`).join(", "));
  }
  if (!SEMVER.test(want)) throw new Error(`version ${JSON.stringify(want)} is not strict semver`);
  if (!existsSync(join(root, "LICENSE"))) {
    throw new Error("LICENSE file is missing (package.json `files` ships it)");
  }
  return want;
}

const TARGETS = [
  { zig: "aarch64-macos", platform: "darwin", arch: "arm64" },
  { zig: "x86_64-macos", platform: "darwin", arch: "x64" },
  { zig: "x86_64-linux-musl", platform: "linux", arch: "x64" },
  { zig: "aarch64-linux-musl", platform: "linux", arch: "arm64" },
];
const assetNames = TARGETS.map((t) => `claude-p-${t.platform}-${t.arch}.gz`);
const PLATFORMS = TARGETS.map((t) => `${t.platform}-${t.arch}`);
const assetsDir = join(root, "release-assets");
const HEX64 = /^[0-9a-f]{64}$/;

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

function parseSums(text) {
  const m = new Map();
  for (const line of text.split(/\r?\n/)) {
    const x = /^([0-9a-f]{64}) {2}\*?(\S+)$/.exec(line.trim());
    if (x) m.set(x[2], x[1]);
  }
  return m;
}

function main() {
  log("version", `releasing v${version}`);

  if (!SKIP_GIT) {
    log("git", "checking clean working tree");
    const out = capture("git", ["status", "--porcelain"]);
    if (out.status !== 0) throw new Error(`git status failed:\n${out.stderr}`);
    if (out.stdout.trim()) {
      throw new Error(`working tree is dirty — commit or stash first (or pass --skip-git):\n${out.stdout}`);
    }
  }

  if (!LOCAL_ONLY) {
    log("git", `verifying v${version} points at HEAD (local and remote)`);
    verifyTagRevision({ tag: `v${version}`, capture, env: process.env });
  }

  if (FROM_ASSETS) {
    log("assets", "using prebuilt ./release-assets/ (no build)");
  } else {
    if (!SKIP_TESTS) {
      log("test", "zig build test");
      run("zig", ["build", "test"]);
    } else {
      log("test", "skipped (--skip-tests)");
    }
    buildAll();
  }

  writeChecksums();

  if (LOCAL_ONLY) {
    console.log("\n✓ --local-only: prebuilts in ./prebuilt/; gzipped assets, SHA256SUMS, checksums.json in ./release-assets/. Stopping.");
    return;
  }

  if (ONLY !== "npm") {
    tag();
    githubRelease();
  }
  if (ONLY !== "github") npmPublish();
  console.log(`\n✓ v${version} ${DRY_RUN ? "(dry run) " : ""}done`);
}

// ---------------------------------------------------------------------------
// Build prebuilts
// ---------------------------------------------------------------------------

function buildAll() {
  rmSync(join(root, "prebuilt"), { recursive: true, force: true });
  rmSync(assetsDir, { recursive: true, force: true });
  mkdirSync(assetsDir, { recursive: true });

  for (const t of TARGETS) {
    log("build", `${t.zig} -> prebuilt/${t.platform}-${t.arch}/claude-p`);
    const stage = join(root, `prebuilt-stage-${t.zig}`);
    run("zig", [
      "build",
      "-Doptimize=ReleaseSafe",
      `-Dtarget=${t.zig}`,
      "--cache-dir",
      join(root, ".zig-cache", "release", t.zig),
      "-p",
      stage,
    ]);
    const built = join(stage, "bin", "claude-p");
    if (!existsSync(built)) throw new Error(`expected built binary at ${built}, not found`);
    const bin = readFileSync(built);
    const destDir = join(root, "prebuilt", `${t.platform}-${t.arch}`);
    mkdirSync(destDir, { recursive: true });
    writeFileSync(join(destDir, "claude-p"), bin, { mode: 0o755 });
    const gz = gzipSync(bin, { level: 9 });
    writeFileSync(join(assetsDir, `claude-p-${t.platform}-${t.arch}.gz`), gz, { mode: 0o644 });
    console.log(`  built ${(bin.length / 1024).toFixed(1)} KiB raw, ${(gz.length / 1024).toFixed(1)} KiB gzipped`);
    rmSync(stage, { recursive: true, force: true });
  }

  log("checksums", "writing release-assets/SHA256SUMS");
  const sums = assetNames.map((name) => `${sha256(readFileSync(join(assetsDir, name)))}  ${name}\n`).join("");
  writeFileSync(join(assetsDir, "SHA256SUMS"), sums, { mode: 0o644 });
  console.log(sums.trimEnd().replace(/^/gm, "  "));

  log("smoke", "exercising the native prebuilt's --version");
  const bin = join(root, "prebuilt", `${process.platform}-${process.arch}`, "claude-p");
  if (existsSync(bin)) run(bin, ["--version"]);
  else console.log(`  (skipped — no native target for ${process.platform}-${process.arch})`);
}

// Verify every asset against SHA256SUMS and write checksums.json.
function writeChecksums() {
  log("checksums", "verifying release-assets/ and writing checksums.json");
  const sumsPath = join(assetsDir, "SHA256SUMS");
  if (!existsSync(sumsPath)) throw new Error(`${sumsPath} is missing`);
  const sums = parseSums(readFileSync(sumsPath, "utf8"));
  const manifest = { version, assets: {}, binSha256: {} };
  for (const t of TARGETS) {
    const name = `claude-p-${t.platform}-${t.arch}.gz`;
    const gz = readFileSync(join(assetsDir, name));
    const digest = sha256(gz);
    if (sums.get(name) !== digest) {
      throw new Error(`SHA256SUMS lists ${sums.get(name) ?? "nothing"} for ${name}, file is ${digest}`);
    }
    manifest.assets[name] = digest;
    manifest.binSha256[`${t.platform}-${t.arch}`] = sha256(gunzipSync(gz));
  }
  if (sums.size !== assetNames.length) {
    throw new Error(`SHA256SUMS has ${sums.size} entries, expected ${assetNames.length}`);
  }
  writeFileSync(join(assetsDir, "checksums.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
  console.log(`  ${Object.keys(manifest.assets).length} assets verified`);
  return manifest;
}

// ---------------------------------------------------------------------------
// Tag
// ---------------------------------------------------------------------------

function tag() {
  if (IN_ACTIONS) {
    log("git", "skipping tag: GITHUB_ACTIONS=true (the tag push triggered this run)");
    return;
  }
  const t = `v${version}`;
  log("git", `tagging ${t} (if not already tagged)`);
  const tags = capture("git", ["tag", "--list", t]);
  if (tags.status !== 0) throw new Error(`git tag --list failed:\n${tags.stderr}`);
  if (tags.stdout.trim() !== t) {
    if (DRY_RUN) console.log(`  DRY RUN — would run: git tag -a ${t}`);
    else run("git", ["tag", "-a", t, "-m", `claude-p ${t}`]);
  } else {
    console.log(`  ${t} already tagged locally`);
  }
  const remote = capture("git", ["ls-remote", "--tags", "origin", `refs/tags/${t}`]);
  if (remote.status === 0 && remote.stdout.trim()) {
    console.log(`  ${t} already pushed to origin`);
  } else if (DRY_RUN) {
    console.log(`  DRY RUN — would run: git push origin ${t}`);
  } else {
    run("git", ["push", "origin", t]);
  }
  if (!DRY_RUN) verifyTagRevision({ tag: t, capture, env: process.env });
}

// Parse `git ls-remote origin refs/tags/<t> refs/tags/<t>^{}` output into the
// tag's peeled commit: the `^{}` line for an annotated tag, else the plain
// line for a lightweight tag. Returns null when the remote has no such tag.
export function parseLsRemoteTag(stdout, tag) {
  let plain = null;
  let peeled = null;
  for (const line of String(stdout).split(/\r?\n/)) {
    const m = /^([0-9a-f]{40}|[0-9a-f]{64})\t(\S+)$/.exec(line.trim());
    if (!m) continue;
    if (m[2] === `refs/tags/${tag}^{}`) peeled = m[1];
    else if (m[2] === `refs/tags/${tag}`) plain = m[1];
  }
  return peeled ?? plain;
}

// H15: refuse a tag whose local or remote peeled commit is not HEAD. `capture`
// is injectable for tests and must return { status, stdout, stderr }.
export function verifyTagRevision({ tag, capture: cap, env = {} }) {
  const head = cap("git", ["rev-parse", "--verify", "HEAD^{commit}"]);
  if (head.status !== 0) throw new Error(`git rev-parse HEAD failed:\n${head.stderr}`);
  const headSha = head.stdout.trim();
  if (env.GITHUB_ACTIONS === "true" && env.GITHUB_SHA && env.GITHUB_SHA !== headSha) {
    throw new Error(`HEAD is ${headSha} but GITHUB_SHA is ${env.GITHUB_SHA}; refusing to release a different revision`);
  }
  const local = cap("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${tag}^{commit}`]);
  const localSha = local.status === 0 ? local.stdout.trim() : null;
  if (localSha && localSha !== headSha) {
    throw new Error(`local tag ${tag} points at ${localSha}, HEAD is ${headSha}; refusing mismatched revision`);
  }
  const remote = cap("git", ["ls-remote", "origin", `refs/tags/${tag}`, `refs/tags/${tag}^{}`]);
  if (remote.status !== 0) {
    throw new Error(`git ls-remote origin failed; cannot verify remote tag ${tag}:\n${remote.stderr}`);
  }
  const remoteSha = parseLsRemoteTag(remote.stdout, tag);
  if (remoteSha && remoteSha !== headSha) {
    throw new Error(`remote tag ${tag} points at ${remoteSha}, HEAD is ${headSha}; refusing mismatched revision`);
  }
  return { head: headSha, local: localSha, remote: remoteSha };
}

// ---------------------------------------------------------------------------
// GitHub release (immutable)
// ---------------------------------------------------------------------------

// M21: compare the digests of assets already on the release with the local
// files. Throws on any mismatch; with `requireAll`, also on any missing file.
// Returns the names the release still lacks.
export function compareReleaseAssets(local, remote, { tag = "release", requireAll = false } = {}) {
  const missing = [];
  for (const [name, digest] of Object.entries(local)) {
    if (!Object.prototype.hasOwnProperty.call(remote, name)) {
      missing.push(name);
      continue;
    }
    if (remote[name] !== digest) {
      throw new Error(
        `${tag} already publishes ${name} with sha256 ${remote[name]}; this build is ${digest}. ` +
          "Releases are immutable: bump the version instead of overwriting.",
      );
    }
  }
  if (requireAll && missing.length) {
    throw new Error(`${tag} is missing ${missing.join(", ")} after upload`);
  }
  return missing;
}

// Digests of `names` on release `t`: download each present asset into a
// private temp dir and hash it. The API `digest` field, when gh reports one,
// must agree with the downloaded bytes.
function remoteAssetDigests(t, names) {
  const view = capture("gh", ["release", "view", t, "--json", "assets"]);
  if (view.status !== 0) throw new Error(`gh release view ${t} failed:\n${view.stderr}`);
  const assets = JSON.parse(view.stdout).assets;
  const present = assets.filter((a) => names.includes(a.name));
  const out = {};
  if (present.length === 0) return out;
  const dir = mkdtempSync(join(tmpdir(), "claude-p-release-"));
  try {
    for (const a of present) {
      run("gh", ["release", "download", t, "--pattern", a.name, "--dir", dir, "--clobber"]);
      const digest = sha256(readFileSync(join(dir, a.name)));
      if (typeof a.digest === "string" && a.digest.startsWith("sha256:") && a.digest.slice(7) !== digest) {
        throw new Error(`${t} asset ${a.name}: API digest ${a.digest} disagrees with downloaded sha256 ${digest}`);
      }
      out[a.name] = digest;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  return out;
}

function githubRelease() {
  const t = `v${version}`;
  log("github", `creating ${t} or completing its missing assets`);
  const files = [...assetNames, "SHA256SUMS", "checksums.json"];
  const local = Object.fromEntries(files.map((n) => [n, sha256(readFileSync(join(assetsDir, n)))]));

  const view = capture("gh", ["release", "view", t, "--json", "assets"]);
  if (view.status !== 0) {
    if (!/release not found|not found/i.test(view.stderr)) {
      throw new Error(`gh release view ${t} failed:\n${view.stderr}`);
    }
    const argv = ["release", "create", t, "--verify-tag", "--title", `claude-p ${t}`, "--notes", "Automated release.", ...files.map((n) => join(assetsDir, n))];
    if (DRY_RUN) {
      console.log(`  DRY RUN — would run: ${display("gh", argv)}`);
      return;
    }
    run("gh", argv);
  } else {
    const missing = compareReleaseAssets(local, remoteAssetDigests(t, files), { tag: t });
    if (missing.length === 0) {
      console.log(`  ${t} already has every asset; verifying digests below`);
    } else {
      const argv = ["release", "upload", t, ...missing.map((n) => join(assetsDir, n))];
      if (DRY_RUN) {
        console.log(`  DRY RUN — would run: ${display("gh", argv)}`);
        return;
      }
      run("gh", argv);
    }
  }
  log("github", `re-verifying every ${t} asset by sha256`);
  compareReleaseAssets(local, remoteAssetDigests(t, files), { tag: t, requireAll: true });
  console.log(`  ${files.length} assets on ${t} match the local digests`);
}

// ---------------------------------------------------------------------------
// npm publish
// ---------------------------------------------------------------------------

function npmPublish() {
  const pkgName = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).name;

  log("npm", `checking whether ${pkgName}@${version} is already published`);
  const view = capture("npm", ["view", `${pkgName}@${version}`, "version"]);
  if (view.status === 0 && view.stdout.trim() === version) {
    console.log(`  ${pkgName}@${version} is already on npm; skipping npm publish`);
    return;
  }
  if (view.status !== 0 && !/E404|404 Not Found|is not in this registry/i.test(`${view.stdout}${view.stderr}`)) {
    console.log(`  npm view failed (status ${view.status}); proceeding to publish:\n${view.stderr.trim()}`);
  } else {
    console.log("  not published yet");
  }

  // Provenance needs a GitHub Actions OIDC token (`permissions: id-token: write`).
  const HAS_OIDC = IN_ACTIONS && !!process.env.ACTIONS_ID_TOKEN_REQUEST_URL;
  const HAS_TOKEN = !!(process.env.NODE_AUTH_TOKEN || process.env.NPM_TOKEN);

  log("npm", "checking auth");
  if (HAS_TOKEN) {
    console.log("  using NODE_AUTH_TOKEN / NPM_TOKEN; skipping whoami");
  } else if (HAS_OIDC) {
    console.log("  no npm token; relying on npm trusted publishing (OIDC)");
  } else {
    const who = capture("npm", ["whoami"]);
    if (who.status === 0) {
      console.log(`  logged in as ${who.stdout.trim()}`);
    } else if (!DRY_RUN) {
      console.log("  not logged in — running `npm login` (interactive)");
      run("npm", ["login"]);
    }
  }

  const argv = ["publish", "--access", "public"];
  if (HAS_OIDC) argv.push("--provenance");
  if (OTP) argv.push(`--otp=${OTP}`);

  const stage = stageNpmPackage({ srcRoot: root, manifestPath: join(assetsDir, "checksums.json") });
  try {
    log("npm", `staged package in ${stage}; checking the tarball file list`);
    const pack = capture("npm", ["pack", "--dry-run", "--json", "--ignore-scripts"], { cwd: stage });
    if (pack.status !== 0) throw new Error(`npm pack --dry-run failed:\n${pack.stderr}`);
    verifyPackList(pack.stdout);
    verifyStagedManifest(readFileSync(join(stage, "checksums.json"), "utf8"), { version });
    console.log("  tarball contains checksums.json for all 4 platforms");
    if (DRY_RUN) {
      console.log(`  DRY RUN — would run in the staging dir: ${display("npm", argv)}`);
      return;
    }
    log("npm", "publish (from the private staging dir, with bundled checksums.json)");
    run("npm", argv, { cwd: stage });
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
}

// L04/M22: copy package.json, every `files` entry, and the generated
// checksums.json into a private mkdtemp directory. The repo root is never
// written. Returns the staging directory; the caller removes it.
export function stageNpmPackage({ srcRoot, manifestPath, tmp = tmpdir() }) {
  const pkg = JSON.parse(readFileSync(join(srcRoot, "package.json"), "utf8"));
  if (!Array.isArray(pkg.files) || !pkg.files.includes("checksums.json")) {
    throw new Error("package.json `files` must list checksums.json");
  }
  const stage = mkdtempSync(join(tmp, "claude-p-npm-"));
  try {
    copyFileSync(join(srcRoot, "package.json"), join(stage, "package.json"));
    for (const rel of pkg.files) {
      if (rel.includes("*") || rel.startsWith("/") || rel.split("/").includes("..")) {
        throw new Error(`package.json files entry ${JSON.stringify(rel)} is not a plain relative path`);
      }
      const from = rel === "checksums.json" ? manifestPath : join(srcRoot, rel);
      if (!existsSync(from)) throw new Error(`cannot stage ${rel}: ${from} is missing`);
      const to = join(stage, rel);
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(from, to);
      chmodSync(to, statSync(from).mode & 0o777);
    }
    return stage;
  } catch (err) {
    rmSync(stage, { recursive: true, force: true });
    throw err;
  }
}

// `npm pack --dry-run --json` output must list checksums.json and the files
// the installer and launcher need.
export function verifyPackList(jsonText) {
  let data;
  try {
    data = JSON.parse(jsonText);
  } catch (err) {
    throw new Error(`npm pack --json printed invalid JSON: ${err.message}`);
  }
  const entry = Array.isArray(data) ? data[0] : data;
  const paths = new Set((entry && entry.files ? entry.files : []).map((f) => f.path));
  for (const need of ["package.json", "checksums.json", "scripts/install.js", "bin/claude-p.js"]) {
    if (!paths.has(need)) throw new Error(`npm tarball would not contain ${need}`);
  }
  return paths;
}

// The staged checksums.json must be for `version` and cover every platform.
export function verifyStagedManifest(text, { version: want, names = assetNames, platforms = PLATFORMS }) {
  const m = JSON.parse(text);
  if (m.version !== want) throw new Error(`staged checksums.json is for ${m.version}, package.json is ${want}`);
  for (const n of names) {
    if (!m.assets || !HEX64.test(m.assets[n] ?? "")) throw new Error(`staged checksums.json lacks a sha256 for ${n}`);
  }
  for (const p of platforms) {
    if (!m.binSha256 || !HEX64.test(m.binSha256[p] ?? "")) throw new Error(`staged checksums.json lacks binSha256 for ${p}`);
  }
  if (Object.keys(m.assets).length !== names.length) throw new Error("staged checksums.json lists unexpected assets");
  return m;
}

function cli() {
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`✗ ${err.message}`);
    process.exit(1);
  }
  DRY_RUN = !!args["dry-run"];
  SKIP_TESTS = !!args["skip-tests"];
  SKIP_GIT = !!args["skip-git"];
  LOCAL_ONLY = !!args["local-only"];
  FROM_ASSETS = !!args["from-assets"];
  OTP = args.otp ?? null;
  ONLY = args.only ?? null;
  IN_ACTIONS = process.env.GITHUB_ACTIONS === "true";

  log("version", "checking package.json / build.zig.zon / src/root.zig agree");
  try {
    version = checkVersions(args["expect-version"]);
    // The tag must be exactly v<version>: `vv0.1.3` and `0.1.3` both fail.
    if (args["expect-tag"] !== undefined && args["expect-tag"] !== `v${version}`) {
      throw new Error(`tag ${JSON.stringify(args["expect-tag"])} is not v${version}`);
    }
  } catch (err) {
    console.error(`\n✗ ${err.message}`);
    process.exit(1);
  }

  if (args["check-versions"]) {
    console.log(`\n✓ versions agree on ${version}; LICENSE present`);
    process.exit(0);
  }

  try {
    main();
  } catch (err) {
    console.error(`\n✗ ${redact(err.message)}`);
    process.exit(1);
  }
}

export { parseArgs, parseSums };

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) cli();
