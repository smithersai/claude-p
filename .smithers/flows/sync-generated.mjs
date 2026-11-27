#!/usr/bin/env node
// Writes .smithers/generated.json matching apps/mvp/src/features/generated/schema.ts
// so Smithers Cloud tracks every generated artifact with exact SHA-256 digests.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const sha256 = (rel) =>
  crypto.createHash("sha256").update(fs.readFileSync(path.join(ROOT, rel))).digest("hex");

const tracked = [
  {
    output: ".smithers/factory.json",
    flow: "factory-write",
    source: ".smithers/FACTORY.ts",
    inputs: [".smithers/FACTORY.ts", ".smithers/WORKSPACE.ts", ".smithers/PACKAGE.ts"],
  },
  {
    output: ".smithers/home.json",
    flow: "factory-write",
    source: ".smithers/FACTORY.ts",
    inputs: [".smithers/FACTORY.ts"],
  },
  {
    output: ".smithers/wiki/snapshot.json",
    flow: "wiki",
    source: ".smithers/flows/wiki/sync-wiki.mjs",
    inputs: [".smithers/coding-project.json", ".smithers/wiki/pages/index.md"],
  },
  {
    output: ".smithers/history/CHRONICLE.md",
    flow: "mythical-history",
    source: ".smithers/flows/mythical-history/generate.mjs",
    inputs: [".smithers/flows/mythical-history/generate.mjs", "package.json"],
  },
  {
    output: ".smithers/history/history.json",
    flow: "mythical-history",
    source: ".smithers/flows/mythical-history/generate.mjs",
    inputs: [".smithers/flows/mythical-history/generate.mjs", "package.json"],
  },
  {
    output: "docs/public/audit/index.html",
    flow: "uphill",
    source: ".smithers/audit/generate-lighthouse.mjs",
    inputs: [".agents/uphill/uphill.yaml", ".agents/uphill/uphill.baseline.yaml", ".smithers/trust-policy.json"],
  },
  {
    output: "docs/public/audit/audit.json",
    flow: "uphill",
    source: ".smithers/audit/generate-lighthouse.mjs",
    inputs: [".agents/uphill/uphill.yaml", ".agents/uphill/uphill.baseline.yaml", ".smithers/trust-policy.json"],
  },
  {
    output: ".agents/uphill/rules.md",
    flow: "uphill",
    source: ".agents/uphill/uphill.yaml",
    inputs: [".agents/uphill/uphill.yaml"],
  },
];

const outputs = {};
for (const entry of tracked) {
  if (!fs.existsSync(path.join(ROOT, entry.output))) continue;
  outputs[entry.output] = {
    flow: entry.flow,
    source: entry.source,
    inputs: entry.inputs
      .filter((i) => fs.existsSync(path.join(ROOT, i)))
      .map((i) => ({ path: i, sha256: sha256(i) })),
    sha256: sha256(entry.output),
  };
}

const manifest = { version: 1, outputs };
fs.writeFileSync(path.join(ROOT, ".smithers/generated.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`generated.json: recorded ${Object.keys(outputs).length} generated outputs`);
