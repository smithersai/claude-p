import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const historyJob = CiJob.make("mythical-history", {
  steps: [
    { name: "generate-mythical-history", run: "node .smithers/flows/mythical-history/generate.mjs --write" },
    { name: "verify-mythical-history", run: "node .smithers/flows/mythical-history/generate.mjs --check" }
  ]
})

export default Flow.make("mythical-history", {
  description:
    "Reconstruct the Mythical History of claude-p from jj commits, releases, PRs, and fuzzing bug kills into CHRONICLE.md, history.json, and Starlight docs.",
  capabilities: [
    "fs:read:**",
    "fs:write:.smithers/history/**",
    "fs:write:docs/src/content/docs/history/**",
    "proc:spawn:node .smithers/flows/mythical-history/generate.mjs *",
    "proc:spawn:jj --no-pager log *"
  ],
  effects: {
    reads: ["SPEC.md", "README.md", "package.json", ".smithers/history/**"],
    writes: [".smithers/history/CHRONICLE.md", ".smithers/history/history.json", "docs/src/content/docs/history/index.mdx"],
    mode: "expected",
    onConflict: "serialize",
    tier: "reversible"
  },
  modelInvocable: true,
  payload: {
    target: CiJob.Target
  },
  success: Schema.Struct({
    history: CiJob.Result
  }),
  body: Node.capture({}, ({ target }) =>
    Node.all({
      history: historyJob.call(target)
    })
  )
})
