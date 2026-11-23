#!/bin/sh
# Invoke Zig 0.15.2 consistently on both local dev machines (where PATH `zig`
# may point to another ZVM toolchain like 0.17.1) and GitHub Actions CI
# (where mlugg/setup-zig installs 0.15.2 on PATH). Every candidate, including
# $ZIG_BIN and ~/.zvm/0.15.2/zig, must report exactly 0.15.2.
set -eu

REQUIRED="0.15.2"

is_required() { # path
  [ -x "$1" ] && [ "$("$1" version 2>/dev/null || true)" = "$REQUIRED" ]
}

if [ -n "${ZIG_BIN:-}" ]; then
  if is_required "$ZIG_BIN"; then
    exec "$ZIG_BIN" "$@"
  fi
  echo "claude-p factory: ZIG_BIN=$ZIG_BIN is not Zig ${REQUIRED} (found '$("$ZIG_BIN" version 2>/dev/null || echo none)')" >&2
  exit 1
fi

if path_zig="$(command -v zig 2>/dev/null)" && is_required "$path_zig"; then
  exec "$path_zig" "$@"
fi

if is_required "${HOME}/.zvm/${REQUIRED}/zig"; then
  exec "${HOME}/.zvm/${REQUIRED}/zig" "$@"
fi

echo "claude-p factory: Zig ${REQUIRED} is required (found '$(zig version 2>/dev/null || echo none)'). Install with: zvm install ${REQUIRED}" >&2
exit 1
