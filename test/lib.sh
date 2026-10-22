# Test harness. Source from a t-*.sh file; no `set -e` here on purpose.
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GIT_AUTHOR_NAME=kit-test GIT_AUTHOR_EMAIL=kit-test@example.invalid
export GIT_COMMITTER_NAME=kit-test GIT_COMMITTER_EMAIL=kit-test@example.invalid
export GIT_CONFIG_NOSYSTEM=1
T_N=0
T_FAIL=0
OUT=""
RC=0

t_setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
}

mk_kit() {
  local slices="$1"
  mkdir -p "$T/kit/slices"
  cp -R "$TEST_ROOT/bin" "$T/kit/bin"
  cp -R "$TEST_ROOT/lib" "$T/kit/lib"
  cp -R "$slices/." "$T/kit/slices/"
  : > "$T/kit/CHANGELOG.md"
  git -C "$T/kit" init -q -b main
  git -C "$T/kit" add -A
  git -C "$T/kit" commit -q -m "kit fixture"
  KIT_HEAD="$(git -C "$T/kit" rev-parse HEAD)"
}

# R33: nothing under test/ may carry a name Claude Code loads as
# instructions, so consumer inputs and fixture trees store .claude as
# dot-claude and CLAUDE.md as CLAUDE.md.in.

# restore_names <dir>: under <dir>, rename each dot-claude directory to
# .claude and each CLAUDE.md.in file to CLAUDE.md.
restore_names() {
  local p
  while IFS= read -r -d '' p; do
    mv "$p" "${p%/*}/.claude"
  done < <(find "$1" -depth -type d -name dot-claude -print0)
  while IFS= read -r -d '' p; do
    mv "$p" "${p%/*}/CLAUDE.md"
  done < <(find "$1" -type f -name CLAUDE.md.in -print0)
}

# store_names <dir>: the inverse of restore_names.
store_names() {
  local p
  while IFS= read -r -d '' p; do
    mv "$p" "${p%/*}/dot-claude"
  done < <(find "$1" -depth -type d -name .claude -print0)
  while IFS= read -r -d '' p; do
    mv "$p" "${p%/*}/CLAUDE.md.in"
  done < <(find "$1" -type f -name CLAUDE.md -print0)
}

# mk_consumer <inputs> [dir]: a consumer repo from kit.json, repo.md,
# settings.json, CLAUDE.md.in and files/ (copied with names restored), with
# the kit vendored at .claude/vendor/kit.
mk_consumer() {
  local in="$1" dir="${2:-$T/con}" stage
  mkdir -p "$dir/.claude/rules"
  git -C "$dir" init -q -b topic
  cp "$in/kit.json" "$dir/.claude/kit.json"
  cp "$in/repo.md" "$dir/.claude/rules/repo.md"
  cp "$in/settings.json" "$dir/.claude/settings.json"
  cp "$in/CLAUDE.md.in" "$dir/CLAUDE.md"
  if [ -d "$in/files" ]; then
    stage="$(mktemp -d "$T/stage.XXXXXX")"
    cp -R "$in/files/." "$stage/"
    restore_names "$stage"
    cp -R "$stage/." "$dir/"
  fi
  git -C "$dir" -c protocol.file.allow=always submodule add -q "file://$T/kit" .claude/vendor/kit
  # R15: .gitmodules records the public https URL; the clone keeps fetching
  # from the local file URL that submodule add wrote to .git/config.
  git config -f "$dir/.gitmodules" submodule..claude/vendor/kit.url https://github.com/bitsy-services/claude-kit
  # R16: what kit init sets in a real consumer clone.
  git -C "$dir" config push.recurseSubmodules check
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "consumer fixture"
  CON="$dir"
}

kit_run() {
  OUT="$(cd "$CON" && CLAUDE_PROJECT_DIR="$CON" bash "$CON/.claude/vendor/kit/bin/kit" "$@" 2>&1)" && RC=0 || RC=$?
}

_t_report() {
  T_N=$((T_N + 1))
  if [ "$1" = 0 ]; then
    echo "ok $T_N - $2"
  else
    echo "not ok $T_N - $2"
    T_FAIL=$((T_FAIL + 1))
  fi
}

is() {
  local ok=1
  [ "$1" = "$2" ] && ok=0
  _t_report "$ok" "$3"
  if [ "$ok" != 0 ]; then
    echo "#   got:  $1"
    echo "#   want: $2"
  fi
}

like() {
  local ok=1
  printf '%s\n' "$1" | grep -Eq -- "$2" && ok=0
  _t_report "$ok" "$3"
  if [ "$ok" != 0 ]; then echo "#   text: $1"; echo "#   wanted /$2/"; fi
}

unlike() {
  local ok=0
  printf '%s\n' "$1" | grep -Eq -- "$2" && ok=1
  _t_report "$ok" "$3"
  if [ "$ok" != 0 ]; then echo "#   text: $1"; echo "#   unwanted /$2/"; fi
}

has_file() {
  local ok=1
  [ -e "$1" ] && ok=0
  _t_report "$ok" "has file $1"
}

no_file() {
  local ok=0
  [ -e "$1" ] && ok=1
  _t_report "$ok" "no file $1"
}

done_testing() {
  echo "1..$T_N"
  if [ "$T_FAIL" != 0 ]; then
    echo "# $T_FAIL failed"
    exit 1
  fi
  exit 0
}
