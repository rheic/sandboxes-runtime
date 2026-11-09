#!/bin/sh
# Reject an unpinned or replaced Linux libkrun/libkrunfw prefix.
set -eu
: "${1:?usage: verify-libkrun-linux-prefix.sh LIBKRUN_PREFIX}"
PREFIX=$1
INFO=$PREFIX/share/rheic-runtime/libkrun-linux-arm64-build-info
LIBKRUN_COMMIT=227b2de6ed323fe180e02f871c5f325a90c13cc2
LIBKRUNFW_COMMIT=f14ac64ca8a04c6c9d76cac1c61ee050809c88c9
KERNEL_SHA256=5484e552a334e15019f4aeba89e5b58f04651cf2f4e24e04de9f152f1c38e3fa

test -f "$INFO" || { echo "missing pinned Linux libkrun build info: $INFO" >&2; exit 1; }
for pin in \
  "libkrun_version=1.19.6" \
  "libkrun_commit=$LIBKRUN_COMMIT" \
  "libkrunfw_version=5.6.2" \
  "libkrunfw_commit=$LIBKRUNFW_COMMIT" \
  "kernel_version=linux-6.12.109" \
  "kernel_sha256=$KERNEL_SHA256" \
  "rustc_version=1.90.0" \
  "gcc_version=13.3.0"; do
  key=${pin%%=*}
  count=$(grep -c "^$key=" "$INFO" || true)
  [ "$count" -eq 1 ] && grep -Fqx "$pin" "$INFO" || {
    echo "Linux libkrun build metadata does not match unique pin: $key" >&2
    exit 1
  }
done

field() {
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); count++ } END { if (count != 1) exit 1 }' "$INFO"
}

verify_digest() {
  name=$1
  path=$2
  expected=$(field "${name}_sha256") || { echo "missing $name digest in build metadata" >&2; exit 1; }
  case "$expected" in
    *[!0-9a-f]*|'') echo "invalid $name digest in build metadata" >&2; exit 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { echo "invalid $name digest length" >&2; exit 1; }
  actual=$(sha256sum "$path" | awk '{print $1}')
  [ "$actual" = "$expected" ] || { echo "$name digest does not match build metadata" >&2; exit 1; }
}

verify_library() {
  name=$1
  path=$2
  test -f "$path" || { echo "required pinned library is missing: $path" >&2; exit 1; }
  expected=$(field "${name}_sha256") || { echo "missing $name digest in build metadata" >&2; exit 1; }
  case "$expected" in
    *[!0-9a-f]*|'') echo "invalid $name digest in build metadata" >&2; exit 1 ;;
  esac
  [ "${#expected}" -eq 64 ] || { echo "invalid $name digest length" >&2; exit 1; }
  actual=$(sha256sum "$path" | awk '{print $1}')
  [ "$actual" = "$expected" ] || { echo "$name library digest does not match build metadata" >&2; exit 1; }
}

verify_library libkrun "$PREFIX/lib64/libkrun.so.1.19.6"
if [ -f "$PREFIX/lib/aarch64-linux-gnu/libkrunfw.so.5.6.2" ]; then
  verify_library libkrunfw "$PREFIX/lib/aarch64-linux-gnu/libkrunfw.so.5.6.2"
else
  verify_library libkrunfw "$PREFIX/lib64/libkrunfw.so.5.6.2"
fi
KERNEL_IMAGE=$PREFIX/nerdbox-kernel-arm64
test -s "$KERNEL_IMAGE" || { echo "required pinned kernel Image is missing: $KERNEL_IMAGE" >&2; exit 1; }
verify_digest kernel_image "$KERNEL_IMAGE"
