import { spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { emit, ROOT } from "./_lib.ts"

// 1. Shared Smithers Cloud object store (build.smithers.sh) with split read/write secrets
const wsSrc = existsSync(join(ROOT, ".smithers/WORKSPACE.ts"))
  ? readFileSync(join(ROOT, ".smithers/WORKSPACE.ts"), "utf8")
  : ""
const hasRemoteCache =
  wsSrc.includes("https://build.smithers.sh") &&
  wsSrc.includes("SMITHERS_CACHE_READ_TOKEN") &&
  wsSrc.includes("SMITHERS_CACHE_WRITE_TOKEN")
emit("remote-cache-config", hasRemoteCache ? "pass" : "fail", {
  note: hasRemoteCache ? undefined : "Configure S.RemoteCache on https://build.smithers.sh with split read/write secrets"
})

// 2. Trust boundaries & non-poisoning invariants
const trust = spawnSync("node", ["--test", ".smithers/tests/trust-boundaries.test.mjs"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("trust-boundaries", trust.status === 0 ? "pass" : "fail", {
  note: trust.status === 0 ? undefined : (trust.stderr || trust.stdout).trim().slice(0, 180)
})

// 3. Personalized 3-audience factory UI (maintainer, contributor, everyone) + docs llms.txt
let homeOk = false
let homeNote: string | undefined
try {
  const home = JSON.parse(readFileSync(join(ROOT, ".smithers/home.json"), "utf8")) as {
    docs?: string
    contributors?: string
    sections?: Array<{ audience?: string; blocks?: unknown[] }>
  }
  const audiences = new Set((home.sections ?? []).map((s) => s.audience ?? "everyone"))
  const blockCount = (home.sections ?? []).reduce((n, s) => n + (s.blocks?.length ?? 0), 0)
  homeOk =
    Boolean(home.docs?.startsWith("https://")) &&
    audiences.has("maintainer") &&
    audiences.has("contributor") &&
    audiences.has("everyone") &&
    blockCount > 0 &&
    blockCount <= 32
  if (!homeOk) homeNote = "home.json must declare docs llms.txt and maintainer/contributor/everyone sections (<= 32 blocks)"
} catch (err) {
  homeNote = err instanceof Error ? err.message : String(err)
}
emit("personalized-ui", homeOk ? "pass" : "fail", { note: homeNote })

// 4. Engineering Wiki citations and freshness snapshot
const wiki = spawnSync("node", [".smithers/flows/wiki/sync-wiki.mjs", "--check"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("wiki-freshness", wiki.status === 0 ? "pass" : "fail", {
  note: wiki.status === 0 ? undefined : (wiki.stderr || wiki.stdout).trim().slice(0, 180)
})

// 5. Mythical History chronicle and timeline integrity
const history = spawnSync("node", [".smithers/flows/mythical-history/generate.mjs", "--check"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("mythical-history", history.status === 0 ? "pass" : "fail", {
  note: history.status === 0 ? undefined : (history.stderr || history.stdout).trim().slice(0, 180)
})

// 6. One-time sandbox / Cloud MCP auth CLI dry-run
const auth = spawnSync("node", ["scripts/smithers-auth.mjs", "--dry-run", "--format", "json"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("mcp-sandbox-auth", auth.status === 0 ? "pass" : "fail", {
  note: auth.status === 0 ? undefined : (auth.stderr || auth.stdout).trim().slice(0, 180)
})
