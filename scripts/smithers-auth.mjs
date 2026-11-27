#!/usr/bin/env node
// One-time / short-lived attenuated authentication bootstrap for smithersai/claude-p
// sandboxes and BYOA coding agents (Claude Code, Codex, Antigravity, Cursor).
//
// Security invariants:
//   - NEVER prints raw master SMITHERS_TOKEN, GitHub PATs, or browser cookies.
//   - Mints short-lived, scope-attenuated gateway tokens via `scripts/smthrs token mint`
//     when SMITHERS_TOKEN is present in the trusted host environment.
//   - Optionally exchanges an attenuated token for a single-use WebSocket ticket
//     via POST <gateway>/auth/ticket when SMITHERS_GATEWAY_URL is set.
//   - Probes live Cloud MCP OAuth discovery on https://smithers.sh/api/mcp and prints
//     exact client bootstrap snippets so agents immediately use Smithers Cloud MCP
//     to create artifacts, TODOs, issues, PRs, and changeset stacks.
//
// Usage:
//   node scripts/smithers-auth.mjs [--scope read:runs] [--ttl 15m] [--format text|json] [--dry-run]
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const argv = process.argv.slice(2);

function flagValue(name, fallback) {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === name && argv[i + 1]) return argv[i + 1];
    if (argv[i].startsWith(`${name}=`)) return argv[i].slice(name.length + 1);
  }
  return fallback;
}

const format = flagValue("--format", "text");
const ttl = flagValue("--ttl", "15m");
const scope = flagValue("--scope", "read:runs");
const dryRun = argv.includes("--dry-run");
const noNetwork = argv.includes("--offline") || dryRun;

const ALLOWED_SCOPES = new Set(["read:runs", "write:runs"]);
if (!ALLOWED_SCOPES.has(scope)) {
  console.error(`smithers-auth: disallowed scope "${scope}" (sandbox tokens allow only read:runs or write:runs, never approve:runs)`);
  process.exit(2);
}

const MAX_SANDBOX_TTL_SECONDS = 4 * 3600;
function parseTtlSeconds(raw) {
  const m = /^(\d+)([smh])$/.exec(raw);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isSafeInteger(n) || n <= 0) return null;
  const mult = m[2] === "s" ? 1 : m[2] === "m" ? 60 : 3600;
  return n * mult;
}
const ttlSeconds = parseTtlSeconds(ttl);
if (ttlSeconds === null || ttlSeconds > MAX_SANDBOX_TTL_SECONDS) {
  console.error(`smithers-auth: invalid or excessive --ttl "${ttl}" (expected <n>[s|m|h], max 4h for sandbox tokens)`);
  process.exit(2);
}

const policy = JSON.parse(fs.readFileSync(path.join(ROOT, ".smithers/trust-policy.json"), "utf8"));
const cloudMcpUrl = policy.mcpEndpoint;
const repo = policy.repository;

async function probeCloudMcp() {
  if (noNetwork) {
    return { reachable: null, mode: "offline-dry-run", endpoint: cloudMcpUrl };
  }
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    const res = await fetch("https://smithers.sh/.well-known/oauth-protected-resource", {
      signal: controller.signal,
      headers: { accept: "application/json" },
    });
    clearTimeout(timer);
    if (res.ok) {
      const meta = await res.json();
      return {
        reachable: true,
        status: res.status,
        endpoint: cloudMcpUrl,
        resource: meta.resource ?? cloudMcpUrl,
        authorizationServers: meta.authorization_servers ?? ["https://smithers.sh"],
        scopesSupported: meta.scopes_supported ?? ["mcp:read", "mcp:write"],
      };
    }
    return { reachable: true, status: res.status, endpoint: cloudMcpUrl };
  } catch (err) {
    return {
      reachable: false,
      endpoint: cloudMcpUrl,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

function mintAttenuatedGatewayToken() {
  if (dryRun) {
    return {
      mode: "dry-run",
      minted: false,
      scope,
      ttl,
      oneTimeNonce: crypto.randomBytes(16).toString("hex"),
      note: "Dry-run mode: pass SMITHERS_TOKEN in a trusted host to mint a live smt1.* attenuated token.",
    };
  }
  if (!process.env.SMITHERS_TOKEN) {
    return {
      mode: "unauthenticated-local",
      minted: false,
      scope,
      ttl,
      note: "SMITHERS_TOKEN not set in environment; using Cloud MCP OAuth PKCE or interactive smthrs login.",
    };
  }
  const smthrsBin = path.join(ROOT, "scripts/smthrs");
  const res = spawnSync(smthrsBin, ["token", "mint", "--scope", scope, "--ttl", ttl, "--json"], {
    cwd: ROOT,
    encoding: "utf8",
    env: process.env,
  });
  if (res.status !== 0) {
    return {
      mode: "mint-failed",
      minted: false,
      scope,
      ttl,
      error: (res.stderr || res.stdout || "token mint failed").trim().slice(0, 200),
    };
  }
  try {
    const parsed = JSON.parse(res.stdout);
    return {
      mode: "attenuated-smt1",
      minted: true,
      token: parsed.token,
      expiresAt: parsed.expiresAt,
      scopes: parsed.scopes ?? [scope],
      oneTimeUseGuidance: "Inject into sandbox via mode-0600 file or stdin, never argv or committed files.",
    };
  } catch {
    return {
      mode: "attenuated-smt1",
      minted: true,
      token: res.stdout.trim(),
      scope,
      ttl,
    };
  }
}

async function mintOneTimeWsTicket(bearerToken) {
  const gw = process.env.SMITHERS_GATEWAY_URL;
  if (dryRun || !gw || !bearerToken) return null;
  let parsedUrl;
  try {
    parsedUrl = new URL(gw);
  } catch {
    return { minted: false, error: "invalid SMITHERS_GATEWAY_URL" };
  }
  const isLoopback =
    parsedUrl.hostname === "127.0.0.1" ||
    parsedUrl.hostname === "localhost" ||
    parsedUrl.hostname === "::1" ||
    parsedUrl.hostname === "[::1]";
  if (parsedUrl.protocol !== "https:" && !(parsedUrl.protocol === "http:" && isLoopback)) {
    return { minted: false, error: "refusing to send bearer token to non-HTTPS non-loopback gateway" };
  }
  try {
    const base = gw.replace(/\/+$/, "");
    const res = await fetch(`${base}/auth/ticket`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${bearerToken}`,
        origin: base,
      },
    });
    if (!res.ok) return { minted: false, status: res.status };
    const body = await res.json();
    return { minted: true, singleUse: true, ticket: body.ticket, expiresInMs: body.expiresInMs ?? 30000 };
  } catch (err) {
    return { minted: false, error: err instanceof Error ? err.message : String(err) };
  }
}

const cloudMcp = await probeCloudMcp();
const gatewayAuth = mintAttenuatedGatewayToken();
const oneTimeTicket = gatewayAuth.minted ? await mintOneTimeWsTicket(gatewayAuth.token) : null;

const bootstrap = {
  schema: "smithers-sandbox-auth/v1",
  repository: repo,
  generatedAt: new Date().toISOString(),
  trustPolicy: {
    untrustedCanWriteTrunkCache: false,
    personOnlyActionsBlockedForAgents: policy.personOnlyActions,
    readOnlyCacheSecret: policy.objectStore.readSecret,
  },
  cloudMcp: {
    ...cloudMcp,
    oauth: {
      registerUrl: "https://smithers.sh/api/mcp/oauth/register",
      authorizeUrl: "https://smithers.sh/api/mcp/oauth/authorize",
      tokenUrl: "https://smithers.sh/api/mcp/oauth/token",
      bearerFormat: "sma_<64 lowercase hex>",
      scopes: ["mcp:read", "mcp:write"],
    },
    clientSnippets: {
      claudeCode: `claude mcp add --transport http smithers-cloud ${cloudMcpUrl}`,
      antigravityMcpConfig: {
        mcpServers: {
          "smithers-cloud": {
            serverUrl: cloudMcpUrl,
          },
          "claude-p-local": {
            command: path.join(ROOT, "scripts/smthrs"),
            args: ["--mcp"],
          },
        },
      },
      sandboxEnvSetup: [
        "# Never pass tokens on argv. Write to a mode-0600 file inside the sandbox:",
        "umask 077 && cat > /tmp/smithers-sandbox.token",
        "export SMITHERS_CACHE_NAMESPACE=pr-sandbox",
      ].join("\n"),
    },
  },
  gatewayAttenuatedToken: gatewayAuth,
  oneTimeWebSocketTicket: oneTimeTicket,
};

if (format === "json") {
  process.stdout.write(`${JSON.stringify(bootstrap, null, 2)}\n`);
} else {
  console.log(`Smithers Cloud MCP & One-Time Sandbox Auth (${repo})`);
  console.log(`  Cloud MCP endpoint : ${cloudMcpUrl} (reachable=${String(cloudMcp.reachable)})`);
  console.log(`  OAuth authorize    : ${bootstrap.cloudMcp.oauth.authorizeUrl}`);
  console.log(`  OAuth token        : ${bootstrap.cloudMcp.oauth.tokenUrl}`);
  console.log(`  Gateway token mode : ${gatewayAuth.mode} (scope=${scope}, ttl=${ttl})`);
  if (gatewayAuth.minted && gatewayAuth.token) {
    console.log(`  Attenuated token   : ${gatewayAuth.token}`);
  }
  if (oneTimeTicket?.minted) {
    console.log(`  One-time WS ticket : ${oneTimeTicket.ticket} (single-use, ${oneTimeTicket.expiresInMs}ms)`);
  }
  console.log(`\nConnect Claude Code / BYOA Agent:`);
  console.log(`  ${bootstrap.cloudMcp.clientSnippets.claudeCode}`);
  console.log(`\nLocal MCP registration:`);
  console.log(`  scripts/smthrs mcp add`);
}
