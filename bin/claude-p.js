#!/usr/bin/env node
// Thin shim that runs the platform-specific prebuilt `claude-p` binary
// downloaded by scripts/install.js into ../prebuilt/.

const { spawn } = require("node:child_process");
const { constants: { signals } } = require("node:os");
const path = require("node:path");

function platformDir() {
  const platform = process.platform;
  const arch = process.arch;
  return `${platform}-${arch}`;
}

function binaryPath() {
  const dir = path.join(__dirname, "..", "prebuilt", platformDir());
  const name = process.platform === "win32" ? "claude-p.exe" : "claude-p";
  return path.join(dir, name);
}

function main() {
  const child = spawn(binaryPath(), process.argv.slice(2), {
    stdio: "inherit",
  });
  const forwardedSignals = ["SIGINT", "SIGTERM", "SIGHUP"];
  const forwardSignal = (signal) => child.kill(signal);
  for (const signal of forwardedSignals) {
    process.on(signal, forwardSignal);
  }

  child.on("error", (error) => {
    console.error("claude-p:", error.message);
    if (child.pid === undefined) {
      console.error(
        "Re-run `npm install claude-p` or build https://github.com/smithersai/claude-p " +
          "with `zig build -Doptimize=ReleaseSafe` and run `./zig-out/bin/claude-p`.",
      );
    }
  });

  child.once("close", (code, signal) => {
    for (const forwardedSignal of forwardedSignals) {
      process.removeListener(forwardedSignal, forwardSignal);
    }
    if (signal) {
      process.exitCode = 128 + signals[signal];
      // Node uses SIGUSR1 to start its debugger.
      if (signal !== "SIGUSR1") {
        process.kill(process.pid, signal);
      }
      return;
    }
    process.exitCode = child.pid === undefined ? 2 : (code ?? 2);
  });
}

main();
