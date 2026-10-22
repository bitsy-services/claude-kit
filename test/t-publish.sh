#!/usr/bin/env bash
# kit publish, in a clone of the toy kit whose origin is a local bare repo.
# It refuses on main, on a dirty tree, on a red selftest and when slices/
# changed without a CHANGELOG entry; otherwise it fast-forwards main to the
# topic and pushes main to origin. The toy kit has no test/run.sh, so its
# selftest runs only the lints (R3).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
mk_kit "$TEST_ROOT/test/kits/toy/slices"
git clone -q --bare "$T/kit" "$T/origin.git"
N=0

# fresh: a new clone of the origin in $C, on a new topic branch.
fresh() {
  N=$((N + 1))
  C="$T/clone$N"
  git clone -q "$T/origin.git" "$C"
  git -C "$C" switch -q -c "topic$N"
  MAIN0="$(git -C "$T/origin.git" rev-parse main)"
}

# change <file> <line> <message>: append the line to the file and commit it.
change() {
  printf '%s\n' "$2" >> "$C/$1"
  git -C "$C" add -- "$1"
  git -C "$C" commit -q -m "$3"
}

publish() {
  OUT="$(cd "$C" && bash "$C/bin/kit" publish 2>&1)" && RC=0 || RC=$?
}

# unmoved <label>: neither the clone's main nor origin's main moved.
unmoved() {
  is "$(git -C "$C" rev-parse main)" "$MAIN0" "$1: main is unmoved"
  is "$(git -C "$T/origin.git" rev-parse main)" "$MAIN0" "$1: origin's main is unmoved"
}

t_on_main() {
  fresh
  git -C "$C" switch -q main
  change README.md "a line" "Touch the readme"
  MAIN0="$(git -C "$T/origin.git" rev-parse main)"
  publish
  like "$OUT" '^publish: run it on the topic branch$' "on main: refused"
  is "$RC" 2 "on main: exits 2"
  is "$(git -C "$T/origin.git" rev-parse main)" "$MAIN0" "on main: origin's main is unmoved"
}

t_detached() {
  fresh
  git -C "$C" switch -q --detach HEAD
  publish
  like "$OUT" '^publish: run it on the topic branch$' "detached: refused"
  is "$RC" 2 "detached: exits 2"
}

t_dirty() {
  fresh
  change slices/core/rules/a.md "Changed." "Change a rule"
  change CHANGELOG.md "- a.md: changed." "Log the change"
  printf 'stray\n' > "$C/notes.txt"
  publish
  like "$OUT" '^publish: the tree is dirty' "dirty: refused"
  is "$RC" 1 "dirty: exits 1"
  unmoved dirty
}

t_no_changelog() {
  fresh
  change slices/core/rules/a.md "Changed." "Change a rule"
  publish
  like "$OUT" '^publish: slices changed without a CHANGELOG entry$' "no entry: refused"
  is "$RC" 1 "no entry: exits 1"
  unmoved "no entry"
  is "$(git -C "$C" branch --show-current)" "topic$N" "no entry: still on the topic"
}

t_red_selftest() {
  fresh
  printf '# x\n# then: rm -rf "$tmp"\n' > "$C/lib/zz.sh"
  git -C "$C" add lib/zz.sh
  git -C "$C" commit -q -m "Plant a lint"
  publish
  like "$OUT" '^LINT rm-r lib/zz\.sh' "red selftest: the LINT line shows"
  like "$OUT" '^publish: selftest failed$' "red selftest: refused"
  is "$RC" 1 "red selftest: exits 1"
  unmoved "red selftest"
}

t_published() {
  local head
  fresh
  change slices/core/rules/a.md "Changed." "Change a rule"
  change CHANGELOG.md "- a.md: changed." "Log the change"
  head="$(git -C "$C" rev-parse HEAD)"
  publish
  is "$RC" 0 "published: exits 0"
  like "$OUT" '^selftest: ok$' "published: selftest ran"
  like "$OUT" '^published [0-9a-f]{7}$' "published: says so"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "published ${head:0:7}" "published: names the topic head"
  is "$(git -C "$T/origin.git" rev-parse main)" "$head" "published: origin's main is the topic head"
  is "$(git -C "$C" rev-parse main)" "$head" "published: main is the topic head"
}

# A change outside slices/ needs no CHANGELOG entry.
t_outside_slices() {
  local head
  fresh
  change README.md "a line" "Touch the readme"
  head="$(git -C "$C" rev-parse HEAD)"
  publish
  is "$RC" 0 "outside slices: exits 0"
  is "$(git -C "$T/origin.git" rev-parse main)" "$head" "outside slices: origin's main is the topic head"
}

# main has a commit the topic lacks: no fast-forward, back on the topic.
t_diverged() {
  local b
  fresh
  b="topic$N"
  git -C "$C" switch -q main
  change README.md "on main" "Move main"
  git -C "$C" switch -q "$b"
  change README.md "on topic" "Move the topic"
  MAIN0="$(git -C "$T/origin.git" rev-parse main)"
  local main1
  main1="$(git -C "$C" rev-parse main)"
  publish
  like "$OUT" "^publish: main cannot fast-forward to $b" "diverged: refused"
  is "$RC" 1 "diverged: exits 1"
  is "$(git -C "$C" rev-parse main)" "$main1" "diverged: main is unmoved"
  is "$(git -C "$T/origin.git" rev-parse main)" "$MAIN0" "diverged: origin's main is unmoved"
  is "$(git -C "$C" branch --show-current)" "$b" "diverged: back on the topic"
}

# origin's main moved since the clone: the push is rejected, main goes back
# to where it was, and the topic is checked out again.
t_push_rejected() {
  local b other
  fresh
  b="topic$N"
  git clone -q "$T/origin.git" "$T/other"
  printf 'elsewhere\n' >> "$T/other/README.md"
  git -C "$T/other" add README.md
  git -C "$T/other" commit -q -m "Publish elsewhere"
  git -C "$T/other" push -q origin main
  other="$(git -C "$T/other" rev-parse HEAD)"
  change README.md "on topic" "Move the topic"
  publish
  like "$OUT" "^publish: the push failed; main is back at ${MAIN0:0:7}$" "push rejected: refused"
  is "$RC" 1 "push rejected: exits 1"
  is "$(git -C "$C" rev-parse main)" "$MAIN0" "push rejected: main is back where it was"
  is "$(git -C "$C" branch --show-current)" "$b" "push rejected: back on the topic"
  is "$(git -C "$T/origin.git" rev-parse main)" "$other" "push rejected: origin's main is untouched"
}

t_on_main
t_detached
t_dirty
t_no_changelog
t_red_selftest
t_published
t_outside_slices
t_diverged
t_push_rejected
done_testing
