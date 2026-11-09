#!/bin/sh
# Build the pinned Linux/arm64 libkrun + kernel firmware stack.
set -eu
: "${LIBKRUN_PREFIX:?set LIBKRUN_PREFIX to an absolute output prefix}"
case "$LIBKRUN_PREFIX" in
  /*) ;;
  *) echo "LIBKRUN_PREFIX must be an absolute path" >&2; exit 1 ;;
esac
mkdir -p "$LIBKRUN_PREFIX"
if [ -n "$(find "$LIBKRUN_PREFIX" -mindepth 1 -print -quit)" ]; then
  echo "LIBKRUN_PREFIX must be empty; refusing to overwrite an existing prefix" >&2
  exit 1
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JOBS=${JOBS:-4}
case "$JOBS" in
  ''|*[!0-9]*|0) echo "JOBS must be a positive integer" >&2; exit 1 ;;
esac
RUST_VERSION=1.90.0
LIBKRUN_COMMIT=227b2de6ed323fe180e02f871c5f325a90c13cc2
LIBKRUNFW_COMMIT=f14ac64ca8a04c6c9d76cac1c61ee050809c88c9
KERNEL_VERSION=linux-6.12.109
KERNEL_SHA256=5484e552a334e15019f4aeba89e5b58f04651cf2f4e24e04de9f152f1c38e3fa
KERNEL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/$KERNEL_VERSION.tar.xz

# A caller's jobserver flags can be parsed as a make target by libkrunfw's
# kernel sub-build. Keep all recursive make invocations scoped to this recipe.
unset MAKEFLAGS MFLAGS

RUSTUP_TOOLCHAIN=$RUST_VERSION rustc --version | awk -v want="$RUST_VERSION" '$2 != want { exit 1 } END { if (NR != 1) exit 1 }' || {
  echo "rustc $RUST_VERSION is required" >&2
  exit 1
}
GCC_VERSION=$(gcc -dumpfullversion -dumpversion)
case "$GCC_VERSION" in
  13.3.0) ;;
  *) echo "GCC 13.3.0 is required, found $GCC_VERSION" >&2; exit 1 ;;
esac
for tool in git make curl sha256sum strip cargo; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool" >&2; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rheic-libkrun-linux.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
# Rust embeds source paths in release binaries. Normalize only this isolated,
# randomly named checkout so independent builds produce identical artifacts.
RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$WORK=/usr/src"
export RUSTFLAGS
INFO_DIR=$LIBKRUN_PREFIX/share/rheic-runtime

checkout_source() {
  source_url=$1
  commit=$2
  output_path=$3
  git clone --filter=blob:none --no-checkout "$source_url" "$output_path"
  git -C "$output_path" checkout --detach "$commit"
  "$ROOT/scripts/verify-pinned-source.sh" "$output_path" "$commit"
  printf '%s\n' "$output_path"
}

LIBKRUN_SRC=$(checkout_source https://github.com/containers/libkrun "$LIBKRUN_COMMIT" "$WORK/libkrun")
LIBKRUNFW_SRC=$(checkout_source https://github.com/containers/libkrunfw "$LIBKRUNFW_COMMIT" "$WORK/libkrunfw")

RUSTUP_TOOLCHAIN=$RUST_VERSION make -C "$LIBKRUN_SRC" -j "$JOBS" BLK=1 NET=1 PREFIX="$LIBKRUN_PREFIX" all
if ! git -C "$LIBKRUN_SRC" diff --quiet -- Cargo.lock; then
  echo "libkrun build changed Cargo.lock" >&2
  exit 1
fi
RUSTUP_TOOLCHAIN=$RUST_VERSION make -C "$LIBKRUN_SRC" BLK=1 NET=1 PREFIX="$LIBKRUN_PREFIX" install

KERNEL_TARBALL=$LIBKRUNFW_SRC/tarballs/$KERNEL_VERSION.tar.xz
mkdir -p "$(dirname -- "$KERNEL_TARBALL")"
curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --output "$KERNEL_TARBALL" "$KERNEL_URL"
printf '%s  %s\n' "$KERNEL_SHA256" "$KERNEL_TARBALL" | sha256sum --check --status || {
  echo "kernel source SHA-256 verification failed" >&2
  exit 1
}
(cd "$LIBKRUNFW_SRC" && make -j "$JOBS" ARCH=arm64 all)
(cd "$LIBKRUNFW_SRC" && make ARCH=arm64 PREFIX="$LIBKRUN_PREFIX" install)
KERNEL_IMAGE=$LIBKRUNFW_SRC/$KERNEL_VERSION/arch/arm64/boot/Image
test -s "$KERNEL_IMAGE" || { echo "built Linux kernel Image is missing" >&2; exit 1; }
install -m 0644 "$KERNEL_IMAGE" "$LIBKRUN_PREFIX/nerdbox-kernel-arm64"

LIBKRUN_SO=$LIBKRUN_PREFIX/lib64/libkrun.so.1.19.6
if [ -f "$LIBKRUN_PREFIX/lib/aarch64-linux-gnu/libkrunfw.so.5.6.2" ]; then
  LIBKRUNFW_SO=$LIBKRUN_PREFIX/lib/aarch64-linux-gnu/libkrunfw.so.5.6.2
else
  LIBKRUNFW_SO=$LIBKRUN_PREFIX/lib64/libkrunfw.so.5.6.2
fi
test -f "$LIBKRUN_SO" || { echo "pinned libkrun output missing" >&2; exit 1; }
test -f "$LIBKRUNFW_SO" || { echo "pinned libkrunfw output missing" >&2; exit 1; }
mkdir -p "$INFO_DIR"
INFO_TMP=$INFO_DIR/libkrun-linux-arm64-build-info.tmp
{
  printf 'libkrun_version=1.19.6\n'
  printf 'libkrun_commit=%s\n' "$LIBKRUN_COMMIT"
  printf 'libkrun_sha256=%s\n' "$(sha256sum "$LIBKRUN_SO" | awk '{print $1}')"
  printf 'libkrunfw_version=5.6.2\n'
  printf 'libkrunfw_commit=%s\n' "$LIBKRUNFW_COMMIT"
  printf 'libkrunfw_sha256=%s\n' "$(sha256sum "$LIBKRUNFW_SO" | awk '{print $1}')"
  printf 'kernel_version=%s\n' "$KERNEL_VERSION"
  printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
  printf 'kernel_image_sha256=%s\n' "$(sha256sum "$LIBKRUN_PREFIX/nerdbox-kernel-arm64" | awk '{print $1}')"
  printf 'rustc_version=%s\n' "$RUST_VERSION"
  printf 'gcc_version=%s\n' "$GCC_VERSION"
} > "$INFO_TMP"
chmod 0644 "$INFO_TMP"
mv "$INFO_TMP" "$INFO_DIR/libkrun-linux-arm64-build-info"
"$ROOT/scripts/verify-libkrun-linux-prefix.sh" "$LIBKRUN_PREFIX"
