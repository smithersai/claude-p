#!/usr/bin/env node
// Lighthouse-style interactive audit report generator for smithersai/claude-p.
//
// Combines Uphill continuous metrics (.uphill/report.json), trust-boundary
// provenance (trusted maintainer sandbox vs untrusted contributor execution),
// and repository telemetry into a self-contained HTML report modeled after
// Google Lighthouse, plus a machine-readable JSON artifact for MCP and CI.
//
// Outputs:
//   .smithers/reports/audit.html  (local artifact)
//   .smithers/reports/audit.json  (local JSON)
//   docs/public/audit/index.html  (published at https://smithersai.github.io/claude-p/audit/)
//   docs/public/audit/audit.json  (published JSON API)
//
// Usage:
//   node .smithers/audit/generate-lighthouse.mjs [--no-run] [--strict] [--skip-docs]
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const args = new Set(process.argv.slice(2));
const noRun = args.has("--no-run");
const strict = args.has("--strict");
const skipDocs = args.has("--skip-docs");

function findUphill() {
  const candidates = [
    process.env.UPHILL_BIN,
    path.join(os.homedir(), ".uphill/bin/uphill"),
    "uphill",
  ].filter(Boolean);
  for (const bin of candidates) {
    const res = spawnSync(bin, ["--version"], { encoding: "utf8" });
    if (res.status === 0) return bin;
  }
  return null;
}

if (!noRun) {
  const uphillBin = findUphill();
  if (!uphillBin) {
    console.error("audit: uphill binary not found (install uphill or pass --no-run with an existing .uphill/report.json)");
    process.exit(1);
  }
  const check = spawnSync(uphillBin, ["check"], { cwd: ROOT, stdio: "inherit" });
  if (check.status !== 0) process.exit(check.status ?? 1);
  const run = spawnSync(uphillBin, ["--compact"], { cwd: ROOT, stdio: "inherit" });
  if (run.status !== 0) process.exit(run.status ?? 1);
}

const reportPath = path.join(ROOT, ".uphill/report.json");
if (!fs.existsSync(reportPath)) {
  console.error(`audit: missing ${reportPath}`);
  process.exit(1);
}

const uphill = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
const trustPolicy = JSON.parse(fs.readFileSync(path.join(ROOT, ".smithers/trust-policy.json"), "utf8"));

function detectCommit() {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA.slice(0, 12);
  try {
    const out = execFileSync("jj", ["--no-pager", "log", "-r", "@-", "--no-graph", "-T", "commit_id.short(12)"], {
      cwd: ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (out) return out;
  } catch {
    // Fallback below if jj is unavailable in a minimal sandbox.
  }
  return "working-tree";
}

function detectTrustProvenance() {
  const explicit = process.env.SMITHERS_TRUST_TIER;
  const ghEvent = process.env.GITHUB_EVENT_NAME ?? "";
  const ghRef = process.env.GITHUB_REF ?? "";
  const ghActor = process.env.GITHUB_ACTOR ?? process.env.USER ?? "local";
  const isMaintainer = trustPolicy.maintainers.includes(ghActor);
  const isTrustedMainCi = ghEvent === "push" && ghRef === "refs/heads/main";
  const isTrustedSandbox =
    explicit === "trusted_maintainer_sandbox" ||
    isTrustedMainCi ||
    (process.env.SMITHERS_SANDBOX_TRUSTED === "1" && isMaintainer);

  if (isTrustedSandbox) {
    return {
      tier: "trusted_maintainer_sandbox",
      label: "Trusted Maintainer Sandbox",
      badgeClass: "trusted",
      actor: ghActor,
      cacheMode: "Read + Trunk Write (build.smithers.sh)",
      gateAuthority: "Authoritative for merge and release gates",
      note: "Executed inside a maintainer-controlled environment. Verified artifacts may populate the shared Smithers Cloud object store.",
    };
  }
  return {
    tier: "untrusted_contributor",
    label: "Untrusted / Local Execution",
    badgeClass: "untrusted",
    actor: ghActor,
    cacheMode: "Read-Only Trunk + Isolated Namespace",
    gateAuthority: "Informational only (cannot skip maintainer sandbox gates)",
    note: "Non-maintainer and local runs are welcomed and encouraged. Results read shared cache hits but never write trunk keys or bypass gates.",
  };
}

function bandOf(score) {
  if (score === null || score === undefined) return "none";
  if (score >= 90) return "good";
  if (score >= 50) return "average";
  return "poor";
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatMetricValue(val, kind, unit) {
  if (typeof val === "boolean") return val ? "pass" : "fail";
  if (val === null || val === undefined) return "—";
  if (kind === "bytes" || unit === "B") {
    const n = Number(val);
    if (Number.isFinite(n)) {
      if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)} MB`;
      if (n >= 1_000) return `${(n / 1_000).toFixed(1)} kB`;
      return `${n} B`;
    }
  }
  return unit ? `${val}${unit}` : String(val);
}

function evaluateItem(entry, metric) {
  const kind = metric.kind ?? "count";
  const better = metric.better ?? "lower";
  const target = entry.target ?? metric.target ?? metric.default ?? null;
  const val = entry.value;

  if (kind === "bool" || typeof val === "boolean") {
    const ok = val === true || val === 1 || val === "pass";
    return { passed: ok, score: ok ? 100 : 0, target };
  }
  const numVal = Number(val);
  const numTarget = target !== null ? Number(target) : null;
  if (Number.isFinite(numVal) && numTarget !== null && Number.isFinite(numTarget)) {
    const ok = better === "higher" ? numVal >= numTarget : numVal <= numTarget;
    let score = ok ? 100 : 50;
    if (!ok) {
      if (better === "higher" && numTarget > 0) {
        score = Math.max(0, Math.min(89, Math.round((numVal / numTarget) * 90)));
      } else if (better === "lower" && numVal > 0 && numTarget > 0) {
        score = Math.max(0, Math.min(89, Math.round((numTarget / numVal) * 90)));
      } else {
        score = 0;
      }
    }
    return { passed: ok, score, target };
  }
  const fallbackScore = typeof entry.score === "number" ? Math.round(entry.score) : typeof metric.score === "number" ? Math.round(metric.score) : 100;
  return { passed: fallbackScore >= 90, score: fallbackScore, target };
}

function normalizeCategories(raw) {
  const cats = Array.isArray(raw.categories) ? raw.categories : [];
  return cats.map((cat) => {
    const id = cat.name ?? cat.id ?? String(cat.title ?? "category").toLowerCase().replace(/[^a-z0-9]+/g, "-");
    const score = typeof cat.score === "number" ? Math.round(cat.score) : null;
    const rawItems = [];
    for (const metric of cat.metrics ?? []) {
      const mName = metric.name ?? metric.id ?? "metric";
      const mDesc = metric.description ?? "";
      const kind = metric.kind ?? "count";
      const unit = metric.unit ?? null;
      const entries = Array.isArray(metric.items) && metric.items.length > 0
        ? metric.items
        : [{ name: "", value: metric.value, target: metric.target, baseline: metric.baseline, note: metric.note, score: metric.score }];
      for (const entry of entries) {
        const evalRes = evaluateItem(entry, metric);
        const itemLabel = entry.name ?? entry.item ?? "";
        const formattedVal = formatMetricValue(entry.value, kind, unit);
        const formattedTarget =
          kind === "bool" || evalRes.target === null || evalRes.target === undefined
            ? ""
            : formatMetricValue(evalRes.target, kind, unit);
        const formattedBaseline =
          entry.baseline === null || entry.baseline === undefined
            ? ""
            : formatMetricValue(entry.baseline, kind, unit);
        rawItems.push({
          metric: mName,
          item: itemLabel === mName ? "" : String(itemLabel),
          description: mDesc,
          value: formattedVal,
          target: formattedTarget,
          baseline: formattedBaseline,
          score: evalRes.score,
          band: evalRes.passed ? "good" : bandOf(evalRes.score),
          passed: evalRes.passed,
          note: entry.note ? String(entry.note) : "",
        });
      }
    }
    return {
      id,
      title: cat.title ?? id,
      description: cat.description ?? "",
      score,
      band: bandOf(score),
      items: rawItems,
      passedCount: rawItems.filter((i) => i.passed).length,
      failedCount: rawItems.filter((i) => !i.passed).length,
    };
  });
}

const categories = normalizeCategories(uphill);
const numericScores = categories.map((c) => c.score).filter((s) => typeof s === "number");
const overallScore =
  numericScores.length > 0 ? Math.round(numericScores.reduce((a, b) => a + b, 0) / numericScores.length) : 0;

const opportunities = (Array.isArray(uphill.opportunities) ? uphill.opportunities : []).map((opp) => ({
  gain: Number(opp.gain ?? opp.points ?? opp.delta ?? 0),
  category: String(opp.category ?? ""),
  metric: String(opp.metric ?? ""),
  item: opp.item ? String(opp.item) : opp.items ? `${opp.items} items` : "",
  from: opp.value ?? opp.from ?? opp.current ?? "",
  to: opp.target ?? opp.to ?? "",
  label: opp.label ?? `${opp.category ?? ""} ${opp.metric ?? ""} ${opp.item ?? ""}`.trim(),
}));

const changes = Array.isArray(uphill.changes) ? uphill.changes : [];
const provenance = detectTrustProvenance();
const commit = detectCommit();
const generatedAt = new Date().toISOString();

const auditPayload = {
  schema: "smithers-lighthouse-audit/v1",
  repository: trustPolicy.repository,
  version: pkg.version,
  commit,
  generatedAt,
  overallScore,
  overallBand: bandOf(overallScore),
  provenance,
  objectStore: trustPolicy.objectStore.endpoint,
  mcpEndpoint: trustPolicy.mcpEndpoint,
  categories,
  opportunities,
  changes,
};

function renderGauge(score, label, size = 112, href = "") {
  const band = bandOf(score);
  const r = 44;
  const circ = 2 * Math.PI * r;
  const pct = typeof score === "number" ? Math.max(0, Math.min(100, score)) : 0;
  const dash = ((pct / 100) * circ).toFixed(2);
  const tag = href ? "a" : "div";
  const attr = href ? ` href="${escapeHtml(href)}"` : "";
  return `<${tag}${attr} class="lh-gauge lh-${band}" style="--size:${size}px" aria-label="${escapeHtml(label)}: ${score ?? "n/a"}">
  <div class="lh-gauge-ring">
    <svg viewBox="0 0 100 100" width="${size}" height="${size}">
      <circle class="lh-base" cx="50" cy="50" r="${r}" />
      <circle class="lh-arc" cx="50" cy="50" r="${r}" stroke-dasharray="${dash} ${circ.toFixed(2)}" transform="rotate(-90 50 50)" />
    </svg>
    <span class="lh-score">${score ?? "—"}</span>
  </div>
  <span class="lh-label">${escapeHtml(label)}</span>
</${tag}>`;
}

function renderHtml(data) {
  const maxOpp = Math.max(1, ...data.opportunities.map((o) => o.gain || 0));
  const categoryCards = data.categories
    .map((cat) => {
      const failed = cat.items.filter((i) => !i.passed);
      const passed = cat.items.filter((i) => i.passed);
      const renderRow = (item) => `<div class="audit-row status-${item.band}" data-status="${item.passed ? "passed" : "missed"}">
        <span class="audit-icon icon-${item.band}" aria-hidden="true"></span>
        <div class="audit-main">
          <div class="audit-title">
            <code>${escapeHtml(item.metric)}</code>
            ${item.item ? `<span class="audit-item">${escapeHtml(item.item)}</span>` : ""}
          </div>
          ${item.note ? `<div class="audit-note">${escapeHtml(item.note)}</div>` : item.description ? `<div class="audit-desc">${escapeHtml(item.description)}</div>` : ""}
        </div>
        <div class="audit-metrics">
          <span class="pill pill-${item.band}">${escapeHtml(item.value)}</span>
          ${item.target ? `<span class="meta-chip">target ${escapeHtml(item.target)}</span>` : ""}
          ${item.baseline ? `<span class="meta-chip">base ${escapeHtml(item.baseline)}</span>` : ""}
        </div>
      </div>`;

      return `<section class="cat-section" id="cat-${escapeHtml(cat.id)}" data-category="${escapeHtml(cat.id)}">
        <div class="cat-header">
          ${renderGauge(cat.score, cat.title, 96)}
          <div class="cat-meta">
            <h2>${escapeHtml(cat.title)}</h2>
            <p>${escapeHtml(cat.description)}</p>
            <div class="cat-counts">
              <span class="pill pill-good">${cat.passedCount} passed</span>
              ${cat.failedCount > 0 ? `<span class="pill pill-poor">${cat.failedCount} missed target</span>` : `<span class="pill pill-good">0 missed targets</span>`}
            </div>
          </div>
        </div>
        ${failed.length > 0 ? `<div class="audit-group"><h3>Diagnostics and missed targets (${failed.length})</h3>${failed.map(renderRow).join("")}</div>` : ""}
        <details class="audit-group passed-group" ${failed.length === 0 ? "open" : ""}>
          <summary>Passed audits (${passed.length})</summary>
          <div class="passed-list">${passed.map(renderRow).join("")}</div>
        </details>
      </section>`;
    })
    .join("\n");

  const oppRows = data.opportunities.length > 0
    ? data.opportunities
        .map((o) => {
          const width = Math.max(8, Math.round(((o.gain || 0) / maxOpp) * 100));
          return `<div class="opp-row">
            <div class="opp-gain">+${escapeHtml(o.gain)}</div>
            <div class="opp-body">
              <div class="opp-title"><code>${escapeHtml(o.category)}</code> / <code>${escapeHtml(o.metric)}</code> ${o.item ? `<span class="audit-item">${escapeHtml(o.item)}</span>` : ""}</div>
              <div class="opp-bar-track"><div class="opp-bar-fill" style="width:${width}%"></div></div>
            </div>
            <div class="opp-delta">${escapeHtml(o.from)} &rarr; ${escapeHtml(o.to)}</div>
          </div>`;
        })
        .join("")
    : `<div class="empty-good">All active Uphill opportunities are cleared. Every category is at or near target.</div>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>claude-p Lighthouse Backpressure Audit (${data.overallScore}/100)</title>
<style>
:root {
  --bg: #ffffff;
  --surface: #f8f9fa;
  --surface-2: #f1f3f4;
  --fg: #1f2328;
  --muted: #5f6368;
  --line: #dadce0;
  --accent: #1a73e8;
  --good: #0cce6b;
  --good-fg: #00803c;
  --good-bg: rgba(12, 206, 107, 0.14);
  --average: #ffa400;
  --average-fg: #b25e00;
  --average-bg: rgba(255, 164, 0, 0.16);
  --poor: #ff4e42;
  --poor-fg: #c5221f;
  --poor-bg: rgba(255, 78, 66, 0.14);
  --none: #9aa0a6;
  --none-fg: #5f6368;
  --none-bg: rgba(154, 160, 166, 0.16);
  --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
[data-theme="dark"] {
  --bg: #111317;
  --surface: #181b21;
  --surface-2: #20242c;
  --fg: #e8eaed;
  --muted: #9aa0a6;
  --line: #2d323b;
  --accent: #8ab4f8;
  --good-fg: #0cce6b;
  --average-fg: #ffb74d;
  --poor-fg: #ff6b61;
  --none-fg: #9aa0a6;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #111317;
    --surface: #181b21;
    --surface-2: #20242c;
    --fg: #e8eaed;
    --muted: #9aa0a6;
    --line: #2d323b;
    --accent: #8ab4f8;
    --good-fg: #0cce6b;
    --average-fg: #ffb74d;
    --poor-fg: #ff6b61;
    --none-fg: #9aa0a6;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
code { font-family: var(--mono); font-size: 12.5px; background: var(--surface-2); padding: 1px 5px; border-radius: 4px; }
.topbar { position: sticky; top: 0; z-index: 20; background: var(--bg); border-bottom: 1px solid var(--line); backdrop-filter: blur(8px); }
.topbar-inner { max-width: 1120px; margin: 0 auto; padding: 12px 20px; display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; }
.brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 15px; }
.brand-dot { width: 10px; height: 10px; border-radius: 50%; background: var(--good); box-shadow: 0 0 0 4px var(--good-bg); }
.nav-links { display: flex; flex-wrap: wrap; align-items: center; gap: 14px; font-size: 13px; }
.btn { font: inherit; font-size: 12.5px; font-weight: 600; padding: 5px 10px; border-radius: 6px; border: 1px solid var(--line); background: var(--surface); color: var(--fg); cursor: pointer; }
.btn:hover { background: var(--surface-2); }
main { max-width: 1120px; margin: 0 auto; padding: 24px 20px 80px; }
.hero { display: grid; grid-template-columns: 1fr auto; gap: 24px; align-items: center; padding: 24px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); margin-bottom: 20px; }
@media (max-width: 720px) { .hero { grid-template-columns: 1fr; } }
.hero h1 { margin: 0 0 6px; font-size: 24px; letter-spacing: -0.02em; }
.hero p { margin: 0 0 12px; color: var(--muted); max-width: 68ch; }
.meta-row { display: flex; flex-wrap: wrap; gap: 8px; }
.meta-chip { font-family: var(--mono); font-size: 11.5px; padding: 2px 8px; border-radius: 999px; background: var(--surface-2); color: var(--muted); border: 1px solid var(--line); }
.trust-banner { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 16px; border-radius: 10px; border: 1px solid var(--line); margin-bottom: 22px; }
.trust-banner.trusted { background: var(--good-bg); border-color: var(--good); }
.trust-banner.untrusted { background: var(--average-bg); border-color: var(--average); }
.trust-title { font-weight: 700; font-size: 13.5px; }
.trust-detail { font-size: 12.5px; color: var(--muted); margin-top: 2px; }
.gauges-panel { padding: 20px 16px 14px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); margin-bottom: 22px; }
.gauges-grid { display: flex; flex-wrap: wrap; justify-content: center; gap: 18px 28px; }
.lh-gauge { display: inline-flex; flex-direction: column; align-items: center; gap: 8px; color: var(--fg); text-decoration: none; min-width: 116px; padding: 6px; border-radius: 10px; transition: background 0.15s ease; }
.lh-gauge:hover { background: var(--surface-2); text-decoration: none; }
.lh-gauge-ring { position: relative; width: var(--size); height: var(--size); }
.lh-gauge-ring svg { display: block; width: 100%; height: 100%; }
.lh-base { fill: transparent; stroke: var(--line); stroke-width: 7; opacity: 0.45; }
.lh-good .lh-base { fill: var(--good-bg); stroke: var(--good-bg); opacity: 1; }
.lh-average .lh-base { fill: var(--average-bg); stroke: var(--average-bg); opacity: 1; }
.lh-poor .lh-base { fill: var(--poor-bg); stroke: var(--poor-bg); opacity: 1; }
.lh-arc { fill: none; stroke-width: 7; stroke-linecap: round; animation: lh-draw 0.8s ease-out; }
.lh-good .lh-arc { stroke: var(--good); }
.lh-average .lh-arc { stroke: var(--average); }
.lh-poor .lh-arc { stroke: var(--poor); }
.lh-none .lh-arc { stroke: var(--none); }
.lh-score { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; font-family: var(--mono); font-weight: 700; font-size: calc(var(--size) * 0.28); }
.lh-good .lh-score { color: var(--good-fg); }
.lh-average .lh-score { color: var(--average-fg); }
.lh-poor .lh-score { color: var(--poor-fg); }
.lh-label { font-size: 13px; font-weight: 600; text-align: center; }
@keyframes lh-draw { from { stroke-dasharray: 0 300; } }
.scale { display: flex; justify-content: center; gap: 20px; margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--line); font-size: 12px; color: var(--muted); }
.scale span { display: inline-flex; align-items: center; gap: 6px; }
.icon-good, .icon-average, .icon-poor, .icon-none { display: inline-block; flex: 0 0 auto; }
.icon-good { width: 11px; height: 11px; border-radius: 50%; background: var(--good); }
.icon-average { width: 11px; height: 11px; border-radius: 2px; background: var(--average); }
.icon-poor { width: 0; height: 0; border-left: 6px solid transparent; border-right: 6px solid transparent; border-bottom: 11px solid var(--poor); }
.icon-none { width: 11px; height: 11px; border-radius: 50%; border: 2px solid var(--none); }
.toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 18px; }
.tabs { display: flex; flex-wrap: wrap; gap: 6px; }
.tab { font: inherit; font-size: 12.5px; font-weight: 600; padding: 6px 12px; border-radius: 999px; border: 1px solid var(--line); background: var(--surface); color: var(--muted); cursor: pointer; }
.tab.active { background: var(--fg); color: var(--bg); border-color: var(--fg); }
.filter-bar { display: flex; gap: 8px; align-items: center; }
.search { font: inherit; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--line); background: var(--surface); color: var(--fg); min-width: 210px; }
.card { border: 1px solid var(--line); border-radius: 14px; background: var(--surface); padding: 18px 20px; margin-bottom: 20px; }
.card h2 { margin: 0 0 12px; font-size: 16px; }
.opp-row { display: grid; grid-template-columns: 54px 1fr 130px; gap: 12px; align-items: center; padding: 8px 0; border-bottom: 1px solid var(--line); }
.opp-row:last-child { border-bottom: 0; }
.opp-gain { font-family: var(--mono); font-weight: 700; color: var(--good-fg); text-align: right; }
.opp-title { font-size: 13px; margin-bottom: 5px; }
.opp-bar-track { height: 7px; border-radius: 999px; background: var(--surface-2); overflow: hidden; }
.opp-bar-fill { height: 100%; border-radius: 999px; background: linear-gradient(90deg, var(--average), var(--poor)); }
.opp-delta { font-family: var(--mono); font-size: 12px; color: var(--muted); text-align: right; }
.empty-good { padding: 12px; border-radius: 8px; background: var(--good-bg); color: var(--good-fg); font-weight: 600; }
.cat-section { border: 1px solid var(--line); border-radius: 14px; background: var(--surface); padding: 20px; margin-bottom: 20px; }
.cat-header { display: flex; flex-wrap: wrap; align-items: center; gap: 20px; padding-bottom: 16px; border-bottom: 1px solid var(--line); margin-bottom: 14px; }
.cat-meta h2 { margin: 0 0 4px; font-size: 19px; }
.cat-meta p { margin: 0 0 8px; color: var(--muted); max-width: 66ch; }
.cat-counts { display: flex; gap: 8px; }
.pill { display: inline-flex; align-items: center; padding: 2px 8px; border-radius: 999px; font-family: var(--mono); font-size: 11.5px; font-weight: 600; }
.pill-good { background: var(--good-bg); color: var(--good-fg); }
.pill-average { background: var(--average-bg); color: var(--average-fg); }
.pill-poor { background: var(--poor-bg); color: var(--poor-fg); }
.pill-none { background: var(--none-bg); color: var(--none-fg); }
.audit-group h3 { font-size: 11.5px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin: 12px 0 6px; }
.audit-group summary { cursor: pointer; font-weight: 600; font-size: 13px; color: var(--muted); padding: 8px 0; user-select: none; }
.audit-row { display: grid; grid-template-columns: 16px 1fr auto; gap: 12px; align-items: start; padding: 10px 4px; border-bottom: 1px solid var(--line); }
.audit-row:last-child { border-bottom: 0; }
.audit-title { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.audit-item { font-family: var(--mono); font-size: 12px; color: var(--muted); }
.audit-note { font-size: 12.5px; color: var(--poor-fg); margin-top: 3px; }
.audit-desc { font-size: 12.5px; color: var(--muted); margin-top: 3px; }
.audit-metrics { display: flex; flex-wrap: wrap; gap: 6px; justify-content: flex-end; }
.trust-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; }
.trust-box { border: 1px solid var(--line); border-radius: 10px; padding: 14px; background: var(--bg); }
.trust-box h3 { margin: 0 0 6px; font-size: 14px; }
.trust-box p { margin: 0; font-size: 12.5px; color: var(--muted); }
.hidden { display: none !important; }
footer { margin-top: 32px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 12px; display: flex; flex-wrap: wrap; justify-content: space-between; gap: 10px; }
</style>
</head>
<body>
<header class="topbar">
  <div class="topbar-inner">
    <div class="brand">
      <span class="brand-dot"></span>
      <span>smithersai/claude-p</span>
      <span class="meta-chip">Lighthouse Backpressure Audit</span>
    </div>
    <nav class="nav-links">
      <a href="https://smithers.sh/smithersai/claude-p">Smithers Factory</a>
      <a href="https://smithersai.github.io/claude-p/">Docs</a>
      <a href="https://smithersai.github.io/claude-p/wiki/">Wiki</a>
      <a href="https://smithersai.github.io/claude-p/history/">Mythical History</a>
      <a href="./audit.json">JSON</a>
      <button class="btn" id="theme-toggle" type="button">Theme</button>
    </nav>
  </div>
</header>
<main>
  <section class="hero">
    <div>
      <h1>Backpressure Audit Report</h1>
      <p>Continuous Uphill measurements across Zig footprint, TigerStyle invariants, correctness, unit and fuzz testing, documentation coverage, and Smithers Cloud trust boundaries.</p>
      <div class="meta-row">
        <span class="meta-chip">v${escapeHtml(data.version)}</span>
        <span class="meta-chip">commit ${escapeHtml(data.commit)}</span>
        <span class="meta-chip">store ${escapeHtml(data.objectStore)}</span>
        <span class="meta-chip">mcp ${escapeHtml(data.mcpEndpoint)}</span>
        <span class="meta-chip">${escapeHtml(data.generatedAt)}</span>
      </div>
    </div>
    ${renderGauge(data.overallScore, "Overall", 124)}
  </section>

  <section class="trust-banner ${escapeHtml(data.provenance.badgeClass)}">
    <div>
      <div class="trust-title">Execution Provenance: ${escapeHtml(data.provenance.label)} (actor: ${escapeHtml(data.provenance.actor)})</div>
      <div class="trust-detail">${escapeHtml(data.provenance.note)}</div>
    </div>
    <div class="meta-row">
      <span class="meta-chip">${escapeHtml(data.provenance.cacheMode)}</span>
      <span class="meta-chip">${escapeHtml(data.provenance.gateAuthority)}</span>
    </div>
  </section>

  <section class="gauges-panel">
    <div class="gauges-grid">
      ${data.categories.map((c) => renderGauge(c.score, c.title, 100, `#cat-${c.id}`)).join("")}
    </div>
    <div class="scale">
      <span><i class="icon-poor"></i> 0–49 Poor</span>
      <span><i class="icon-average"></i> 50–89 Needs work</span>
      <span><i class="icon-good"></i> 90–100 Good</span>
    </div>
  </section>

  <section class="card">
    <h2>Top Score Opportunities</h2>
    ${oppRows}
  </section>

  <div class="toolbar">
    <div class="tabs" role="tablist">
      <button class="tab active" data-filter-cat="all" type="button">All Categories</button>
      ${data.categories.map((c) => `<button class="tab" data-filter-cat="${escapeHtml(c.id)}" type="button">${escapeHtml(c.title)} (${c.score ?? "—"})</button>`).join("")}
    </div>
    <div class="filter-bar">
      <button class="btn" id="missed-only" type="button">Missed only: Off</button>
      <input class="search" id="audit-search" type="search" placeholder="Filter metrics or files..." aria-label="Filter audits">
    </div>
  </div>

  <div id="categories-root">
    ${categoryCards}
  </div>

  <section class="card">
    <h2>Execution Trust Boundary Policy</h2>
    <div class="trust-grid">
      <div class="trust-box">
        <h3>Trusted Maintainer Sandboxes</h3>
        <p>Maintainer-controlled sandboxes and main-branch cache-publish jobs hold read and trunk write credentials for <code>build.smithers.sh</code> and satisfy merge and release gates.</p>
      </div>
      <div class="trust-box">
        <h3>Untrusted Contributor Runs (Encouraged)</h3>
        <p>Non-maintainers can run local or sandboxed checks, Uphill audits, and repro flows freely. Untrusted runs read shared cache hits but never write trunk keys or skip gates.</p>
      </div>
      <div class="trust-box">
        <h3>Person-Only Governance</h3>
        <p>Agents connect via <code>https://smithers.sh/api/mcp</code> using short-lived attenuated tokens. Merging, committing TODOs, publishing releases, and secret edits remain person-only.</p>
      </div>
    </div>
  </section>

  <footer>
    <span>Generated by <code>.smithers/audit/generate-lighthouse.mjs</code> from Uphill metrics</span>
    <span><a href="https://smithers.sh/smithersai/claude-p">smithers.sh/smithersai/claude-p</a></span>
  </footer>
</main>
<script>
(() => {
  const root = document.documentElement;
  const themeBtn = document.getElementById("theme-toggle");
  themeBtn.addEventListener("click", () => {
    const cur = root.getAttribute("data-theme");
    const next = cur === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
  });

  let activeCat = "all";
  let missedOnly = false;
  let query = "";

  const tabs = [...document.querySelectorAll(".tab[data-filter-cat]")];
  const sections = [...document.querySelectorAll(".cat-section")];
  const missedBtn = document.getElementById("missed-only");
  const searchInput = document.getElementById("audit-search");
  const emptyBanner = document.createElement("div");
  emptyBanner.className = "empty-filter hidden";
  emptyBanner.style.cssText = "padding:20px;border:1px dashed var(--border);border-radius:12px;text-align:center;color:var(--muted);margin:14px 0;";
  emptyBanner.textContent = "No audits match the current filter.";
  if (sections.length > 0) sections[sections.length - 1].after(emptyBanner);

  function applyFilters() {
    const q = query.trim().toLowerCase();
    let visibleSections = 0;
    for (const sec of sections) {
      const catMatch = activeCat === "all" || sec.dataset.category === activeCat;
      if (!catMatch) {
        sec.classList.add("hidden");
        continue;
      }
      let visibleRows = 0;
      for (const row of sec.querySelectorAll(".audit-row")) {
        const isMissed = row.dataset.status === "missed";
        const textMatch = !q || row.textContent.toLowerCase().includes(q);
        const show = (!missedOnly || isMissed) && textMatch;
        row.classList.toggle("hidden", !show);
        if (show) visibleRows += 1;
      }
      const passedGroup = sec.querySelector(".passed-group");
      if (passedGroup) {
        if (q) passedGroup.open = true;
        const visiblePassed = [...passedGroup.querySelectorAll(".audit-row")].some((r) => !r.classList.contains("hidden"));
        passedGroup.classList.toggle("hidden", missedOnly || (!!q && !visiblePassed));
      }
      const hideEmpty = (missedOnly || !!q) && visibleRows === 0;
      sec.classList.toggle("hidden", hideEmpty);
      if (!hideEmpty) visibleSections += 1;
    }
    emptyBanner.classList.toggle("hidden", visibleSections > 0);
  }

  for (const tab of tabs) {
    tab.addEventListener("click", () => {
      activeCat = tab.dataset.filterCat;
      tabs.forEach((t) => t.classList.toggle("active", t === tab));
      applyFilters();
    });
  }
  missedBtn.addEventListener("click", () => {
    missedOnly = !missedOnly;
    missedBtn.textContent = "Missed only: " + (missedOnly ? "On" : "Off");
    applyFilters();
  });
  searchInput.addEventListener("input", (e) => {
    query = e.target.value;
    applyFilters();
  });
})();
</script>
</body>
</html>
`;
}

const html = renderHtml(auditPayload);
const json = `${JSON.stringify(auditPayload, null, 2)}\n`;

const outDirs = [path.join(ROOT, ".smithers/reports")];
if (!skipDocs) outDirs.push(path.join(ROOT, "docs/public/audit"));

for (const dir of outDirs) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.writeFileSync(path.join(ROOT, ".smithers/reports/audit.html"), html);
fs.writeFileSync(path.join(ROOT, ".smithers/reports/audit.json"), json);
if (!skipDocs) {
  fs.writeFileSync(path.join(ROOT, "docs/public/audit/index.html"), html);
  fs.writeFileSync(path.join(ROOT, "docs/public/audit/audit.json"), json);
}

console.log(
  `audit: overall=${overallScore}/100 (${auditPayload.overallBand}) ` +
    categories.map((c) => `${c.id}=${c.score}`).join(" ") +
    ` trust=${provenance.tier}`,
);

if (strict) {
  const regressions = changes.filter((c) => c.direction === "worse" || c.regressed === true);
  const correctnessCat = categories.find((c) => c.id === "correctness");
  const factoryCat = categories.find((c) => c.id === "factory");
  const failures = [];
  if (regressions.length > 0) failures.push(`${regressions.length} Uphill regression(s) vs baseline`);
  if (correctnessCat && correctnessCat.score !== null && correctnessCat.score < 90) {
    failures.push(`correctness score ${correctnessCat.score} < 90`);
  }
  if (factoryCat && factoryCat.score !== null && factoryCat.score < 100) {
    failures.push(`factory trust score ${factoryCat.score} < 100`);
  }
  if (failures.length > 0) {
    console.error(`audit (--strict): FAILED: ${failures.join(", ")}`);
    process.exit(1);
  }
}
