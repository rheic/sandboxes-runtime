#!/bin/sh
# Build pinned containerd with the fail-closed bundle mount-boundary patch.
set -eu
: "${CONTAINERD_SRC:?set CONTAINERD_SRC to a clean containerd v2.4.2 checkout}"
: "${OUT_DIR:?set OUT_DIR to a new output directory}"
case "$OUT_DIR" in
  */) OUT_DIR=${OUT_DIR%/} ;;
esac
if [ -e "$OUT_DIR" ] || [ -L "$OUT_DIR" ]; then
  echo "refusing existing output path: $OUT_DIR" >&2
  exit 1
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMIT=b7a25261e029d68978bbf290df0a62fc819b3c51
"$ROOT/scripts/verify-pinned-source.sh" "$CONTAINERD_SRC" "$COMMIT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rheic-containerd-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
cp -R "$CONTAINERD_SRC" "$WORK/src"
chmod -R u+w "$WORK/src"
"$ROOT/scripts/verify-pinned-source.sh" "$WORK/src" "$COMMIT"
cd "$WORK/src"
git apply "$ROOT/build/patches/containerd-bundle-remove-no-xdev.patch"
GOWORK=off GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags=-buildid= -o "$WORK/containerd" ./cmd/containerd
GOWORK=off GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags=-buildid= -o "$WORK/ctr" ./cmd/ctr
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ]; then
  "$WORK/containerd" --version
  "$WORK/ctr" --version
else
  echo "built linux/arm64 containerd and ctr; execution smoke skipped on $(uname -s)/$(uname -m) host"
fi
mkdir -p "$(dirname -- "$OUT_DIR")"
mkdir "$OUT_DIR"
cp "$WORK/containerd" "$OUT_DIR/containerd"
cp "$WORK/ctr" "$OUT_DIR/ctr"
chmod 0755 "$OUT_DIR/containerd" "$OUT_DIR/ctr"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT_DIR/containerd" "$OUT_DIR/ctr"
else
  shasum -a 256 "$OUT_DIR/containerd" "$OUT_DIR/ctr"
fi
