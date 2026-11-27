import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const docsDeployJob = CiJob.make("docs-deploy", {
  steps: [
    { name: "sync-wiki", run: "node .smithers/flows/wiki/sync-wiki.mjs --write" },
    { name: "sync-history", run: "node .smithers/flows/mythical-history/generate.mjs --write" },
    { name: "generate-lighthouse-audit", run: "node .smithers/audit/generate-lighthouse.mjs" },
    { name: "build-starlight-docs", run: "cd docs && npm ci && npm run build" },
    { name: "verify-llms-and-audit", run: "test -s docs/dist/llms.txt && test -s docs/dist/audit/index.html" }
  ]
})

export default Flow.make("docs-deploy", {
  description:
    "Rebuild the Starlight documentation site, Engineering Wiki, Mythical History, Lighthouse audit report, and llms.txt index on merge to main.",
  capabilities: [
    "fs:read:**",
    "fs:write:docs/**",
    "proc:spawn:node .smithers/**",
    "proc:spawn:npm *"
  ],
  effects: {
    reads: ["docs/**", ".smithers/wiki/**", ".smithers/history/**", ".agents/uphill/**", "README.md", "SPEC.md"],
    writes: ["docs/dist/**", "docs/public/audit/**", "docs/public/llms.txt"],
    mode: "expected",
    onConflict: "serialize",
    tier: "reversible"
  },
  modelInvocable: true,
  payload: {
    target: CiJob.Target
  },
  success: Schema.Struct({
    docs: CiJob.Result
  }),
  body: Node.capture({}, ({ target }) =>
    Node.all({
      docs: docsDeployJob.call(target)
    })
  )
})
