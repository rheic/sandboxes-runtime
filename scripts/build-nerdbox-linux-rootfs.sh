#!/bin/sh
# Rebuild the pinned nerdbox ARM64 guest rootfs with the route-only vminitd fix.
set -eu

: "${NERDBOX_SRC:?set NERDBOX_SRC to a clean nerdbox v0.2.5 checkout}"
: "${BASE_ROOTFS:?set BASE_ROOTFS to the pinned upstream ARM64 EROFS rootfs}"
: "${OUT:?set OUT to a path that does not exist}"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NERDBOX_COMMIT=28c86e8e16c62a08079531ebe99e24a7bdad3d62
BASE_ROOTFS_SHA256=bb7b4ba4df5047d67d0af0ffc9c92b891d8553d4c78a30c14219d079dd003cc3
PATCH_SHA256=521a3370d53515be4f07404b67124e57a387fb62b6c97368d1053fc15ba3f569
ROOTFS_UUID=2f7d7270-8b51-4db0-9fd9-f22cbf109ec2

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != aarch64 ]; then
	echo "rootfs build requires Linux ARM64" >&2
	exit 1
fi
if [ "$(go version)" != 'go version go1.27.3 linux/arm64' ]; then
	echo "rootfs build requires Go 1.27.3 linux/arm64" >&2
	exit 1
fi
if [ "$(fsck.erofs -V)" != 'fsck.erofs 1.7.1' ]; then
	echo "rootfs build requires erofs-utils 1.7.1" >&2
	exit 1
fi
case "$OUT" in
	/*) ;;
	*) echo "OUT must be an absolute path" >&2; exit 1 ;;
esac
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
	echo "refusing to overwrite existing rootfs output: $OUT" >&2
	exit 1
fi
if [ ! -f "$BASE_ROOTFS" ] || [ -L "$BASE_ROOTFS" ]; then
	echo "BASE_ROOTFS must be a regular, non-symlink file" >&2
	exit 1
fi
actual_base_sha=$(sha256sum "$BASE_ROOTFS" | awk '{print $1}')
if [ "$actual_base_sha" != "$BASE_ROOTFS_SHA256" ]; then
	echo "base rootfs checksum mismatch: got $actual_base_sha" >&2
	exit 1
fi
actual_patch_sha=$(sha256sum "$ROOT/build/patches/nerdbox-network-route-only.patch" | awk '{print $1}')
if [ "$actual_patch_sha" != "$PATCH_SHA256" ]; then
	echo "network patch checksum mismatch: got $actual_patch_sha" >&2
	exit 1
fi
"$ROOT/scripts/verify-pinned-source.sh" "$NERDBOX_SRC" "$NERDBOX_COMMIT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rheic-nerdbox-rootfs.XXXXXX")
OUT_TMP=
cleanup() {
	if [ -n "$OUT_TMP" ]; then
		rm -f -- "$OUT_TMP"
	fi
	rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cp -R "$NERDBOX_SRC" "$WORK/src"
chmod -R u+w "$WORK/src"
"$ROOT/scripts/verify-pinned-source.sh" "$WORK/src" "$NERDBOX_COMMIT"
cd "$WORK/src"
git apply --check "$ROOT/build/patches/nerdbox-network-route-only.patch"
git apply "$ROOT/build/patches/nerdbox-network-route-only.patch"

GOWORK=off GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
	go build -trimpath -buildvcs=false \
	-tags 'osusergo netgo static_build no_grpc' \
	-ldflags='-s -w -buildid=' -o "$WORK/vminitd" ./cmd/vminitd

mkdir "$WORK/rootfs"
fsck.erofs --extract="$WORK/rootfs" "$BASE_ROOTFS"
if [ ! -f "$WORK/rootfs/sbin/crun" ] || [ ! -f "$WORK/rootfs/sbin/vminitd" ]; then
	echo "base EROFS rootfs is missing the pinned nerdbox guest binaries" >&2
	exit 1
fi
base_vminitd_mtime=$(stat -c %Y "$WORK/rootfs/sbin/vminitd")
install -m 0755 "$WORK/vminitd" "$WORK/rootfs/sbin/vminitd"
mkfs.erofs -zlz4 --all-root -U "$ROOTFS_UUID" -T "$base_vminitd_mtime" "$WORK/rootfs.erofs" "$WORK/rootfs"

mkdir "$WORK/verify"
fsck.erofs --extract="$WORK/verify" "$WORK/rootfs.erofs"
cmp "$WORK/vminitd" "$WORK/verify/sbin/vminitd"
mkdir -p "$(dirname -- "$OUT")"
OUT_TMP=$(mktemp "${OUT}.tmp.XXXXXX")
cat "$WORK/rootfs.erofs" >"$OUT_TMP"
if ! ln -T "$OUT_TMP" "$OUT"; then
	echo "refusing to overwrite rootfs output: $OUT" >&2
	exit 1
fi
rm -f -- "$OUT_TMP"
OUT_TMP=
sha256sum "$OUT"
