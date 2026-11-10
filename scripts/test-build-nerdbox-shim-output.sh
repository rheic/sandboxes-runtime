#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rheic-shim-output-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

printf 'preserve-me\n' >"$TMP/target"
ln -s "$TMP/target" "$TMP/output"
if NERDBOX_SRC="$TMP/missing-source" OUT="$TMP/output" \
  sh "$ROOT/scripts/build-nerdbox-shim.sh" >"$TMP/log" 2>&1; then
  echo "build script unexpectedly accepted a symlink output" >&2
  exit 1
fi
grep -Fq "refusing symlink shim output: $TMP/output" "$TMP/log"
test "$(cat "$TMP/target")" = "preserve-me"

if NERDBOX_SRC="$TMP/missing-source" OUT="$TMP/" \
  sh "$ROOT/scripts/build-nerdbox-shim.sh" >"$TMP/log" 2>&1; then
  echo "build script unexpectedly accepted a directory output" >&2
  exit 1
fi
grep -Fq "OUT must name a file, not a directory" "$TMP/log"
