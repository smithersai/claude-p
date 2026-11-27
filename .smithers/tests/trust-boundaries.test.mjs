// Trust-boundary and cache-poisoning invariant suite for smithersai/claude-p.
// Verifies that:
// 1. Untrusted contributors are encouraged to run checks, but can NEVER write
//    to the shared trunk cache or skip merge/release gates.
// 2. Read and write object-store credentials are strictly split.
// 3. No GitHub workflow uses pull_request_target or grants cache write tokens to PRs.
// 4. Read-only triage/review flows hold zero process-spawn capabilities.
// 5. Public/user-facing home.json copy obeys house style (no semicolons/em dashes).
//
// Run: node --test .smithers/tests/trust-boundaries.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SMITHERS = path.join(ROOT, ".smithers");

const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
const readText = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

test("trust-policy.json matches FACTORY.ts and WORKSPACE.ts", () => {
  const policy = readJson(".smithers/trust-policy.json");
  const factory = readJson(".smithers/factory.json");
  const workspaceSrc = readText(".smithers/WORKSPACE.ts");

  assert.equal(policy.repository, "smithersai/claude-p");
  assert.equal(policy.objectStore.endpoint, "https://build.smithers.sh");
  assert.equal(policy.objectStore.untrustedCanWriteTrunk, false);
  assert.equal(policy.executionTiers.untrusted_contributor.encouraged, true);
  assert.equal(policy.executionTiers.untrusted_contributor.cacheWriteTrunk, false);
  assert.equal(policy.executionTiers.untrusted_contributor.canSatisfyMergeGates, false);
  assert.equal(policy.executionTiers.trusted_maintainer_sandbox.cacheWriteTrunk, true);
  assert.equal(policy.executionTiers.trusted_maintainer_sandbox.canSatisfyMergeGates, true);

  assert.deepEqual(policy.maintainers, factory.github.maintainers);
  assert.deepEqual(policy.protectedPaths, factory.github.protectedPaths);

  assert.ok(workspaceSrc.includes('endpoint: "https://build.smithers.sh"'));
  assert.ok(workspaceSrc.includes(`S.Secret("${policy.objectStore.readSecret}")`));
  assert.ok(workspaceSrc.includes(`S.Secret("${policy.objectStore.writeSecret}")`));
  assert.notEqual(policy.objectStore.readSecret, policy.objectStore.writeSecret);
});

test("read-only triage and review flows hold zero proc:spawn capabilities", () => {
  const policy = readJson(".smithers/trust-policy.json");
  const factory = readJson(".smithers/factory.json");

  for (const id of policy.readOnlyFlows) {
    const flow = factory.flows.find((f) => f.id === id);
    assert.ok(flow, `missing read-only flow ${id} in factory.json`);
    const spawnCaps = (flow.capabilities ?? []).filter((c) => c.startsWith("proc:spawn"));
    assert.deepEqual(spawnCaps, [], `${id} must never spawn processes on untrusted diffs`);
  }
});

test("release flow is never model-invocable without maintainer approval", () => {
  const factory = readJson(".smithers/factory.json");
  const release = factory.flows.find((f) => f.id === "release");
  assert.ok(release, "release flow must be registered in factory.json");
  assert.equal(release.modelInvocable, false);
  const releaseSrc = readText(".smithers/flows/release/flow.ts");
  assert.ok(releaseSrc.includes("HumanTask.action.call"), "release flow must gate publish behind HumanTask");
});

test("GitHub workflows never use pull_request_target or expose write cache token to PRs", () => {
  const wfDir = path.join(ROOT, ".github/workflows");
  for (const name of fs.readdirSync(wfDir).filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))) {
    const src = fs.readFileSync(path.join(wfDir, name), "utf8");
    assert.ok(!/^\s*pull_request_target\s*:/m.test(src), `${name} must never use pull_request_target`);
    if (src.includes("SMITHERS_CACHE_WRITE_TOKEN")) {
      assert.ok(
        src.includes("refs/heads/main") && src.includes("cache-publish"),
        `${name} may only pass SMITHERS_CACHE_WRITE_TOKEN inside a main-only cache-publish job`,
      );
    }
  }
});

test("home.json copy obeys house style (no semicolons or em dashes in UI prose)", () => {
  const home = readJson(".smithers/home.json");
  const bad = [];
  function walk(node, keyPath) {
    if (typeof node === "string") {
      // Code blocks and URLs may legitimately contain punctuation.
      if (keyPath.endsWith(".code") || keyPath.endsWith(".url") || keyPath === "docs") return;
      if (node.includes(";") || node.includes("\u2014")) {
        bad.push(`${keyPath}: ${JSON.stringify(node)}`);
      }
    } else if (Array.isArray(node)) {
      node.forEach((v, i) => walk(v, `${keyPath}[${i}]`));
    } else if (node && typeof node === "object") {
      for (const [k, v] of Object.entries(node)) walk(v, keyPath ? `${keyPath}.${k}` : k);
    }
  }
  walk(home, "");
  assert.deepEqual(bad, [], `disallowed punctuation in home.json prose:\n${bad.join("\n")}`);
});

test("protectedPaths covers all security-critical modular subdirectories", () => {
  const policy = readJson(".smithers/trust-policy.json");
  for (const required of ["src/driver/**", "src/hook/**", "src/daemon/**", "src/transcript/**", "src/args/**", "src/stdin.zig"]) {
    assert.ok(policy.protectedPaths.includes(required), `missing protectedPath ${required}`);
  }
});

test("GitHub workflows SHA-pin third-party actions and avoid inline expression injection", () => {
  const wfDir = path.join(ROOT, ".github/workflows");
  for (const name of fs.readdirSync(wfDir).filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))) {
    const src = fs.readFileSync(path.join(wfDir, name), "utf8");
    const usesLines = src.match(/^\s*-?\s*uses:\s+\S+/gm) ?? [];
    for (const line of usesLines) {
      assert.match(line, /@[0-9a-f]{40}\b/, `${name}: action must be SHA-pinned: ${line.trim()}`);
    }
    assert.ok(!/RELEASE_TAG="\$\{\{/.test(src), `${name}: pass workflow inputs via env, not inline shell interpolation`);
  }
});

test("smithers-auth rejects privileged scopes and excessive TTLs", () => {
  const script = path.join(ROOT, "scripts/smithers-auth.mjs");
  const badScope = spawnSync(process.execPath, [script, "--dry-run", "--scope", "approve:runs"], { encoding: "utf8" });
  assert.equal(badScope.status, 2);
  const badTtl = spawnSync(process.execPath, [script, "--dry-run", "--ttl", "24h"], { encoding: "utf8" });
  assert.equal(badTtl.status, 2);
  const invalidTtl = spawnSync(process.execPath, [script, "--dry-run", "--ttl", "0m"], { encoding: "utf8" });
  assert.equal(invalidTtl.status, 2);
  const good = spawnSync(process.execPath, [script, "--dry-run", "--ttl", "15m", "--format", "json"], { encoding: "utf8" });
  assert.equal(good.status, 0);
});
