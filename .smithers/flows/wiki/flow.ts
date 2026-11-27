import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const wikiJob = CiJob.make("wiki", {
  steps: [
    { name: "verify-wiki", run: "node .smithers/flows/wiki/sync-wiki.mjs --check" },
    { name: "sync-wiki-to-docs", run: "node .smithers/flows/wiki/sync-wiki.mjs --write" }
  ]
})

export default Flow.make("wiki", {
  description:
    "Verify Engineering Wiki citations, source freshness digests, and wikilinks, then sync Obsidian-compatible pages into Starlight docs and llms.txt.",
  capabilities: ["fs:read:**", "fs:write:docs/src/content/docs/wiki/**", "proc:spawn:node .smithers/flows/wiki/sync-wiki.mjs *"],
  effects: {
    reads: [".smithers/coding-project.json", ".smithers/wiki/**", "src/**", "scripts/**", "SPEC.md", "README.md"],
    writes: [".smithers/wiki/snapshot.json", "docs/src/content/docs/wiki/**", "docs/public/llms.txt"],
    mode: "expected",
    onConflict: "serialize",
    tier: "reversible"
  },
  modelInvocable: true,
  payload: {
    target: CiJob.Target
  },
  success: Schema.Struct({
    wiki: CiJob.Result
  }),
  body: Node.capture({}, ({ target }) =>
    Node.all({
      wiki: wikiJob.call(target)
    })
  )
})
