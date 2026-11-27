import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphillJob = CiJob.make("uphill", {
  steps: [
    { name: "uphill-check", run: "uphill check" },
    { name: "uphill-compact", run: "uphill --compact" },
    { name: "lighthouse-audit-report", run: "node .smithers/audit/generate-lighthouse.mjs" }
  ]
})

export default Flow.make("uphill", {
  description:
    "Run Uphill continuous metrics, validate metric definitions, and generate the Lighthouse-style audit report.",
  capabilities: ["proc:spawn:uphill *", "proc:spawn:node .smithers/audit/generate-lighthouse.mjs"],
  effects: {
    reads: ["**"],
    writes: [".uphill/**", ".smithers/reports/audit.html", ".smithers/reports/audit.json", "docs/public/audit/**"],
    mode: "expected",
    onConflict: "serialize",
    tier: "reversible"
  },
  modelInvocable: true,
  payload: {
    target: CiJob.Target
  },
  success: Schema.Struct({
    uphill: CiJob.Result
  }),
  body: Node.capture({}, ({ target }) =>
    Node.all({
      uphill: uphillJob.call(target)
    })
  )
})
