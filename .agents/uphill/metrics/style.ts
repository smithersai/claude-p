import { spawnSync } from "node:child_process"
import { join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const allZigFiles = [
  ...walkFiles(join(ROOT, "src"), ".zig"),
  ...walkFiles(join(ROOT, "tests"), ".zig")
]

const fmt = spawnSync("zig", ["fmt", "--check", ...allZigFiles], {
  cwd: ROOT,
  encoding: "utf8"
})
const unformatted = new Set(
  `${fmt.stdout ?? ""}\n${fmt.stderr ?? ""}`
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.endsWith(".zig"))
)

for (const file of allZigFiles) {
  emit("zig-fmt", unformatted.has(file) ? "fail" : "pass", {
    item: file,
    note: unformatted.has(file) ? "Run `zig fmt` to format this file" : undefined
  })
}

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  const longest = analysis.prodFunctions.reduce(
    (best, cur) => (cur.lines > best.lines ? cur : best),
    { name: "none", startLine: 1, lines: 1 }
  )
  emit("max-fn-lines", longest.lines, {
    item: file,
    note: longest.lines > 70 ? `${longest.name} at line ${longest.startLine} (${longest.lines} lines)` : undefined
  })

  const longLine = analysis.prodLineEntries.find((entry) => entry.text.length > 120)
  emit("line-length", longLine ? "fail" : "pass", {
    item: file,
    note: longLine ? `line ${longLine.line}: ${longLine.text.length} chars (limit 120)` : undefined
  })

  const assertCount = analysis.prodLineEntries.filter((entry) =>
    /\b(?:std\.debug\.)?assert\s*\(/.test(entry.stripped)
  ).length
  const perKloc = analysis.prodLines > 0 ? Math.round((assertCount * 1000) / analysis.prodLines) : 0
  emit("assert-density", perKloc, { item: file })
}
