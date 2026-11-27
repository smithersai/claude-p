import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphillJob = CiJob.make("uphill", {
  steps: [
    { name: "uphill-check", run: "uphill check" },
    { name: "uphill-compact", run: "uphill --compact" }
  ]
})

export default Flow.make("uphill", {
  description: "Run Uphill continuous metrics, validate metric definitions, and report compact scores and opportunities.",
  capabilities: ["proc:spawn:uphill *"],
  effects: {
    reads: ["**"],
    writes: [".uphill/**"],
    mode: "expected",
    onConflict: "serialize",
    tier: "irreversible"
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
