import { existsSync, readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  if (analysis.pubDecls === 0) continue
  const pct = Math.round((analysis.documentedPubDecls * 100) / analysis.pubDecls)
  emit("pub-doc-coverage", pct, {
    item: file,
    note: pct < 90 ? `${analysis.documentedPubDecls}/${analysis.pubDecls} pub decls have /// doc comments` : undefined
  })
}

const topMd = ["README.md", "SPEC.md", "CLAUDE.md", "AGENTS.md"].filter((f) => existsSync(join(ROOT, f)))
for (const md of topMd) {
  const content = readFileSync(join(ROOT, md), "utf8")
  const links = [...content.matchAll(/\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)/g)]
  let broken: string | undefined
  for (const match of links) {
    const target = match[1].trim()
    if (!target || /^(https?:|mailto:|#)/.test(target)) continue
    const resolved = resolve(dirname(join(ROOT, md)), target)
    if (!existsSync(resolved)) {
      broken = `broken link target: ${target}`
      break
    }
  }
  emit("markdown-links", broken ? "fail" : "pass", { item: md, note: broken })
}

// Check Astro Starlight docs pages have valid title & description frontmatter
const docPages = walkFiles(join(ROOT, "docs/src/content/docs"), [".md", ".mdx"])
for (const page of docPages) {
  if (page.endsWith("404.md")) continue
  const content = readFileSync(join(ROOT, page), "utf8")
  const fm = content.match(/^---\r?\n([\s\S]*?)\r?\n---/)
  const hasTitle = fm ? /^title:\s*.+/m.test(fm[1]) : false
  const hasDesc = fm ? /^description:\s*.+/m.test(fm[1]) : false
  const ok = hasTitle && hasDesc
  emit("docs-frontmatter", ok ? "pass" : "fail", {
    item: page,
    note: ok ? undefined : `missing ${!hasTitle ? "title" : "description"} in MDX frontmatter`
  })
}
