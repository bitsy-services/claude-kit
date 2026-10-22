#!/usr/bin/env bash
# scratch_new / scratch_cleanup (R10): the only way bin/ and lib/ make and remove scratch dirs.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
S="$T/s"
mkdir -p "$S"

# run <code> [args...]: run code under set -euo pipefail with lib/common.sh
# sourced and TMPDIR=$S; $1.. are the args. Sets OUT and RC.
run() {
  local code="$1"
  shift
  OUT="$(TMPDIR="$S" bash -c 'set -euo pipefail; . "$0"; '"$code" "$TEST_ROOT/lib/common.sh" "$@" 2>&1)" && RC=0 || RC=$?
}

run 'scratch_new d; mkdir -p "$d/a/b"; : > "$d/a/b/f"; printf "%s\n" "$d"'
is "$RC" 0 "a run that made a scratch dir exits 0"
like "$OUT" "^$S/claude-kit\.[A-Za-z0-9]{6}\$" "scratch_new makes claude-kit.XXXXXX under TMPDIR"
no_file "$OUT"
is "$(ls -A "$S")" "" "the EXIT trap removes the dir and its contents"

run 'scratch_new d; scratch_new e; printf "%s\n" "$d" "$e"; exit 3'
is "$RC" 3 "the EXIT trap keeps the exit status"
is "$(ls -A "$S")" "" "every registered dir is removed"

mkdir -p "$T/victim"
: > "$T/victim/keep"
run 'scratch_new d; ln -s "$1" "$2/claude-kit.LINKED"; KIT_SCRATCH+=("$2/claude-kit.LINKED")' "$T/victim" "$S"
is "$RC" 0 "a refused path does not change the exit status"
like "$OUT" 'not removing scratch path .*/claude-kit\.LINKED' "a symlink is refused"
has_file "$T/victim/keep"
rm -f "$S/claude-kit.LINKED"

mkdir -p "$T/other"
: > "$T/other/keep"
run 'KIT_SCRATCH+=("$1"); scratch_cleanup' "$T/other"
like "$OUT" "not removing scratch path $T/other" "a dir without the claude-kit. prefix is refused"
has_file "$T/other/keep"

: > "$S/claude-kit.ABCDEF"
run 'KIT_SCRATCH+=("$1"); scratch_cleanup' "$S/claude-kit.ABCDEF"
like "$OUT" 'not removing scratch path .*/claude-kit\.ABCDEF' "a regular file is refused"
has_file "$S/claude-kit.ABCDEF"

done_testing
