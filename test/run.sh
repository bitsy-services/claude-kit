#!/usr/bin/env bash
# Runs every test/t-*.sh in its own bash process.
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
files=0
failed=0
for f in "$dir"/t-*.sh; do
  [ -e "$f" ] || continue
  files=$((files + 1))
  echo "# $(basename "$f")"
  if ! bash "$f"; then
    failed=$((failed + 1))
    echo "# FAILED $(basename "$f")"
  fi
done
echo "$files files, $failed failed"
[ "$failed" = 0 ]
