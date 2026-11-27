import { spawnSync } from "node:child_process"
import { join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

// 1. Version lockstep check across package.json, build.zig.zon, and src/root.zig
const verCheck = spawnSync("node", ["scripts/publish.mjs", "--check-versions"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("version-lockstep", verCheck.status === 0 ? "pass" : "fail", {
  note: verCheck.status === 0 ? undefined : (verCheck.stderr || verCheck.stdout).trim().slice(0, 180)
})

// 2. Release & CLI script syntax checks
const syntaxTargets: Array<{ item: string; cmd: string; args: string[] }> = [
  { item: "bin/claude-p.js", cmd: "node", args: ["--check", "bin/claude-p.js"] },
  { item: "scripts/install.js", cmd: "node", args: ["--check", "scripts/install.js"] },
  { item: "scripts/publish.mjs", cmd: "node", args: ["--check", "scripts/publish.mjs"] },
  { item: "scripts/build-in-linux.sh", cmd: "sh", args: ["-n", "scripts/build-in-linux.sh"] },
  { item: "scripts/fuzz-linux.sh", cmd: "bash", args: ["-n", "scripts/fuzz-linux.sh"] }
]
for (const target of syntaxTargets) {
  const res = spawnSync(target.cmd, target.args, { cwd: ROOT, encoding: "utf8" })
  emit("script-syntax", res.status === 0 ? "pass" : "fail", {
    item: target.item,
    note: res.status === 0 ? undefined : (res.stderr || res.stdout).trim().slice(0, 180)
  })
}

// 3. Factory projection freshness check
const factoryCheck = spawnSync("node", ["--test", ".smithers/tests/factory-projections.test.mjs"], {
  cwd: ROOT,
  encoding: "utf8"
})
emit("factory-projections", factoryCheck.status === 0 ? "pass" : "fail", {
  note: factoryCheck.status === 0 ? undefined : "Run `smthrs target //.smithers:factory-write --write`"
})

// 4. Zig production code safety checks
const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)

  const panicHit = analysis.prodLineEntries.find((e) =>
    /\B@panic\s*\(|\bcatch\s+unreachable\b|\bunreachable\b/.test(e.stripped)
  )
  emit("no-panic", panicHit ? "fail" : "pass", {
    item: file,
    note: panicHit ? `line ${panicHit.line}: panic or unreachable in production code` : undefined
  })

  const swallowHit = analysis.prodLineEntries.find((e) => /\bcatch\s*\{\s*\}/.test(e.stripped))
  emit("no-empty-catch", swallowHit ? "fail" : "pass", {
    item: file,
    note: swallowHit ? `line ${swallowHit.line}: silent \`catch {}\` swallows errors` : undefined
  })

  const todoHit = analysis.prodLineEntries.find((e) => /\b(TODO|FIXME|XXX|HACK)\b/.test(e.text))
  emit("no-todo", todoHit ? "fail" : "pass", {
    item: file,
    note: todoHit ? `line ${todoHit.line}: unresolved TODO/FIXME marker` : undefined
  })
}
