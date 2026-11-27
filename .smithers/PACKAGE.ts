import { Smithers as S } from "@smthrs/targets"
import { fileURLToPath } from "node:url"

// Fine-grained root-anchored input closures so editing docs or JS scripts
// never invalidates Zig builds/tests, and editing JS packaging only reruns
// sub-100ms Node checks. Globs remain package-scoped even with //, so each
// root filegroup sets cwd: "//".
const zigSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//build.zig"),
    S.file("//build.zig.zon"),
    S.glob("//src/**/*.zig"),
    S.glob("//tests/**/*.zig")
  ]
})

const jsSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//package.json"),
    S.file("//bin/claude-p.js"),
    S.file("//scripts/install.js"),
    S.file("//scripts/publish.mjs"),
    S.file("//scripts/build-in-linux.sh"),
    S.file("//scripts/fuzz-linux.sh"),
    S.file("//scripts/smthrs"),
    S.file("//scripts/smithers-auth.mjs")
  ]
})

const versionSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//LICENSE"),
    S.file("//package.json"),
    S.file("//build.zig.zon"),
    S.file("//src/root.zig"),
    S.file("//scripts/publish.mjs")
  ]
})

const workflowSources = S.Filegroup({
  cwd: "//",
  srcs: [S.glob("//.github/workflows/*.yml")]
})

const factorySources = S.Filegroup({
  srcs: [S.glob("**", { exclude: ["cache/**", "reports/**"] })]
})

const uphillSources = S.Filegroup({
  cwd: "//",
  srcs: [S.glob("//.agents/uphill/**")]
})

const docsSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//docs/astro.config.mjs"),
    S.file("//docs/package.json"),
    S.glob("//docs/src/**"),
    S.glob("//docs/public/**")
  ]
})

const zigRunner = S.file("run-zig.sh")
const jsPropTestFile = S.file("//tests/prop/js_supplychain_prop.mjs")

// CLAUDE_P_HOST_KEY joins the action key so native outputs built on macOS
// and Linux (or x64 and arm64) never share a cache entry.
const zigEnv = {
  CLAUDE_P_HOST_KEY: `${process.platform}-${process.arch}-zig-0.15.2`,
  ZIG_GLOBAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/global", import.meta.url)),
  ZIG_LOCAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/local", import.meta.url))
}

const zigCommon = {
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("zig")],
  env: zigEnv,
  sandbox: "none" as const,
  timeout: "15m" as const
}

const hygiene = S.Shell.Test({
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("node")],
  args: ["-eu", "-c", "test -s LICENSE && node scripts/publish.mjs --check-versions"],
  sandbox: "none",
  timeout: "2m",
  data: [versionSources]
})

const testJs = S.Shell.Test({
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("node")],
  args: [
    "-eu",
    "-c",
    "node --check scripts/install.js && node --check scripts/publish.mjs && node --check scripts/smithers-auth.mjs && node --check bin/claude-p.js && sh -n scripts/build-in-linux.sh && bash -n scripts/fuzz-linux.sh && sh -n scripts/smthrs && node --test .smithers/tests/install-checksum.test.mjs .smithers/tests/factory-projections.test.mjs .smithers/tests/trust-boundaries.test.mjs tests/prop/js_supplychain_prop.mjs"
  ],
  sandbox: "none",
  timeout: "2m",
  data: [jsSources, versionSources, factorySources, workflowSources, jsPropTestFile]
})

const trustCheck = S.Shell.Test({
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("node")],
  args: [
    "-eu",
    "-c",
    "node --test .smithers/tests/trust-boundaries.test.mjs && node scripts/smithers-auth.mjs --dry-run --format json >/dev/null"
  ],
  sandbox: "none",
  timeout: "2m",
  data: [factorySources, workflowSources, S.file("//scripts/smithers-auth.mjs")]
})

const wikiCheck = S.Shell.Test({
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("node")],
  args: ["-eu", "-c", "node .smithers/flows/wiki/sync-wiki.mjs --check"],
  sandbox: "none",
  timeout: "2m",
  data: [factorySources, zigSources, jsSources, S.file("//README.md"), S.file("//SPEC.md"), S.file("//CLAUDE.md"), workflowSources, uphillSources]
})

const historyCheck = S.Shell.Test({
  bin: S.Host.bin("sh"),
  tools: [S.Host.bin("node")],
  args: ["-eu", "-c", "node .smithers/flows/mythical-history/generate.mjs --check"],
  sandbox: "none",
  timeout: "2m",
  data: [factorySources, S.file("//package.json")]
})

const build = S.Shell.Build({
  ...zigCommon,
  args: [".smithers/run-zig.sh", "build", "-Doptimize=ReleaseSafe", "-p", "zig-out/native"],
  data: [zigSources, zigRunner],
  outDirs: ["//zig-out/native"]
})

// src/main.zig's process-group signal test reads bin/claude-p.js.
const testUnit = S.Shell.Test({
  ...zigCommon,
  args: [".smithers/run-zig.sh", "build", "test", "--summary", "all"],
  data: [zigSources, zigRunner, S.file("//bin/claude-p.js")]
})

const crossBuild = (name: string, target: string) =>
  S.Shell.Build({
    ...zigCommon,
    args: [
      ".smithers/run-zig.sh",
      "build",
      "-Doptimize=ReleaseSafe",
      `-Dtarget=${target}`,
      "-p",
      `zig-out/cross-${name}`
    ],
    data: [zigSources, zigRunner],
    outDirs: [`//zig-out/cross-${name}`]
  })

const buildLinuxX64 = crossBuild("linux-x64", "x86_64-linux-musl")
const buildLinuxArm64 = crossBuild("linux-arm64", "aarch64-linux-musl")
const buildDarwinArm64 = crossBuild("darwin-arm64", "aarch64-macos")
const buildDarwinX64 = crossBuild("darwin-x64", "x86_64-macos")

// Lighthouse-style Uphill backpressure audit (manual Run target so local
// environments without ~/.uphill/bin/uphill still pass fast `smthrs ci //...`).
const audit = S.Shell.Run({
  shell: "node .smithers/audit/generate-lighthouse.mjs",
  tools: [S.Host.bin("node"), S.Host.bin("bun"), S.Host.bin("zig")],
  sandbox: "none",
  timeout: "10m",
  data: [zigSources, jsSources, factorySources, uphillSources, docsSources],
  manual: true
})

// Real-Claude E2E suite (0 mocks). Declared as a manual Run target so fast
// local/CI `smthrs ci //...` remains completely offline and zero-cost; run
// explicitly on demand via `scripts/smthrs run //.smithers:test-e2e`.
const testE2e = S.Shell.Run({
  shell: "env -u ANTHROPIC_API_KEY CLAUDE_P_E2E=1 sh .smithers/run-zig.sh build test-integration --summary all",
  tools: [S.Host.bin("zig")],
  env: zigEnv,
  sandbox: "none",
  timeout: "20m",
  data: [zigSources, zigRunner],
  manual: true
})

export const Package = S.Package({
  targets: {
    "zig-sources": zigSources,
    "js-sources": jsSources,
    "version-sources": versionSources,
    "workflow-sources": workflowSources,
    "factory-sources": factorySources,
    "uphill-sources": uphillSources,
    "docs-sources": docsSources,
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" }),
    hygiene,
    "test-js": testJs,
    "trust-check": trustCheck,
    "wiki-check": wikiCheck,
    "history-check": historyCheck,
    build,
    "test-unit": testUnit,
    "build-linux-x64": buildLinuxX64,
    "build-linux-arm64": buildLinuxArm64,
    "build-darwin-arm64": buildDarwinArm64,
    "build-darwin-x64": buildDarwinX64,
    audit,
    "test-e2e": testE2e
  }
})
