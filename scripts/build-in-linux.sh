#!/bin/sh
# Build all 4 prebuilt claude-p targets inside a Linux container and emit
# gzipped release assets to release-assets/. On Linux, zig uses its bundled
# macOS libSystem stub, so the darwin targets cross-compile without an SDK
# (which is exactly what fails on a macOS host carrying a too-new system SDK).
set -e

ZIG_VERSION=0.15.2
case "$(uname -m)" in
  aarch64|arm64) ZARCH=aarch64 ;;
  x86_64|amd64)  ZARCH=x86_64 ;;
  *) echo "unsupported container arch $(uname -m)"; exit 1 ;;
esac

echo "=== installing toolchain (apk) ==="
apk add --no-cache build-base curl tar xz git >/dev/null

echo "=== fetching zig ${ZIG_VERSION} (${ZARCH}-linux) ==="
mkdir -p /opt/zig
curl -fL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz
tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
export PATH="/opt/zig:$PATH"
zig version

cd /src
rm -rf release-assets && mkdir -p release-assets

build() { # asset-name  zig-target
  name="$1"; tgt="$2"
  echo "=== building ${name} (${tgt}) ==="
  rm -rf "/tmp/stage-${name}"
  zig build -Doptimize=ReleaseSafe -Dtarget="${tgt}" \
    --cache-dir /tmp/zc --global-cache-dir /tmp/zgc \
    -p "/tmp/stage-${name}"
  test -f "/tmp/stage-${name}/bin/claude-p"
  gzip -9 -c "/tmp/stage-${name}/bin/claude-p" > "release-assets/claude-p-${name}.gz"
  ls -la "release-assets/claude-p-${name}.gz"
}

build darwin-arm64  aarch64-macos
build darwin-x64    x86_64-macos
build linux-x64     x86_64-linux-musl
build linux-arm64   aarch64-linux-musl

echo "=== done ==="
ls -la release-assets/
# Make assets owned by the mount user (root in container -> fix perms loosely)
chmod -R 0644 release-assets/*.gz
