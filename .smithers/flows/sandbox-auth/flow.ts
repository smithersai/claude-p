import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const authJob = CiJob.make("sandbox-auth", {
  steps: [
    { name: "mint-one-time-sandbox-auth", run: "node scripts/smithers-auth.mjs --format json" }
  ]
})

export default Flow.make("sandbox-auth", {
  description:
    "Mint and print short-lived, attenuated one-time authentication and MCP bootstrap configuration for sandboxes and BYOA coding agents without exposing master secrets.",
  capabilities: ["proc:spawn:node scripts/smithers-auth.mjs *"],
  effects: {
    reads: [".smithers/trust-policy.json"],
    writes: [],
    mode: "expected",
    onConflict: "parallel",
    tier: "reversible"
  },
  modelInvocable: true,
  payload: {
    target: CiJob.Target
  },
  success: Schema.Struct({
    auth: CiJob.Result
  }),
  body: Node.capture({}, ({ target }) =>
    Node.all({
      auth: authJob.call(target)
    })
  )
})
