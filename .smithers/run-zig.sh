#!/bin/sh
# Invoke Zig 0.15.2 consistently on both local dev machines (where PATH `zig`
# may point to another ZVM toolchain like 0.17.1) and GitHub Actions CI
# (where mlugg/setup-zig installs 0.15.2 on PATH).
set -eu

REQUIRED="0.15.2"

if [ -n "${ZIG_BIN:-}" ] && [ -x "$ZIG_BIN" ]; then
  exec "$ZIG_BIN" "$@"
fi

if command -v zig >/dev/null 2>&1; then
  if [ "$(zig version 2>/dev/null || true)" = "$REQUIRED" ]; then
    exec zig "$@"
  fi
fi

if [ -x "${HOME}/.zvm/${REQUIRED}/zig" ]; then
  exec "${HOME}/.zvm/${REQUIRED}/zig" "$@"
fi

echo "claude-p factory: Zig ${REQUIRED} is required (found '$(zig version 2>/dev/null || echo none)'). Install with: zvm install ${REQUIRED}" >&2
exit 1
