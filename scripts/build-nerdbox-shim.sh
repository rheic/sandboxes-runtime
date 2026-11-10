#!/bin/sh
# Build the nerdbox shim with Linux raw-virtio EROFS support. The pinned Linux
# block-device mapping allows at most 25 container disks plus the reserved
# rootfs disk; larger stacks use the existing host-mount/virtiofs fallback
# before the unsupported GPT VMDK path. The proxy channel patch adds a
# guest-dialed vsock port bridged to a host unix socket.
set -eu
: "${NERDBOX_SRC:?set NERDBOX_SRC to an unpacked nerdbox v0.2.5 tree}"
: "${OUT:?set OUT to the shim output path}"
case "$OUT" in
  */) echo "OUT must name a file, not a directory: $OUT" >&2; exit 1 ;;
esac
if [ -L "$OUT" ]; then
  echo "refusing symlink shim output: $OUT" >&2
  exit 1
fi
if [ -d "$OUT" ]; then
  echo "refusing directory shim output: $OUT" >&2
  exit 1
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_OS=$(uname -s)
case "$HOST_OS" in
  Darwin)
    LIBKRUN_PREFIX=${LIBKRUN_PREFIX:-/opt/homebrew/opt/libkrun}
    LIBKRUN_LIBDIR=${LIBKRUN_LIBDIR:-$LIBKRUN_PREFIX/lib}
    ;;
  Linux)
    : "${LIBKRUN_PREFIX:?set LIBKRUN_PREFIX to the prefix containing the pinned Linux libkrun build}"
    EXPECTED_LIBKRUN_LIBDIR=$LIBKRUN_PREFIX/lib64
    if [ -n "${LIBKRUN_LIBDIR:-}" ] && [ "$LIBKRUN_LIBDIR" != "$EXPECTED_LIBKRUN_LIBDIR" ]; then
      echo "Linux LIBKRUN_LIBDIR must be $EXPECTED_LIBKRUN_LIBDIR" >&2
      exit 1
    fi
    LIBKRUN_LIBDIR=$EXPECTED_LIBKRUN_LIBDIR
    "$ROOT/scripts/verify-libkrun-linux-prefix.sh" "$LIBKRUN_PREFIX"
    ;;
  *)
    echo "unsupported shim build host: $HOST_OS" >&2
    exit 1
    ;;
esac
"$ROOT/scripts/verify-pinned-source.sh" "$NERDBOX_SRC" 28c86e8e16c62a08079531ebe99e24a7bdad3d62
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rheic-nerdbox-build.XXXXXX")
OUT_TMP=
cleanup() {
  if [ -n "$OUT_TMP" ]; then
    rm -f -- "$OUT_TMP"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
cp -R "$NERDBOX_SRC" "$WORK/src"
chmod -R u+w "$WORK/src"
"$ROOT/scripts/verify-pinned-source.sh" "$WORK/src" 28c86e8e16c62a08079531ebe99e24a7bdad3d62
cd "$WORK/src"
git apply "$ROOT/build/patches/nerdbox-gpt-threshold.patch"
git apply "$ROOT/build/patches/nerdbox-linux-host-mount-cleanup.patch"
git apply "$ROOT/build/patches/nerdbox-proxy-channel.patch"
git apply "$ROOT/build/patches/nerdbox-linux-shutdown-symbol.patch"
git apply "$ROOT/build/patches/nerdbox-ttrpc-close-once.patch"
CGO_ENABLED=1 \
CGO_CFLAGS="-I$LIBKRUN_PREFIX/include" \
CGO_LDFLAGS="-L$LIBKRUN_LIBDIR -lkrun" \
GOWORK=off go build -trimpath -buildvcs=false -ldflags=-buildid= -o "$WORK/shim" ./cmd/containerd-shim-nerdbox-v1
if [ "$HOST_OS" = Darwin ]; then
  codesign --force --sign - \
    --entitlements cmd/containerd-shim-nerdbox-v1/containerd-shim-nerdbox-v1.entitlements \
    "$WORK/shim"
fi
OUT_DIR=$(dirname -- "$OUT")
mkdir -p "$OUT_DIR"
OUT_TMP=$(mktemp "$OUT.tmp.XXXXXX")
cp "$WORK/shim" "$OUT_TMP"
chmod 0755 "$OUT_TMP"
if [ -L "$OUT" ]; then
  echo "refusing symlink shim output: $OUT" >&2
  exit 1
fi
mv -f "$OUT_TMP" "$OUT"
OUT_TMP=
if [ "$HOST_OS" = Darwin ]; then
  shasum -a 256 "$OUT"
else
  sha256sum "$OUT"
fi
