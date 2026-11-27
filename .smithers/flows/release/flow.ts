import { Flow, HumanTask } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const preflightJob = CiJob.make("release-preflight", {
  steps: [
    { name: "version-lockstep", run: "node scripts/publish.mjs --check-versions" },
    { name: "trust-and-factory-checks", run: "node --test .smithers/tests/factory-projections.test.mjs .smithers/tests/trust-boundaries.test.mjs .smithers/tests/install-checksum.test.mjs tests/prop/js_supplychain_prop.mjs" },
    { name: "zig-unit-and-prop-tests", run: "sh .smithers/run-zig.sh build test --summary all" },
    { name: "lighthouse-audit-gate", run: "node .smithers/audit/generate-lighthouse.mjs --strict" },
    { name: "build-4-targets-and-checksums", run: "node scripts/publish.mjs --local-only --skip-git --skip-tests" }
  ]
})

const publishJob = CiJob.make("release-publish", {
  steps: [
    { name: "github-release", run: "node scripts/publish.mjs --from-assets --skip-git --only=github" },
    { name: "npm-publish-provenance", run: "node scripts/publish.mjs --from-assets --skip-git --only=npm" }
  ]
})

const Result = Schema.Struct({
  status: Schema.Literals(["published", "declined"]),
  preflight: CiJob.Result
})

export default Flow.make("release", {
  description:
    "Verify version lockstep, tests, and Lighthouse audit gates, cross-compile all four platform binaries with SHA256SUMS and checksums.json, ask maintainer approval, and publish to GitHub Releases and npm.",
  capabilities: [
    "fs:read:**",
    "fs:write:release-assets/**",
    "proc:spawn:node scripts/publish.mjs *",
    "proc:spawn:node --test *",
    "proc:spawn:node .smithers/audit/generate-lighthouse.mjs *",
    "proc:spawn:sh .smithers/run-zig.sh *"
  ],
  effects: {
    reads: ["**"],
    writes: ["release-assets/**"],
    mode: "expected",
    onConflict: "serialize",
    tier: "irreversible"
  },
  modelInvocable: false,
  payload: {
    target: CiJob.Target,
    version: Schema.String
  },
  success: Result,
  body: Node.capture({}, ({ target, version }) =>
    Node.bindPlanned(preflightJob.call(target), (preflight) =>
      Node.branch(
        HumanTask.action.call({
          name: "approve-release",
          kind: "confirm",
          prompt: `Approve publishing claude-p v${version} to GitHub Releases and npm with verified SHA256SUMS and checksums.json?`,
          maxAttempts: 2
        }),
        {
          if: Node.capture({}, (answer: unknown) => answer === true),
          then: Node.capture({}, () =>
            publishJob.call(target).pipe(
              Node.map(Node.capture({}, () => ({ status: "published" as const, preflight })))
            )
          ),
          else: Node.capture({}, () => Node.succeed({ status: "declined" as const, preflight }))
        }
      )
    )
  )
})
