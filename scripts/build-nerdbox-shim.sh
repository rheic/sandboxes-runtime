#!/bin/sh
# Build the nerdbox shim with raw-virtio multi-layer support. The upstream
# gptLayerThreshold=8 path produces a GPT VMDK that libkrun 1.19.6 rejects;
# the patch keeps up to 128 plain EROFS layers on raw virtio disks. The proxy
# channel patch adds a guest-dialed vsock port bridged to a host unix socket.
set -eu
: "${NERDBOX_SRC:?set NERDBOX_SRC to an unpacked nerdbox v0.2.5 tree}"
: "${OUT:?set OUT to the shim output path}"
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
trap 'rm -rf "$WORK"' EXIT INT TERM
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
mkdir -p "$(dirname -- "$OUT")"
cp "$WORK/shim" "$OUT"
chmod 0755 "$OUT"
if [ "$HOST_OS" = Darwin ]; then
  shasum -a 256 "$OUT"
else
  sha256sum "$OUT"
fi
