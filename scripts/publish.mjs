#!/usr/bin/env node
// Build prebuilt Zig binaries for every supported target, attach them to a
// GitHub release at the current `package.json` version, and publish the
// npm package. Inspired by ../smithers/scripts/publish.mjs.
//
// Usage:
//   npm run release                   # full release: build all + tag + GH release + npm publish
//   npm run release -- --dry-run      # everything up to (but not including) `gh release create` and `npm publish`
//   npm run release -- --skip-tests   # skip `zig build test`
//   npm run release -- --skip-git     # skip clean-tree check
//   npm run release -- --otp=123456   # npm 2fa code
//   npm run release -- --local-only   # build prebuilts but don't publish anywhere (smoke test)
//   node scripts/publish.mjs --check-versions [--expect-version=X.Y.Z]
//                                     # only verify package.json / build.zig.zon /
//                                     # src/root.zig versions (and LICENSE) agree; used by CI
//
// Required env for full publish:
//   - GH_TOKEN (or you must be logged in via `gh auth login`)
//   - npm auth (NPM_TOKEN in CI, or `npm login` locally)
//
// Required tooling:
//   - zig 0.15.2 on $PATH (cross-compiles natively)
//   - gh CLI
//   - npm
//
// Targets:
//   - aarch64-macos     -> prebuilt/darwin-arm64/claude-p
//   - x86_64-macos      -> prebuilt/darwin-x64/claude-p
//   - x86_64-linux-musl -> prebuilt/linux-x64/claude-p
//   - aarch64-linux-musl-> prebuilt/linux-arm64/claude-p
//
// Each is gzipped to release-assets/claude-p-<platform>-<arch>.gz and
// uploaded as a GitHub release asset alongside release-assets/SHA256SUMS
// (`<sha256>  <asset>` per line). The npm `postinstall` hook in
// scripts/install.js downloads the right one at install time and verifies it
// against SHA256SUMS.
//
// Idempotency: re-running for a version whose GitHub release or npm version
// already exists re-uploads assets (--clobber) and skips `npm publish`.
// In GitHub Actions on a tag push, tag creation/push is skipped entirely (the
// tag already exists and the runner has no git identity).

import { execSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, "").split("=");
    return [k, v ?? true];
  }),
);
const DRY_RUN = !!args["dry-run"];
const SKIP_TESTS = !!args["skip-tests"];
const SKIP_GIT = !!args["skip-git"];
const LOCAL_ONLY = !!args["local-only"];
const OTP = typeof args.otp === "string" ? args.otp : null;

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
    throw new Error(
      `version mismatch: expected ${want} everywhere, got ` +
        bad.map(([f, v]) => `${f}=${v}`).join(", "),
    );
  }
  if (!existsSync(join(root, "LICENSE"))) {
    throw new Error("LICENSE file is missing (package.json `files` ships it)");
  }
  return want;
}

const EXPECT =
  typeof args["expect-version"] === "string"
    ? args["expect-version"].replace(/^v/, "")
    : undefined;

log("version", "checking package.json / build.zig.zon / src/root.zig agree");
let version;
try {
  version = checkVersions(EXPECT);
} catch (err) {
  console.error(`\n✗ ${err.message}`);
  process.exit(1);
}

if (args["check-versions"]) {
  console.log(`\n✓ versions agree on ${version}; LICENSE present`);
  process.exit(0);
}

const TARGETS = [
  { zig: "aarch64-macos",      platform: "darwin",  arch: "arm64" },
  { zig: "x86_64-macos",       platform: "darwin",  arch: "x64"   },
  { zig: "x86_64-linux-musl",  platform: "linux",   arch: "x64"   },
  { zig: "aarch64-linux-musl", platform: "linux",   arch: "arm64" },
];

function log(step, msg) {
  console.log(`\n▸ [${step}] ${msg}`);
}

function run(cmd) {
  console.log(`  $ ${cmd}`);
  execSync(cmd, { stdio: "inherit", cwd: root });
}

function capture(cmd) {
  return execSync(cmd, { cwd: root, encoding: "utf8" }).trim();
}

log("version", `releasing v${version}`);

if (!SKIP_GIT) {
  log("git", "checking clean working tree");
  const out = spawnSync("git", ["status", "--porcelain"], {
    cwd: root,
    encoding: "utf8",
  });
  if (out.stdout.trim()) {
    throw new Error(
      `working tree is dirty — commit or stash first (or pass --skip-git):\n${out.stdout}`,
    );
  }
}

if (!SKIP_TESTS) {
  log("test", "zig build test");
  run("zig build test");
} else {
  log("test", "skipped (--skip-tests)");
}

// ---------------------------------------------------------------------------
// Build prebuilts
// ---------------------------------------------------------------------------

rmSync(join(root, "prebuilt"), { recursive: true, force: true });
rmSync(join(root, "release-assets"), { recursive: true, force: true });
mkdirSync(join(root, "release-assets"), { recursive: true });

for (const t of TARGETS) {
  log("build", `${t.zig} -> prebuilt/${t.platform}-${t.arch}/claude-p`);
  const cacheDir = join(root, ".zig-cache", "release", t.zig);
  run(
    `zig build -Doptimize=ReleaseSafe -Dtarget=${t.zig} --cache-dir ${cacheDir} -p prebuilt-stage-${t.zig}`,
  );

  // zig install drops the binary into <prefix>/bin/claude-p
  const built = join(root, `prebuilt-stage-${t.zig}`, "bin", "claude-p");
  if (!existsSync(built)) {
    throw new Error(`expected built binary at ${built}, not found`);
  }
  const destDir = join(root, "prebuilt", `${t.platform}-${t.arch}`);
  mkdirSync(destDir, { recursive: true });
  const dest = join(destDir, "claude-p");
  writeFileSync(dest, readFileSync(built), { mode: 0o755 });

  // Gzip into release-assets/.
  const gz = gzipSync(readFileSync(built), { level: 9 });
  const asset = join(
    root,
    "release-assets",
    `claude-p-${t.platform}-${t.arch}.gz`,
  );
  writeFileSync(asset, gz);
  console.log(
    `  built ${(readFileSync(built).length / 1024).toFixed(1)} KiB raw, ` +
      `${(gz.length / 1024).toFixed(1)} KiB gzipped`,
  );

  // Clean the staging install.
  rmSync(join(root, `prebuilt-stage-${t.zig}`), { recursive: true, force: true });
}

log("checksums", "writing release-assets/SHA256SUMS");
const assetNames = TARGETS.map((t) => `claude-p-${t.platform}-${t.arch}.gz`);
const sums = assetNames
  .map((name) => {
    const digest = createHash("sha256")
      .update(readFileSync(join(root, "release-assets", name)))
      .digest("hex");
    return `${digest}  ${name}\n`;
  })
  .join("");
writeFileSync(join(root, "release-assets", "SHA256SUMS"), sums);
console.log(sums.trimEnd().replace(/^/gm, "  "));

log("smoke", "exercising the native prebuilt's --version");
const nativePlatform = process.platform;
const nativeArch = process.arch;
const native = TARGETS.find(
  (t) => t.platform === nativePlatform && t.arch === nativeArch,
);
if (native) {
  const bin = join(root, "prebuilt", `${native.platform}-${native.arch}`, "claude-p");
  if (existsSync(bin)) {
    run(`${bin} --version`);
  }
} else {
  console.log(`  (skipped — no native target match for ${nativePlatform}-${nativeArch})`);
}

if (LOCAL_ONLY) {
  console.log("\n✓ --local-only: built prebuilts in ./prebuilt/, gzipped + SHA256SUMS in ./release-assets/. Stopping.");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Tag
// ---------------------------------------------------------------------------

const CI_TAG_BUILD =
  process.env.GITHUB_ACTIONS === "true" &&
  process.env.GITHUB_REF_TYPE === "tag" &&
  process.env.GITHUB_REF_NAME === `v${version}`;

if (CI_TAG_BUILD) {
  log("git", `skipping tag: triggered by tag push of v${version}`);
} else {
  log("git", `tagging v${version} (if not already tagged)`);
  const tags = capture("git tag --list");
  if (!tags.split("\n").includes(`v${version}`)) {
    if (DRY_RUN) {
      console.log(`  DRY RUN — would run: git tag -a v${version}`);
    } else {
      run(`git tag -a v${version} -m "claude-p v${version}"`);
    }
  } else {
    console.log(`  v${version} already tagged locally`);
  }

  // Push tag if not already at remote.
  const remoteTag = capture(`git ls-remote --tags origin v${version} || true`);
  if (remoteTag.trim()) {
    console.log(`  v${version} already pushed to origin`);
  } else if (DRY_RUN) {
    console.log("  DRY RUN — would push tag with: git push origin v" + version);
  } else {
    run(`git push origin v${version}`);
  }
}

// ---------------------------------------------------------------------------
// GitHub release
// ---------------------------------------------------------------------------

log("github", "creating release + uploading assets");
const assets = [...assetNames, "SHA256SUMS"].map((name) =>
  join(root, "release-assets", name),
);
const assetArgs = assets.map((a) => `"${a}"`).join(" ");

if (DRY_RUN) {
  console.log(
    `  DRY RUN — would run: gh release create v${version} --title "claude-p v${version}" --notes "automated release" ${assetArgs}`,
  );
} else {
  // If the release already exists, upload assets to it; otherwise create.
  const releaseExists =
    spawnSync("gh", ["release", "view", `v${version}`], {
      cwd: root,
      stdio: "ignore",
    }).status === 0;
  if (releaseExists) {
    run(`gh release upload v${version} ${assetArgs} --clobber`);
  } else {
    run(
      `gh release create v${version} --title "claude-p v${version}" --notes "Automated release. See REPORT.md and CHANGELOG (if present)." ${assetArgs}`,
    );
  }
}

// ---------------------------------------------------------------------------
// npm publish
// ---------------------------------------------------------------------------

const pkgName = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).name;

log("npm", `checking whether ${pkgName}@${version} is already published`);
const view = spawnSync("npm", ["view", `${pkgName}@${version}`, "version"], {
  cwd: root,
  encoding: "utf8",
});
const alreadyPublished = view.status === 0 && view.stdout.trim() === version;
if (alreadyPublished) {
  console.log(`  ${pkgName}@${version} is already on npm; skipping npm publish`);
  console.log(`\n✓ v${version} ${DRY_RUN ? "(dry run) " : ""}done`);
  process.exit(0);
}
if (view.status !== 0 && !/E404|404 Not Found|is not in this registry/i.test(`${view.stdout}${view.stderr}`)) {
  // Registry/network error: don't guess. Publishing a version twice fails
  // anyway, so a wrong guess here would only produce a noisier failure.
  console.log(`  npm view failed (status ${view.status}); proceeding to publish:\n${view.stderr.trim()}`);
} else {
  console.log("  not published yet");
}

// Provenance needs a GitHub Actions OIDC token (`permissions: id-token: write`).
const HAS_OIDC =
  process.env.GITHUB_ACTIONS === "true" && !!process.env.ACTIONS_ID_TOKEN_REQUEST_URL;
const HAS_TOKEN = !!(process.env.NODE_AUTH_TOKEN || process.env.NPM_TOKEN);

log("npm", "checking auth");
if (HAS_TOKEN) {
  console.log("  using NODE_AUTH_TOKEN / NPM_TOKEN; skipping whoami");
} else if (HAS_OIDC) {
  console.log("  no npm token; relying on npm trusted publishing (OIDC)");
} else {
  const who = spawnSync("npm", ["whoami"], { cwd: root, encoding: "utf8" });
  if (who.status === 0) {
    console.log(`  logged in as ${who.stdout.trim()}`);
  } else if (!DRY_RUN) {
    console.log("  not logged in — running `npm login` (interactive)");
    run("npm login");
  }
}

const provenanceFlag = HAS_OIDC ? " --provenance" : "";
const otpFlag = OTP ? ` --otp=${OTP}` : "";
const publishCmd = `npm publish --access public${provenanceFlag}${otpFlag}`;
if (DRY_RUN) {
  console.log(`  DRY RUN — would run: ${publishCmd}`);
} else {
  log("npm", "publish");
  run(publishCmd);
}

console.log(`\n✓ v${version} ${DRY_RUN ? "(dry run) " : ""}done`);
