#!/usr/bin/env bash
# Each test/fixtures/<f>/ renders the real slices into a consumer built from
# its inputs, passes kit check, and its whole .claude/ (without vendor/, the
# lock's pin read as "PIN") equals test/fixtures/<f>/expected/.claude.
# KIT_UPDATE_EXPECTED=1 rewrites expected/ from the render instead, and only
# when render and check both pass.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
mk_kit "$TEST_ROOT/slices"

# snapshot <out>: $CON/.claude without vendor/ into <out>/.claude, with the
# lock's pin replaced by "PIN" and nothing else changed.
snapshot() {
  local out="$1" e
  mkdir -p "$out/.claude"
  for e in "$CON/.claude"/* "$CON/.claude"/.[!.]*; do
    [ -e "$e" ] || continue
    [ "${e##*/}" = vendor ] && continue
    cp -R "$e" "$out/.claude/"
  done
  jq '.pin = "PIN"' "$CON/.claude/kit.lock.json" > "$out/.claude/kit.lock.json"
}

# fixture <dir>: render, check and compare one fixture.
fixture() {
  local fx="${1%/}" name got ok=1 d out
  name="${fx##*/}"
  got="$T/got/$name"
  mk_consumer "$fx" "$T/con/$name"
  kit_run render
  is "$RC" 0 "$name: render exits 0"
  [ "$RC" = 0 ] || { ok=0; printf '%s\n' "$OUT" | sed 's/^/#   /'; }
  kit_run check
  is "$RC" 0 "$name: kit check exits 0"
  [ "$RC" = 0 ] || { ok=0; printf '%s\n' "$OUT" | sed 's/^/#   /'; }
  snapshot "$got"
  is "$(grep -rlF '{{kit.' "$got/.claude" || true)" "" "$name: no {{kit. is left"

  if [ "${KIT_UPDATE_EXPECTED:-}" = 1 ]; then
    if [ "$ok" = 1 ]; then
      rm -rf "$fx/expected"
      mkdir -p "$fx/expected"
      cp -R "$got/.claude" "$fx/expected/.claude"
    fi
    _t_report "$((1 - ok))" "$name: expected/ rewritten"
    return
  fi
  out="$(diff -r "$fx/expected/.claude" "$got/.claude" 2>&1)" && d=0 || d=$?
  is "$d" 0 "$name: .claude equals expected/.claude"
  [ "$d" = 0 ] || printf '%s\n' "$out" | sed 's/^/#   /'
}

for f in "$TEST_ROOT"/test/fixtures/*/; do
  fixture "$f"
done
done_testing
