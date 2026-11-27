// Dependency-free staleness check for .smithers/factory.json and home.json.
//
// `scripts/smthrs target //.smithers:factory-check` is the authoritative check,
// but GitHub CI may run without smthrs installed. This test re-derives the
// projected fields from flow.mdx frontmatter, flow.ts declarations, and
// FACTORY.ts literals and fails when a source changed without
// `scripts/smthrs target //.smithers:factory-write --write`.
//
// Run: node --test .smithers/tests/factory-projections.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SMITHERS_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

// Minimal frontmatter parser for the subset flow.mdx files use:
// `key: scalar`, `key: [json or bare list]`, and one level of indented maps.
export function parseFrontmatter(text) {
  const m = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!m) throw new Error("missing frontmatter");
  const out = {};
  let nested = null;
  for (const line of m[1].split("\n")) {
    if (!line.trim()) continue;
    const kv = /^(\s*)([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (!kv) throw new Error(`unparsed frontmatter line: ${line}`);
    const [, indent, key, raw] = kv;
    if (indent && nested) {
      nested[key] = scalar(raw);
    } else if (raw === "") {
      nested = out[key] = {};
    } else {
      nested = null;
      out[key] = scalar(raw);
    }
  }
  return out;
}

function scalar(raw) {
  if (raw.startsWith("[")) {
    try {
      return JSON.parse(raw);
    } catch {
      return raw
        .slice(1, -1)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    }
  }
  if (/^-?\d+$/.test(raw)) return Number(raw);
  if (raw === "true" || raw === "false") return raw === "true";
  return raw;
}

function listFlows(dir, rel = "") {
  const found = [];
  for (const ent of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
    const r = rel ? `${rel}/${ent.name}` : ent.name;
    if (ent.isDirectory()) found.push(...listFlows(dir, r));
    else if (ent.name === "flow.mdx") found.push({ id: rel, kind: "mdx", file: `flows/${rel}/flow.mdx` });
    else if (ent.name === "flow.ts") found.push({ id: rel, kind: "ts", file: `flows/${rel}/flow.ts` });
  }
  return found.sort((a, b) => a.id.localeCompare(b.id));
}

// Every double-quoted string literal in FACTORY.ts, decoded.
function stringLiterals(src) {
  return [...src.matchAll(/"(?:[^"\\\n]|\\.)*"/g)].map((x) => JSON.parse(x[0]));
}

function flowDecls(src) {
  const decls = new Map();
  for (const m of src.matchAll(/S\.Flow\(\{([\s\S]*?)\}\)/g)) {
    const body = m[1];
    const id = JSON.parse(/flow:\s*("(?:[^"\\]|\\.)*")/.exec(body)[1]);
    const summary = /summary:\s*("(?:[^"\\]|\\.)*")/.exec(body);
    decls.set(id, {
      featured: /featured:\s*true/.test(body),
      summary: summary ? JSON.parse(summary[1]) : undefined,
    });
  }
  return decls;
}

function stringLeaves(value, out = []) {
  if (typeof value === "string") out.push(value);
  else if (Array.isArray(value)) value.forEach((v) => stringLeaves(v, out));
  else if (value && typeof value === "object") Object.values(value).forEach((v) => stringLeaves(v, out));
  return out;
}

// Returns a list of human-readable staleness errors; empty means fresh.
export function checkProjections(dir = SMITHERS_DIR) {
  const errors = [];
  const factory = JSON.parse(fs.readFileSync(path.join(dir, "factory.json"), "utf8"));
  const home = JSON.parse(fs.readFileSync(path.join(dir, "home.json"), "utf8"));
  const src = fs.readFileSync(path.join(dir, "FACTORY.ts"), "utf8");

  const projected = new Map(factory.flows.map((f) => [f.id, f]));
  const onDisk = listFlows(path.join(dir, "flows"));
  const onDiskIds = new Set(onDisk.map((f) => f.id));

  for (const flow of onDisk) {
    if (!projected.has(flow.id)) errors.push(`${flow.file} is not in factory.json`);
  }
  for (const id of projected.keys()) {
    if (!onDiskIds.has(id)) errors.push(`factory.json flow ${id} has no flow file on disk`);
  }

  for (const flow of onDisk) {
    const entry = projected.get(flow.id);
    if (!entry) continue;
    const expectedPath = `.smithers/${flow.file}`;
    if (entry.path !== expectedPath) {
      errors.push(`factory.json ${flow.id}.path is stale: ${entry.path} != ${expectedPath}`);
    }
    if (entry.kind !== flow.kind) {
      errors.push(`factory.json ${flow.id}.kind is stale: ${entry.kind} != ${flow.kind}`);
    }
    if (flow.kind === "mdx") {
      const fm = parseFrontmatter(fs.readFileSync(path.join(dir, flow.file), "utf8"));
      const want = {
        description: fm.description,
        capabilities: fm.capabilities ?? [],
        model: fm.model ?? null,
        flows: fm.flows ?? [],
        budget: fm.budget,
      };
      for (const [key, value] of Object.entries(want)) {
        try {
          assert.deepEqual(entry[key], value);
        } catch {
          errors.push(`factory.json ${flow.id}.${key} is stale: ${JSON.stringify(entry[key])} != ${JSON.stringify(value)}`);
        }
      }
    } else if (flow.kind === "ts") {
      const tsSrc = fs.readFileSync(path.join(dir, flow.file), "utf8");
      if (!tsSrc.includes(`Flow.make("${flow.id}"`)) {
        errors.push(`${flow.file} does not declare Flow.make("${flow.id}")`);
      }
      if (!entry.description || typeof entry.description !== "string") {
        errors.push(`factory.json ${flow.id}.description is missing`);
      }
    }
  }

  const decls = flowDecls(src);
  for (const [id, decl] of decls) {
    const entry = projected.get(id);
    if (!entry) {
      errors.push(`FACTORY.ts declares ${id}, factory.json lacks it`);
      continue;
    }
    if (entry.summary !== decl.summary) errors.push(`factory.json ${id}.summary is stale`);
    if (Boolean(entry.featured) !== decl.featured) errors.push(`factory.json ${id}.featured is stale`);
  }

  // Factory- and home-level fields: every projected string must still be a
  // literal in FACTORY.ts, and every FACTORY.ts literal under S.Factory.Home
  // must still be projected.
  const literals = new Set(stringLiterals(src));
  const factoryTop = { ...factory, flows: undefined };
  for (const s of stringLeaves(factoryTop)) {
    if (!literals.has(s)) errors.push(`factory.json value ${JSON.stringify(s)} is not in FACTORY.ts`);
  }
  const factoryStart = src.indexOf("S.Factory({");
  const factoryEnd = src.indexOf("S.Factory.Home(");
  if (factoryStart < 0 || factoryEnd < factoryStart) {
    errors.push("FACTORY.ts has no S.Factory({...}) before S.Factory.Home(...)");
  } else {
    const factorySrc = src.slice(factoryStart, factoryEnd).replace(/^\s*flows:[\s\S]*?\],/m, "");
    const topSet = new Set(stringLeaves(factoryTop));
    for (const s of stringLiterals(factorySrc)) {
      if (!topSet.has(s)) errors.push(`FACTORY.ts factory literal ${JSON.stringify(s)} is not in factory.json`);
    }
    for (const [, key] of factorySrc.matchAll(/^ {2}([A-Za-z_]\w*):/gm)) {
      if (key !== "flows" && !(key in factory)) errors.push(`FACTORY.ts factory key ${key} is not in factory.json`);
    }
    const policy = /S\.Github\.Policy\(\{([\s\S]*?)\n {2}\}\)/.exec(factorySrc);
    if (policy) {
      for (const [, key] of policy[1].matchAll(/^ {4}([A-Za-z_]\w*):/gm)) {
        if (!factory.github || !(key in factory.github)) errors.push(`FACTORY.ts github.${key} is not in factory.json`);
      }
    }
  }

  const homeLeaves = stringLeaves(home);
  for (const s of homeLeaves) {
    if (!literals.has(s)) errors.push(`home.json value ${JSON.stringify(s)} is not in FACTORY.ts`);
  }
  const homeSrc = src.slice(src.indexOf("S.Factory.Home("));
  const homeSet = new Set(homeLeaves);
  for (const s of stringLiterals(homeSrc)) {
    if (!homeSet.has(s)) errors.push(`FACTORY.ts home literal ${JSON.stringify(s)} is not in home.json`);
  }

  // Personalized multi-audience UI checks
  if (!Array.isArray(home.sections) || home.sections.length === 0) {
    errors.push("home.json must declare personalized sections (maintainer, contributor, everyone)");
  } else {
    const audiences = new Set(home.sections.map((s) => s.audience ?? "everyone"));
    for (const required of ["maintainer", "contributor", "everyone"]) {
      if (!audiences.has(required)) errors.push(`home.json missing audience section: ${required}`);
    }
    const totalBlocks = home.sections.reduce((n, s) => n + (s.blocks?.length ?? 0), 0);
    if (totalBlocks > 32) errors.push(`home.json has ${totalBlocks} blocks (limit 32)`);
    if (home.sections.length > 8) errors.push(`home.json has ${home.sections.length} sections (limit 8)`);
  }
  if (!home.docs || !home.docs.startsWith("https://")) {
    errors.push("home.json must declare an https:// docs llms.txt index");
  }

  return errors;
}

test("factory.json and home.json match their sources", () => {
  assert.deepEqual(checkProjections(), []);
});

function tamperedCopy(edit) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "claude-p-factory-"));
  fs.cpSync(SMITHERS_DIR, dir, {
    recursive: true,
    filter: (p) => !["cache", "reports"].includes(path.relative(SMITHERS_DIR, p).split(path.sep)[0]),
  });
  edit(dir);
  return dir;
}

test("a changed flow capability is reported stale", () => {
  const dir = tamperedCopy((d) => {
    const p = path.join(d, "flows/issue/poc/flow.mdx");
    fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace('"proc:spawn:node --test *"', '"proc:spawn:node *"'));
  });
  try {
    assert.ok(checkProjections(dir).some((e) => e.includes("issue/poc.capabilities")));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a changed FACTORY.ts home title is reported stale", () => {
  const dir = tamperedCopy((d) => {
    const p = path.join(d, "FACTORY.ts");
    fs.writeFileSync(p, fs.readFileSync(p, "utf8").replace('title: "Why claude-p"', 'title: "renamed"'));
  });
  try {
    const errors = checkProjections(dir);
    assert.ok(errors.some((e) => e.includes('"Why claude-p" is not in FACTORY.ts')));
    assert.ok(errors.some((e) => e.includes('"renamed" is not in home.json')));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a new flow without a projection is reported", () => {
  const dir = tamperedCopy((d) => {
    fs.mkdirSync(path.join(d, "flows/extra"));
    fs.writeFileSync(path.join(d, "flows/extra/flow.mdx"), "---\ndescription: x\n---\nbody\n");
  });
  try {
    assert.ok(checkProjections(dir).includes("flows/extra/flow.mdx is not in factory.json"));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a deleted factory.json policy key or entry is reported stale", () => {
  const drop = (mutate) =>
    tamperedCopy((d) => {
      const p = path.join(d, "factory.json");
      const json = JSON.parse(fs.readFileSync(p, "utf8"));
      mutate(json);
      fs.writeFileSync(p, `${JSON.stringify(json, null, 2)}\n`);
    });
  const cases = [
    [(j) => delete j.github.protectedPaths, ["github.protectedPaths is not in factory.json", '"src/driver.zig" is not in factory.json']],
    [(j) => j.github.protectedPaths.pop(), ['".agents/uphill/**" is not in factory.json']],
    [(j) => delete j.github.maintainers, ["github.maintainers is not in factory.json"]],
    [(j) => delete j.on, ["factory key on is not in factory.json"]],
  ];
  for (const [mutate, wants] of cases) {
    const dir = drop(mutate);
    try {
      const errors = checkProjections(dir);
      for (const want of wants) assert.ok(errors.some((e) => e.includes(want)), `${want} in ${JSON.stringify(errors)}`);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});
