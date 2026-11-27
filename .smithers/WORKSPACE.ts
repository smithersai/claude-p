// Smithers 1.0 workspace declaration for smithersai/claude-p.
// Local-first action cache syncs through the shared Smithers Cloud object store
// (https://build.smithers.sh) with strictly split read/write secrets.
import { Smithers as S } from "@smthrs/targets"

export const runtime = S.Runtime.Node({ version: ">=26.4.0" })
export const packageManager = S.PackageManager.Pnpm({ version: "11.25.0", runtime })
const nodeModules = S.Npm.NodeModules({
  packageJson: S.file("//package.json")
})

export const Workspace = S.Workspace("smithersai-claude-p", {
  repository: "smithersai/claude-p",
  runtime,
  packageManager,
  nodeModules,
  cache: S.Cache({
    directory: ".smithers/cache",
    hostDirectories: [".zig-cache", "zig-out", "prebuilt", "release-assets"],
    // Local-first cache that syncs through the shared Smithers Cloud object
    // store (D1 + R2). PRs and untrusted runs only ever receive READ tokens;
    // WRITE tokens are scoped to main push in the trusted cache-publish env.
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN")
    })
  }),
  host: S.Host({ bins: ["zig", "node", "bun", "sh"] }),
  discovery: {
    prune: [
      ".zig-cache",
      "zig-out",
      "zig-pkg",
      "prebuilt",
      "release-assets",
      ".flows",
      ".uphill",
      ".smithers/cache",
      ".smithers/reports",
      "docs/dist",
      "docs/.astro",
      "docs/node_modules",
      "node_modules"
    ]
  }
})
