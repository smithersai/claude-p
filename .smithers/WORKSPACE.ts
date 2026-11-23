// Current smthrs discovers this file; WORKSPACE.smithers is a compatibility entry.
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
    // Local-first cache that syncs through Cloudflare when tokens are present
    // in the local environment or GitHub Actions CI.
    remote: S.RemoteCache.make({
      endpoint: "https://build.smithers.sh",
      read: S.Secret("SMITHERS_CACHE_READ_TOKEN"),
      write: S.Secret("SMITHERS_CACHE_WRITE_TOKEN")
    })
  }),
  host: S.Host({ bins: ["zig", "node", "sh"] }),
  discovery: {
    prune: [
      ".zig-cache",
      "zig-out",
      "zig-pkg",
      "prebuilt",
      "release-assets",
      ".smithers/cache",
      ".smithers/reports",
      "node_modules"
    ]
  }
})
