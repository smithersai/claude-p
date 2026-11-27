import { spawnSync } from "node:child_process"
import { basename, join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

// 1. Run fast Node supply-chain and checksum verification test suites
const nodeSuites = [
  ".smithers/tests/install-checksum.test.mjs",
  "tests/prop/js_supplychain_prop.mjs"
]

for (const suite of nodeSuites) {
  const res = spawnSync("node", ["--test", suite], { cwd: ROOT, encoding: "utf8" })
  const out = `${res.stdout ?? ""}\n${res.stderr ?? ""}`
  const failLine = out
    .split(/\r?\n/)
    .find((line) => line.includes("✖") || line.includes("not ok"))
  emit("js-supplychain-tests", res.status === 0 ? "pass" : "fail", {
    item: suite,
    note: res.status === 0 ? undefined : (failLine ?? "node --test failed").trim().slice(0, 180)
  })
}

// 2. Inline unit test counts & property/fuzz coverage per Zig module
const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
const propFiles = walkFiles(join(ROOT, "tests/prop"), ".zig").map((f) => basename(f, ".zig"))

for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  const stem = basename(file, ".zig")

  if (stem !== "root") {
    emit("unit-tests", analysis.testCount, { item: file })
  }

  if (stem !== "root" && stem !== "main") {
    const hasProp = propFiles.some((name) => name.includes(stem))
    emit("prop-fuzz-coverage", hasProp ? "pass" : "fail", {
      item: file,
      note: hasProp ? undefined : `missing property/fuzz suite referencing ${stem} under tests/prop/`
    })
  }
}
