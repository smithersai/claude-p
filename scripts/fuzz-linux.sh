#!/usr/bin/env bash
# Coverage-guided Zig 0.15.2 fuzz campaign for Linux (Ubuntu CI, or bare-metal
# hosts such as the Latitude box nyc-01).
#
# One `zig build test-prop --fuzz` invocation compiles the instrumented test
# binary once and the build runner then fuzzes EVERY `std.testing.fuzz` test in
# parallel (one fuzzer process per test, bounded by -j). The corpus and coverage
# map live in FUZZ_CACHE_DIR, so repeated campaigns keep building on the inputs
# previous campaigns discovered.
#
# Usage:
#   ./scripts/fuzz-linux.sh                          # every target, 60s of fuzzing
#   FUZZ_SECONDS=1800 ./scripts/fuzz-linux.sh        # 30 min campaign
#   ./scripts/fuzz-linux.sh "transcript"             # only tests matching a filter
#   ZIG_BIN=~/.local/zig-0.15.2/zig ./scripts/fuzz-linux.sh
#
# Exit status: 0 when every fuzzer survived the whole budget, 1 on any failure
# (crash, failed assertion, leak, or error log), 2 on setup errors.
#
# Zig 0.15.2's `--fuzz` engine is Linux-only. On macOS run `zig build test-prop`,
# which replays every fuzz corpus and runs the deterministic property suites.
set -euo pipefail

ZIG_BIN="${ZIG_BIN:-zig}"
FUZZ_SECONDS="${FUZZ_SECONDS:-60}"
# Debug keeps every safety check and compiles the SanCov-instrumented binary
# far faster than ReleaseSafe (LLVM optimization dominates the build).
FUZZ_OPTIMIZE="${FUZZ_OPTIMIZE:-Debug}"
FUZZ_CACHE_DIR="${FUZZ_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-p-fuzz}"
FUZZ_STARTUP_TIMEOUT="${FUZZ_STARTUP_TIMEOUT:-2400}"
FILTER="${1:-}"

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: Zig 0.15.2 --fuzz requires Linux (this host: $(uname -s))." >&2
  echo "hint: run on an Ubuntu host, or use 'zig build test-prop' to replay corpora on macOS." >&2
  exit 2
fi

ZIG_VER="$("$ZIG_BIN" version)"
if [ "$ZIG_VER" != "0.15.2" ]; then
  echo "error: zig 0.15.2 is required (zmux pins it); got $ZIG_VER from $ZIG_BIN" >&2
  exit 2
fi

mkdir -p "$FUZZ_CACHE_DIR"
LOG="$FUZZ_CACHE_DIR/campaign.log"
: >"$LOG"

filter_args=()
if [ -n "$FILTER" ]; then filter_args=("-Dtest-filter=$FILTER"); fi

echo "=== claude-p coverage-guided fuzz campaign ==="
echo "zig=$ZIG_BIN optimize=$FUZZ_OPTIMIZE seconds=$FUZZ_SECONDS filter='${FILTER:-<all>}'"
echo "cache=$FUZZ_CACHE_DIR log=$LOG"

# The corpus and properties must pass before fuzzing starts.
"$ZIG_BIN" build test-prop -Doptimize="$FUZZ_OPTIMIZE" --cache-dir "$FUZZ_CACHE_DIR" \
  "${filter_args[@]}" --summary none

# Own process group so we can stop the build runner AND every fuzzer child.
setsid "$ZIG_BIN" build test-prop --fuzz -Doptimize="$FUZZ_OPTIMIZE" \
  --cache-dir "$FUZZ_CACHE_DIR" "${filter_args[@]}" >>"$LOG" 2>&1 &
pgid=$!

stop_all() {
  kill -INT -- "-$pgid" 2>/dev/null || true
  sleep 2
  kill -KILL -- "-$pgid" 2>/dev/null || true
  wait "$pgid" 2>/dev/null || true
}
trap stop_all EXIT

# Wait until fuzzers are running (coverage map created and runs counting).
read_header() { # prints "n_runs unique_runs pcs_len"
  python3 - "$1" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    print(*struct.unpack("<QQQ", f.read(24)))
PY
}

runs_of() { read_header "$1" 2>/dev/null | cut -d' ' -f1 || echo 0; }

# The active coverage map is the one whose run counter is advancing.
cov=""
waited=0
while [ -z "$cov" ]; do
  if ! kill -0 "$pgid" 2>/dev/null; then
    echo "error: fuzz build exited before fuzzing started" >&2
    tail -n 60 "$LOG" >&2
    exit 1
  fi
  declare -A first=()
  for f in "$FUZZ_CACHE_DIR"/v/*; do
    [ -f "$f" ] && first["$f"]="$(runs_of "$f")"
  done
  sleep 2
  waited=$((waited + 2))
  for f in "${!first[@]}"; do
    if [ "$(runs_of "$f")" -gt "${first[$f]}" ]; then cov="$f"; break; fi
  done
  unset first
  if [ "$waited" -ge "$FUZZ_STARTUP_TIMEOUT" ]; then
    echo "error: fuzzers did not start within ${FUZZ_STARTUP_TIMEOUT}s" >&2
    tail -n 60 "$LOG" >&2
    exit 1
  fi
done

read -r runs0 uniq0 pcs <<<"$(read_header "$cov")"
echo "fuzzing started after ${waited}s (coverage map $(basename "$cov"), $pcs instrumented PCs)"

failure_re='panic|failed with error|error logs detected|leaked|TestExpected|TestUnexpected|error: .*(failed|crashed|terminated)'
elapsed=0
while [ "$elapsed" -lt "$FUZZ_SECONDS" ]; do
  sleep 10
  elapsed=$((elapsed + 10))
  read -r runs uniq _ <<<"$(read_header "$cov")"
  echo "  t+${elapsed}s runs=$((runs - runs0)) new_unique_inputs=$((uniq - uniq0))"
  if grep -qE "$failure_re" "$LOG"; then break; fi
  if ! kill -0 "$pgid" 2>/dev/null; then break; fi
done

read -r runs uniq _ <<<"$(read_header "$cov")"
seen="$(python3 - "$cov" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
n_runs, uniq, pcs = struct.unpack("<QQQ", data[:24])
words = (pcs + 63) // 64
bits = data[24:24 + words * 8]
print(sum(bin(b).count("1") for b in bits))
PY
)"
trap - EXIT
stop_all

echo "=== campaign summary ==="
echo "executions: $((runs - runs0)) this campaign ($runs total)"
echo "corpus-growing inputs: $((uniq - uniq0)) this campaign ($uniq total)"
echo "coverage: $seen / $pcs instrumented PCs reached"
echo "corpus: $(find "$FUZZ_CACHE_DIR/f" -type f 2>/dev/null | wc -l) saved inputs under $FUZZ_CACHE_DIR/f"

if grep -qE "$failure_re" "$LOG"; then
  echo "FAIL: a fuzzer found a bug. Details:" >&2
  grep -nE -B2 -A30 "$failure_re" "$LOG" | head -n 200 >&2
  echo "Full log: $LOG. Crashing inputs are the 'in' files under $FUZZ_CACHE_DIR/f/<test>." >&2
  exit 1
fi
echo "PASS: every fuzzer ran for ${FUZZ_SECONDS}s without a failure."
