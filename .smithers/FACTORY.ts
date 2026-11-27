/**
 * The factory that develops smithersai/claude-p (https://smithers.sh/smithersai/claude-p):
 * featured flows, Dispatcher rules, GitHub policy, and the personalized app home
 * customized for maintainers, contributors, and public viewers.
 *
 * Projected into .smithers/factory.json and .smithers/home.json by
 * //.smithers:factory-write and checked by //.smithers:factory-check.
 */
import { Smithers as S } from "@smthrs/targets"

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review changes for PTY/Ink safety, Zig memory ownership, claude -p output contract, and supply-chain integrity."
})

export const issueRepro = S.Flow({
  flow: "issue/repro",
  featured: true,
  summary: "Reproduce a claude-p PTY, dialog, resume, or daemon defect with non-mock evidence before planning a fix."
})

export const issuePoc = S.Flow({
  flow: "issue/poc",
  featured: true,
  summary: "Implement a bounded fix with focused unit and real-Claude integration regressions."
})

export const prTriage = S.Flow({
  flow: "pr-triage",
  featured: true,
  summary: "Assess pull request readiness from its diff and CI evidence without executing untrusted PR code."
})

export const compatProbe = S.Flow({
  flow: "claude-compat-probe",
  featured: true,
  summary: "Inspect a Claude Code CLI release with read-only --version/--help for flag drift and rejected-flag coverage."
})

export const uphill = S.Flow({
  flow: "uphill",
  featured: true,
  summary: "Run Uphill continuous metrics and generate the Lighthouse-style audit report."
})

export const wiki = S.Flow({
  flow: "wiki",
  featured: false,
  summary: "Verify Engineering Wiki citations and source digests, then sync pages into Starlight docs and llms.txt."
})

export const mythicalHistory = S.Flow({
  flow: "mythical-history",
  featured: false,
  summary: "Reconstruct the Mythical History of claude-p from jj commits, releases, PRs, and fuzzing discoveries."
})

export const docsDeploy = S.Flow({
  flow: "docs-deploy",
  featured: false,
  summary: "Rebuild and verify Starlight docs, Lighthouse audit report, wiki, mythical history, and llms.txt on merge."
})

export const release = S.Flow({
  flow: "release",
  featured: false,
  summary: "Verify gates, cross-compile four targets with checksums, request maintainer approval, and publish."
})

export const sandboxAuth = S.Flow({
  flow: "sandbox-auth",
  featured: false,
  summary: "Mint short-lived attenuated one-time auth and Cloud MCP bootstrap config for sandboxes and agents."
})

export const factory = S.Factory({
  summary: "claude-p: Zig/JS CI on Smithers Cloud, Lighthouse audit backpressure, wiki, mythical history, and MCP flows.",
  flows: [
    review,
    issueRepro,
    issuePoc,
    prTriage,
    compatProbe,
    uphill,
    wiki,
    mythicalHistory,
    docsDeploy,
    release,
    sandboxAuth
  ],
  on: {
    "issue.labeled:todo": {
      flow: "issue/poc",
      description: "Implement every maintainer-accepted TODO with failing tests first"
    },
    "change.opened": {
      flow: "checks/review",
      description: "Review every Change through PTY, Zig memory, wire parity, and supply-chain lenses"
    },
    "change.updated": {
      flow: "checks/review",
      description: "Re-review every updated Change"
    },
    "change.landed": {
      flow: ["wiki", "mythical-history", "docs-deploy"],
      description: "Refresh wiki, mythical history, audit report, and live docs after landing"
    },
    "github.push:main": {
      flow: ["uphill", "wiki", "mythical-history", "docs-deploy"],
      description: "Run Lighthouse audit and publish docs, wiki, and history on every merge to main"
    },
    "schedule:0 15 * * 1": {
      flow: "claude-compat-probe",
      description: "Weekly Monday probe against the latest Claude Code CLI release"
    },
    "schedule:0 6 * * *": {
      flow: "uphill",
      description: "Daily Uphill Lighthouse audit check across all codebase categories"
    }
  },
  github: S.Github.Policy({
    mirror: "pull",
    issues: "two-way",
    changes: "send-upstream",
    maintainers: ["roninjin10"],
    protectedPaths: [
      "src/driver.zig",
      "src/driver/**",
      "src/hook.zig",
      "src/hook/**",
      "src/daemon.zig",
      "src/daemon/**",
      "src/transcript/**",
      "src/args/**",
      "src/stdin.zig",
      "build.zig.zon",
      "build.zig",
      "package.json",
      "bin/claude-p.js",
      "scripts/install.js",
      "scripts/publish.mjs",
      "scripts/build-in-linux.sh",
      "scripts/fuzz-linux.sh",
      "scripts/smthrs",
      "scripts/smithers-auth.mjs",
      ".github/workflows/**",
      ".smithers/**",
      ".agents/uphill/**"
    ]
  })
})

export const home = S.Factory.Home({
  docs: "https://smithersai.github.io/claude-p/llms.txt",
  contributors: "role",
  sections: [
    {
      title: "Today",
      audience: "maintainer",
      blocks: [
        {
          type: "action",
          flow: "branch.new",
          title: "New branch",
          key: "b"
        },
        {
          type: "issues",
          title: "Open issues and TODOs"
        },
        {
          type: "stack",
          title: "Active changeset stack"
        },
        {
          type: "runs",
          title: "Recent factory runs"
        },
        {
          type: "flows",
          title: "Maintainer operations"
        },
        {
          type: "links",
          title: "Operations and trust",
          links: [
            { label: "Live Lighthouse Audit", url: "https://smithersai.github.io/claude-p/audit/" },
            { label: "Object Store Health", url: "https://build.smithers.sh/healthz" },
            { label: "GitHub Actions CI", url: "https://github.com/smithersai/claude-p/actions" },
            { label: "Engineering Wiki", url: "https://smithersai.github.io/claude-p/wiki/" },
            { label: "Mythical History", url: "https://smithersai.github.io/claude-p/history/" },
            { label: "GitHub Releases", url: "https://github.com/smithersai/claude-p/releases" }
          ]
        }
      ]
    },
    {
      title: "Contribute",
      audience: "contributor",
      blocks: [
        {
          type: "prompt",
          title: "Ask Smithers about claude-p",
          placeholder: "Describe a PTY bug, Claude Code flag change, or changeset..."
        },
        {
          type: "stack",
          title: "Your changeset stack"
        },
        {
          type: "flows",
          title: "Run factory flows"
        },
        {
          type: "app",
          flow: "issue/repro",
          title: "Reproduce a bug",
          picture: "issue"
        },
        {
          type: "app",
          flow: "checks/review",
          title: "Review a change",
          picture: "review"
        },
        {
          type: "app",
          flow: "wiki",
          title: "Engineering wiki",
          picture: "wiki"
        },
        {
          type: "code",
          title: "Local incremental CI and audit",
          language: "sh",
          code: "scripts/smthrs ci //...\nnode scripts/smithers-auth.mjs --format json\nuphill --compact"
        },
        {
          type: "cards",
          title: "How a change lands",
          cards: [
            {
              title: "Untrusted runs are encouraged",
              text: "Anyone can run local or sandboxed checks, Uphill audits, and repro flows. Untrusted results read the shared cache but never write trunk keys or skip gates."
            },
            {
              title: "Connect your own agent via MCP",
              text: "Point Claude Code, Codex, or Antigravity at https://smithers.sh/api/mcp to read docs, draft TODOs, open issues, and link verified artifacts."
            },
            {
              title: "Keep spec, code, and tests in lockstep",
              text: "Add a failing unit test first (zero leaks under std.testing.allocator), update SPEC.md and docs, and keep Uphill Lighthouse scores green."
            },
            {
              title: "Trusted sandbox verification and merge",
              text: "Maintainer-controlled sandboxes verify protected paths and merge with full contributor credit. Merging to main auto-publishes docs, audit reports, and releases."
            }
          ]
        }
      ]
    },
    {
      audience: "everyone",
      blocks: [
        {
          type: "hero",
          title: "claude-p",
          tagline: "Emulate claude -p inside an in-process zmux PTY with zero ~/.claude mutation.",
          text: "A Zig 0.15.2 CLI and embeddable library driving interactive Claude Code over a nonce-tagged hook FIFO, with one-shot text/json output and a dual-watchdog NDJSON daemon.",
          install: "npx claude-p \"Summarize this repository\"",
          actions: [
            { label: "Get started", url: "https://smithersai.github.io/claude-p/getting-started/" },
            { label: "Lighthouse Audit", url: "https://smithersai.github.io/claude-p/audit/" },
            { label: "Docs", url: "https://smithersai.github.io/claude-p/" }
          ],
          announcement: {
            label: "v0.1.3: Claude Code 2.1 compatibility and coverage-guided fuzzing",
            url: "https://github.com/smithersai/claude-p/releases/tag/v0.1.3"
          }
        },
        {
          type: "code",
          title: "One-shot automation",
          file: "review.sh",
          language: "sh",
          code: "git diff main | claude-p --output-format json \"Review this diff for regressions\"\n\n# Live transcript streaming plus final claude -p result envelope\nclaude-p --output-format stream-json --verbose \"Explain src/driver.zig\""
        },
        {
          type: "code",
          title: "Multi-turn NDJSON daemon",
          file: "daemon.sh",
          language: "sh",
          code: "claude-p daemon --output-format stream-json --verbose <<'EOF'\n{\"type\":\"user\",\"content\":\"List the modules in src/\"}\n{\"type\":\"ping\"}\nEOF"
        },
        {
          type: "stats",
          stats: [
            { value: "MIT", label: "License" },
            { value: "Zig 0.15.2", label: "Native CLI and library" },
            { value: "0", label: "Runtime npm deps" },
            { value: "4 targets", label: "macOS and Linux arm64/x64" }
          ]
        },
        {
          type: "cards",
          title: "Why claude-p",
          cards: [
            {
              title: "Zero ~/.claude mutation",
              text: "Every relay hook script and FIFO lives in an ephemeral $TMPDIR directory and cleans up on exit.",
              url: "https://smithersai.github.io/claude-p/internals/hooks-and-transcripts/"
            },
            {
              title: "Stateful DEC and XTerm responder",
              text: "Handles DA1, DA2, DSR, XTVERSION, and 18t queries even when split across PTY reads so Ink never hangs.",
              url: "https://smithersai.github.io/claude-p/internals/pty-and-dec-queries/"
            },
            {
              title: "macOS TTYHOG safe paste",
              text: "Chunked UTF-8-safe bracketed paste under 512 bytes with ESC[201~ neutralization and acceptance watchdog.",
              url: "https://smithersai.github.io/claude-p/internals/startup-dialogs-and-paste/"
            },
            {
              title: "Long-lived NDJSON daemon",
              text: "Incremental paste keeps ping and interrupt responsive while idle and transcript watchdogs catch stalls.",
              url: "https://smithersai.github.io/claude-p/reference/daemon-protocol/"
            },
            {
              title: "SHA-256 install trust root",
              text: "Bundled checksums.json and required SHA256SUMS verify every prebuilt binary before extraction.",
              url: "https://smithersai.github.io/claude-p/reference/installation-and-builds/"
            },
            {
              title: "Property and fuzz verified",
              text: "Coverage-guided Zig fuzzing and 4,000+ supply-chain trials run continuously on Linux and macOS.",
              url: "https://smithersai.github.io/claude-p/audit/"
            }
          ]
        },
        {
          type: "cards",
          title: "Public coding factory",
          cards: [
            {
              label: "Backpressure",
              title: "Lighthouse Audit Report",
              text: "Live Uphill gauges across footprint, TigerStyle, correctness, testing, documentation, and trust boundaries.",
              url: "https://smithersai.github.io/claude-p/audit/"
            },
            {
              label: "World Model",
              title: "Engineering Wiki",
              text: "Citation-verified Obsidian-compatible architecture pages covering every module and invariant.",
              url: "https://smithersai.github.io/claude-p/wiki/"
            },
            {
              label: "Chronicle",
              title: "Mythical History",
              text: "Complete commit, PR, release, and fuzzing bug-kill timeline reconstructed from jj history.",
              url: "https://smithersai.github.io/claude-p/history/"
            },
            {
              label: "BYOA",
              title: "Cloud MCP Server",
              text: "Connect your own agent to https://smithers.sh/api/mcp to explore docs, draft TODOs, and open issues.",
              url: "https://smithersai.github.io/claude-p/wiki/smithers-cloud-factory/"
            }
          ]
        },
        {
          type: "releases",
          title: "Releases",
          releases: [
            {
              name: "v0.1.3",
              url: "https://github.com/smithersai/claude-p/releases/tag/v0.1.3",
              date: "2026-11-23",
              summary: "Claude Code 2.1 trust dialog handling, daemon hardening, SHA-256 install trust root, and zmux v0.2.1."
            },
            {
              name: "v0.1.0",
              url: "https://github.com/smithersai/claude-p/releases/tag/v0.1.0",
              date: "2026-05-18",
              summary: "Multi-turn NDJSON daemon mode, --extra-hook, --setting-json, and offset-isolated session resume."
            },
            {
              name: "v0.0.4",
              url: "https://github.com/smithersai/claude-p/releases/tag/v0.0.4",
              date: "2026-05-14",
              summary: "Prebuilt cross-compiled binaries for macOS and Linux arm64/x64 via npm."
            }
          ],
          more: {
            label: "All releases",
            url: "https://github.com/smithersai/claude-p/releases"
          }
        },
        {
          type: "prompt",
          title: "Questions about claude-p?",
          placeholder: "Ask about flags, daemon frames, Zig embedding, or contributing..."
        }
      ]
    }
  ]
})
