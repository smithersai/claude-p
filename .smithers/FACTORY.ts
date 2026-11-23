/**
 * The factory that develops smithersai/claude-p (https://smithers.sh/smithersai/claude-p):
 * featured flows, Dispatcher rules, GitHub policy, and the app home shown at
 * smithers.sh/smithersai/claude-p. Projected into .smithers/factory.json and
 * .smithers/home.json by //.smithers:factory-write and checked by //.smithers:factory-check.
 */
import { Smithers as S } from "@smthrs/targets"

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review changes for PTY/Ink safety, Zig memory ownership, claude -p wire parity, and supply-chain integrity."
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
  summary: "Probe a Claude Code CLI release for flag drift, hook suppression, Ink probes, and startup dialog regressions."
})

export const factory = S.Factory({
  summary: "claude-p: local-first incremental Zig/JS CI, Claude Code CLI compatibility probes, PTY reliability review, and maintainer triage.",
  flows: [review, issueRepro, issuePoc, prTriage, compatProbe],
  on: {
    "schedule:0 15 * * 1": {
      flow: "claude-compat-probe",
      description: "Weekly Monday probe against the latest Claude Code CLI release"
    }
  },
  github: S.Github.Policy({
    mirror: "pull",
    issues: "read",
    changes: "send-upstream",
    maintainers: ["roninjin10"],
    protectedPaths: [
      "src/driver.zig",
      "src/hook.zig",
      "src/daemon.zig",
      "build.zig.zon",
      "scripts/install.js",
      "scripts/publish.mjs"
    ]
  })
})

export const home = S.Factory.Home({
  blocks: [
    {
      type: "text",
      title: "claude-p factory",
      text: "Drop-in replacement for `claude -p` driving interactive Claude Code inside an in-process zmux PTY. Local-first incremental Zig 0.15.2 and JS CI with Cloudflare cache sync, zero-mock real-Claude E2E gates, and weekly Claude Code compatibility probes."
    },
    {
      type: "prompt",
      title: "Ask about claude-p",
      placeholder: "Describe a Claude Code compatibility issue, PTY hang, or change…"
    },
    {
      type: "flows",
      title: "Review, probe, and reproduce"
    },
    {
      type: "links",
      links: [
        { label: "Repository", url: "https://github.com/smithersai/claude-p" },
        { label: "CI", url: "https://github.com/smithersai/claude-p/actions/workflows/ci.yml" },
        { label: "npm Package", url: "https://www.npmjs.com/package/claude-p" },
        { label: "Spec", url: "https://github.com/smithersai/claude-p/blob/main/SPEC.md" }
      ]
    }
  ]
})
