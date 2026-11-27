import { readFileSync } from "node:fs"
import { join } from "node:path"
import { analyzeZigFile, emit, fileBytes, formatBytes, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  emit("module-prod-lines", analysis.prodLines, { item: file })
  emit("module-bytes", formatBytes(fileBytes(file)), { item: file })
}

for (const jsFile of ["bin/claude-p.js", "scripts/install.js", "scripts/publish.mjs"]) {
  emit("module-bytes", formatBytes(fileBytes(jsFile)), { item: jsFile })
}

// Tripwires: external dependencies in build.zig.zon and package.json
const zon = readFileSync(join(ROOT, "build.zig.zon"), "utf8")
const depsMatch = zon.match(/\.dependencies\s*=\s*\.\{([\s\S]*?)\n\s*\},/)
const zigDeps = depsMatch
  ? [...depsMatch[1].matchAll(/^\s*\.([A-Za-z_]\w*)\s*=\s*\.\{/gm)].map((m) => m[1])
  : []
emit("zig-dependencies", zigDeps.length)

const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as {
  dependencies?: Record<string, string>
}
emit("npm-dependencies", Object.keys(pkg.dependencies ?? {}).length)
