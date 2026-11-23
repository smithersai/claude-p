#!/bin/sh
# Build all 4 prebuilt claude-p targets inside a Linux container and emit
# gzipped assets and SHA256SUMS to release-assets/. Zig's bundled macOS
# libSystem stub lets the darwin targets cross-compile without an SDK.
# Afterwards, on the host, write checksums.json from these assets with:
#   node scripts/publish.mjs --from-assets --local-only --skip-git
set -e

ZIG_VERSION=0.15.2
# Official SHA-256 digests from https://ziglang.org/download/index.json
# ("0.15.2" -> "<arch>-linux" -> "shasum").
case "$(uname -m)" in
  aarch64|arm64) ZARCH=aarch64; ZIG_SHA256=958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f ;;
  x86_64|amd64)  ZARCH=x86_64;  ZIG_SHA256=02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 ;;
  *) echo "unsupported container arch $(uname -m)"; exit 1 ;;
esac

echo "=== installing toolchain (apk) ==="
apk add --no-cache build-base curl tar xz git >/dev/null

echo "=== fetching zig ${ZIG_VERSION} (${ZARCH}-linux) ==="
mkdir -p /opt/zig
curl -fL --proto '=https' --tlsv1.2 "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz
echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - || { echo "zig tarball SHA-256 mismatch"; rm -f /tmp/zig.tar.xz; exit 1; }
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

(cd release-assets && sha256sum claude-p-*.gz > SHA256SUMS)
chmod 0644 release-assets/*.gz release-assets/SHA256SUMS

echo "=== done ==="
ls -la release-assets/
