#!/usr/bin/env node
// Engineering Wiki verifier and Starlight docs syncer for smithersai/claude-p.
//
// Reads .smithers/coding-project.json, verifies:
//   1. Every cataloged wiki page exists on disk.
//   2. Every declared source `inputs` path exists and computes its SHA-256 digest.
//   3. Every Obsidian [[wikilink]] resolves to a cataloged page ID.
//   4. Every backticked repo path citation (`src/...`, `scripts/...`, `.smithers/...`,
//      `.github/...`, `.agents/...`, `tests/...`, `bin/...`, `SPEC.md`, `README.md`)
//      resolves to a real file or directory on disk.
//
// With --write:
//   - Writes content-addressed freshness snapshot to .smithers/wiki/snapshot.json.
//   - Syncs every wiki page into Starlight MDX at docs/src/content/docs/wiki/<id>.mdx
//     with valid title/description frontmatter and working cross-links.
//
// Usage:
//   node .smithers/flows/wiki/sync-wiki.mjs --check
//   node .smithers/flows/wiki/sync-wiki.mjs --write
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const args = new Set(process.argv.slice(2));
const doWrite = args.has("--write");
const doCheck = args.has("--check") || !doWrite;

const catalogPath = path.join(ROOT, ".smithers/coding-project.json");
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const pageIds = new Set(catalog.pages.map((p) => p.id));

const sha256File = (rel) =>
  crypto.createHash("sha256").update(fs.readFileSync(path.join(ROOT, rel))).digest("hex");

const errors = [];
const pageSnapshots = [];

const REPO_PATH_RE =
  /`((?:src|tests|scripts|bin|\.smithers|\.github|\.agents|docs)\/[A-Za-z0-9._/-]+|(?:README|SPEC|CLAUDE|AGENTS|LICENSE)\.md|package\.json|build\.zig(?:\.zon)?)`/g;

for (const page of catalog.pages) {
  const absDoc = path.join(ROOT, page.document);
  if (!fs.existsSync(absDoc)) {
    errors.push(`missing wiki page: ${page.document}`);
    continue;
  }
  const body = fs.readFileSync(absDoc, "utf8");

  // Verify declared inputs exist and hash them
  const inputDigests = {};
  for (const inp of page.inputs ?? []) {
    const absInp = path.join(ROOT, inp);
    if (!fs.existsSync(absInp)) {
      errors.push(`${page.id}: declared input missing: ${inp}`);
    } else if (fs.statSync(absInp).isFile()) {
      inputDigests[inp] = sha256File(inp);
    }
  }

  // Verify related IDs exist
  for (const relId of page.related ?? []) {
    if (!pageIds.has(relId)) errors.push(`${page.id}: unknown related page id "${relId}"`);
  }

  // Verify Obsidian [[wikilinks]]
  for (const m of body.matchAll(/\[\[([a-z0-9-]+)(?:\|[^\]]+)?\]\]/g)) {
    if (!pageIds.has(m[1])) errors.push(`${page.id}: broken wikilink [[${m[1]}]]`);
  }

  // Verify backticked repo path citations (ignore glob patterns with * or template placeholders with <)
  for (const m of body.matchAll(REPO_PATH_RE)) {
    const cited = m[1].replace(/\/+$/, "");
    if (cited.includes("*") || cited.includes("<") || cited.includes("index.html")) continue;
    if (!fs.existsSync(path.join(ROOT, cited))) {
      errors.push(`${page.id}: broken source citation \`${cited}\``);
    }
  }

  pageSnapshots.push({
    id: page.id,
    title: page.title,
    kind: page.kind,
    document: page.document,
    sha256: sha256File(page.document),
    inputs: inputDigests,
  });
}

if (errors.length > 0) {
  console.error("wiki verification failed:");
  for (const err of errors) console.error(`  - ${err}`);
  process.exit(1);
}

const snapshotPayload = {
  version: 1,
  repository: catalog.repository,
  catalogSha256: sha256File(".smithers/coding-project.json"),
  pageCount: pageSnapshots.length,
  pages: pageSnapshots,
};
const snapshotDigest = crypto
  .createHash("sha256")
  .update(JSON.stringify(snapshotPayload))
  .digest("hex");

const fullSnapshot = {
  ...snapshotPayload,
  digest: snapshotDigest,
};

const snapshotPath = path.join(ROOT, ".smithers/wiki/snapshot.json");
const docsWikiDir = path.join(ROOT, "docs/src/content/docs/wiki");

function renderStarlightPage(page, rawMarkdown) {
  const titleMap = new Map(catalog.pages.map((p) => [p.id, p.title]));
  // Strip top H1 since Starlight renders frontmatter title as H1
  let content = rawMarkdown.replace(/^#\s+[^\n]+\n+/, "");
  // Convert [[id]] or [[id|label]] to Starlight links
  content = content.replace(/\[\[([a-z0-9-]+)(?:\|([^\]]+))?\]\]/g, (_, id, customLabel) => {
    const label = customLabel || titleMap.get(id) || id;
    const href = id === "index" ? "/claude-p/wiki/" : `/claude-p/wiki/${id}/`;
    return `[${label}](${href})`;
  });
  // Escape YAML frontmatter quotes cleanly
  const fmTitle = JSON.stringify(page.title);
  const fmDesc = JSON.stringify(page.purpose);
  const inputsList = (page.inputs ?? []).map((i) => `\`${i}\``).join(", ");
  return `---
title: ${fmTitle}
description: ${fmDesc}
---

{/* Generated from ${page.document} by .smithers/flows/wiki/sync-wiki.mjs. Edit the source wiki page instead. */}

${content.trim()}

---

<sub>Source of truth: \`${page.document}\` · Tracked inputs: ${inputsList}</sub>
`;
}

if (doWrite) {
  fs.mkdirSync(path.dirname(snapshotPath), { recursive: true });
  fs.writeFileSync(snapshotPath, `${JSON.stringify(fullSnapshot, null, 2)}\n`);

  fs.mkdirSync(docsWikiDir, { recursive: true });
  for (const page of catalog.pages) {
    const raw = fs.readFileSync(path.join(ROOT, page.document), "utf8");
    const outPath = path.join(docsWikiDir, `${page.id}.mdx`);
    fs.writeFileSync(outPath, renderStarlightPage(page, raw));
  }
  console.log(`wiki: verified and synced ${catalog.pages.length} pages (digest ${snapshotDigest.slice(0, 12)})`);
} else if (doCheck) {
  if (!fs.existsSync(snapshotPath)) {
    console.error("wiki: missing .smithers/wiki/snapshot.json (run with --write)");
    process.exit(1);
  }
  const existing = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  if (existing.digest !== snapshotDigest) {
    console.error(
      `wiki: snapshot is stale (checked-in ${existing.digest?.slice(0, 12)} != current ${snapshotDigest.slice(0, 12)}). Run: node .smithers/flows/wiki/sync-wiki.mjs --write`,
    );
    process.exit(1);
  }
  for (const page of catalog.pages) {
    const outPath = path.join(docsWikiDir, `${page.id}.mdx`);
    if (!fs.existsSync(outPath)) {
      console.error(`wiki: missing synced Starlight page ${path.relative(ROOT, outPath)} (run with --write)`);
      process.exit(1);
    }
  }
  console.log(`wiki: ${catalog.pages.length} pages verified and fresh (digest ${snapshotDigest.slice(0, 12)})`);
}
