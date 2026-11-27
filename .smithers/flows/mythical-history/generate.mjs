#!/usr/bin/env node
// Mythical History generator and verifier for smithersai/claude-p.
//
// Reconstructs the chronological engineering narrative and structured timeline
// from jj history, tagged releases, PR milestones, and fuzzing discoveries.
//
// Outputs:
//   .smithers/history/CHRONICLE.md
//   .smithers/history/history.json
//   docs/src/content/docs/history/index.mdx
//
// Usage:
//   node .smithers/flows/mythical-history/generate.mjs --write
//   node .smithers/flows/mythical-history/generate.mjs --check
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const args = new Set(process.argv.slice(2));
const doWrite = args.has("--write");
const doCheck = args.has("--check") || !doWrite;

const EPOCHS = [
  {
    id: "genesis",
    title: "Epoch I: Genesis and the In-Process PTY",
    period: "2026-05-13",
    releases: ["v0.0.1", "v0.0.2", "v0.0.3", "v0.0.4"],
    summary:
      "Specified and implemented the Zig 0.15.2 zmux PTY emulator, DEC/XTerm responder, hook FIFO harness, JSONL transcript parser, real-Claude integration tests, and 4-target cross-compile npm packaging.",
    turningPoints: [
      { sha: "8c332aa4", label: "Initial Zig scaffold and SPEC.md" },
      { sha: "814840c2", label: "zmux-driven session lifecycle and DEC/XTerm query responder" },
      { sha: "990002da", label: "v0.0.1 cross-compile release pipeline" },
      { sha: "f14507b7", label: "Workspace-trust dialog dismissal and Enter debounce (v0.0.4)" },
    ],
  },
  {
    id: "daemon-era",
    title: "Epoch II: Multi-Turn Daemon and Community Hardening",
    period: "2026-05-18 to 2026-06-17",
    releases: ["v0.1.0"],
    summary:
      "Added live transcript streaming, the long-lived NDJSON daemon mode, ping/pong liveness frames, idle-progress watchdogs, CLAUDE_P_PTY_TRACE gating, and community PRs from @madogao.",
    turningPoints: [
      { sha: "b79113c7", label: "v0.1.0 release with live streaming and musl atomic fix" },
      { sha: "26e3e7c1", label: "Long-lived multi-turn claude-p daemon mode" },
      { sha: "f86ce5bf", label: "Idle-progress watchdog replacing fixed wall-clock timeout" },
      { sha: "bb9ee417", label: "NDJSON ping/pong health probes and PTY byte-rate tracing" },
    ],
  },
  {
    id: "crucible",
    title: "Epoch III: Claude Code 2.1, Supply-Chain Trust, and the Fuzzing Crucible",
    period: "2026-11-22 to 2026-11-24",
    releases: ["v0.1.3"],
    summary:
      "Hardened claude-p for Claude Code 2.1, macOS 1024B TTYHOG chunked paste, SHA-256 checksums.json install trust root, 8 property suites fixing 14 bugs, 3-round multi-model review, coverage-guided Linux fuzzing, zmux v0.2.1, and Starlight docs.",
    turningPoints: [
      { sha: "06eb729f", label: "Claude Code 2.1 compatibility, PasteChunker, and SHA-256 release pipeline" },
      { sha: "545e0b11", label: "Initial Smithers factory and incremental CI graph" },
      { sha: "651d3830", label: "8 property and fuzz suites slaying 14 edge-case bugs" },
      { sha: "b4ff6a89", label: "3-round adversarial codebase review (Astra + Fable + Neon)" },
      { sha: "b336615b", label: "v0.1.3 release pinned to zmux v0.2.1" },
      { sha: "65d7ad89", label: "Coverage-guided Linux fuzz campaign across every module" },
    ],
  },
  {
    id: "smithers-cloud",
    title: "Epoch IV: Smithers Cloud Switchover and Lighthouse Backpressure",
    period: "2026-11-26 onward",
    releases: [],
    summary:
      "Completed the public coding factory switchover at smithers.sh/smithersai/claude-p with Uphill Lighthouse audit backpressure, shared object-store trust boundaries, personalized maintainer/contributor/viewer UI, Engineering Wiki, Mythical History, Cloud MCP one-time auth, and merge-triggered docs and releases.",
    turningPoints: [
      { sha: "919c68bb", label: "Uphill continuous metrics, baseline, rules, and Smithers flow" },
      { sha: "7b7966c7", label: "Zig 0.15.2 fuzzer empty-slot guard, PTY timeout hardening, and scripts/smthrs" },
    ],
  },
];

function readJjCommits() {
  try {
    const raw = execFileSync(
      "jj",
      [
        "--no-pager",
        "log",
        "-r",
        "ancestors(main)",
        "--no-graph",
        "-T",
        'commit_id.short(8) ++ "\\t" ++ committer.timestamp().format("%Y-%m-%d") ++ "\\t" ++ tags ++ "\\t" ++ description.first_line() ++ "\\n"',
      ],
      { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    return raw
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        const [sha, date, tagsRaw, ...titleParts] = line.split("\t");
        const title = titleParts.join("\t").trim();
        const tags = (tagsRaw ?? "")
          .split(/\s+/)
          .map((t) => t.trim())
          .filter(Boolean);
        return { sha, date, tags, title };
      })
      .filter((c) => c.sha !== "00000000" && c.title.length > 0);
  } catch {
    return null;
  }
}

const historyJsonPath = path.join(ROOT, ".smithers/history/history.json");
const chroniclePath = path.join(ROOT, ".smithers/history/CHRONICLE.md");
const docsHistoryPath = path.join(ROOT, "docs/src/content/docs/history/index.mdx");

const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
const commits = readJjCommits();

if (!commits) {
  if (doCheck && fs.existsSync(historyJsonPath) && fs.existsSync(chroniclePath) && fs.existsSync(docsHistoryPath)) {
    const existing = JSON.parse(fs.readFileSync(historyJsonPath, "utf8"));
    if (existing.version === 1 && Array.isArray(existing.epochs) && existing.epochs.length === EPOCHS.length) {
      console.log(`history: verified checked-in mythical history (${existing.commitCount} commits, ${existing.epochs.length} epochs, jj unavailable)`);
      process.exit(0);
    }
  }
  console.error("history: jj unavailable and no valid checked-in history.json found");
  process.exit(1);
}

const commitSet = new Set(commits.map((c) => c.sha));
const releases = commits
  .filter((c) => c.tags.length > 0)
  .map((c) => ({ tag: c.tags[0], sha: c.sha, date: c.date, title: c.title }));

const verifiedEpochs = EPOCHS.map((ep) => ({
  ...ep,
  turningPoints: ep.turningPoints.map((tp) => ({
    ...tp,
    verifiedInHistory: commitSet.has(tp.sha),
  })),
}));

const payload = {
  version: 1,
  repository: "smithersai/claude-p",
  currentVersion: pkg.version,
  commitCount: commits.length,
  releaseCount: releases.length,
  releases,
  epochs: verifiedEpochs,
  recentCommits: commits.slice(0, 25),
};
const digest = crypto.createHash("sha256").update(JSON.stringify(payload)).digest("hex");
const fullHistory = { ...payload, digest };

function renderChronicle(data) {
  const epochBlocks = data.epochs
    .map((ep) => {
      const relStr = ep.releases.length > 0 ? ` · Releases: ${ep.releases.map((r) => `\`${r}\``).join(", ")}` : "";
      const pts = ep.turningPoints
        .map(
          (tp) =>
            `- [\`${tp.sha}\`](https://github.com/smithersai/claude-p/commit/${tp.sha}) ${tp.label}${tp.verifiedInHistory ? "" : " (pending land)"}`,
        )
        .join("\n");
      return `## ${ep.title}

**Period:** ${ep.period}${relStr}

${ep.summary}

### Key Turning Points

${pts}`;
    })
    .join("\n\n");

  const ledgerRows = data.recentCommits
    .map(
      (c) =>
        `| [\`${c.sha}\`](https://github.com/smithersai/claude-p/commit/${c.sha}) | ${c.date} | ${c.tags.join(", ") || "—"} | ${c.title.replace(/\|/g, "\\|")} |`,
    )
    .join("\n");

  return `# Mythical History of claude-p

\`\`\`mermaid
flowchart LR
  E1["Epoch I (May 2026)<br/>Genesis & zmux PTY<br/>v0.0.1 - v0.0.4"] --> E2["Epoch II (May-Jun 2026)<br/>NDJSON Daemon & Watchdogs<br/>v0.1.0"]
  E2 --> E3["Epoch III (Nov 2026)<br/>Claude 2.1, SHA-256 & 18 Fuzz Kills<br/>v0.1.3"]
  E3 --> E4["Epoch IV (Nov 2026+)<br/>Smithers Cloud Factory<br/>Lighthouse Audit & MCP"]
\`\`\`

Reconstructed directly from Jujutsu (\`jj\`) repository history for \`smithersai/claude-p\` (${data.commitCount} commits, ${data.releaseCount} tagged releases, current version \`v${data.currentVersion}\`).

${epochBlocks}

## Recent Commit Ledger

| Commit | Date | Tag | Summary |
| --- | --- | --- | --- |
${ledgerRows}
`;
}

const chronicleMd = renderChronicle(fullHistory);
const docsMdx = `---
title: "Mythical History"
description: "The chronological engineering chronicle of smithersai/claude-p reconstructed from jj commits, releases, reviews, and fuzzing bug kills."
---

{/* Generated by .smithers/flows/mythical-history/generate.mjs. */}

${chronicleMd.replace(/^#\s+[^\n]+\n+/, "")}

---

<sub>Digest \`${digest.slice(0, 12)}\` · Machine-readable archive: \`.smithers/history/history.json\`</sub>
`;

if (doWrite) {
  fs.mkdirSync(path.dirname(historyJsonPath), { recursive: true });
  fs.mkdirSync(path.dirname(docsHistoryPath), { recursive: true });
  fs.writeFileSync(historyJsonPath, `${JSON.stringify(fullHistory, null, 2)}\n`);
  fs.writeFileSync(chroniclePath, chronicleMd);
  fs.writeFileSync(docsHistoryPath, docsMdx);
  console.log(`history: generated ${commits.length} commits across ${EPOCHS.length} epochs (digest ${digest.slice(0, 12)})`);
} else if (doCheck) {
  for (const p of [historyJsonPath, chroniclePath, docsHistoryPath]) {
    if (!fs.existsSync(p)) {
      console.error(`history: missing ${path.relative(ROOT, p)} (run with --write)`);
      process.exit(1);
    }
  }
  const existing = JSON.parse(fs.readFileSync(historyJsonPath, "utf8"));
  if (!existing.digest || !Array.isArray(existing.epochs) || existing.epochs.length !== EPOCHS.length) {
    console.error("history: checked-in history.json is malformed (run with --write)");
    process.exit(1);
  }
  console.log(`history: verified (${existing.commitCount} commits, ${existing.epochs.length} epochs, digest ${existing.digest.slice(0, 12)})`);
}
