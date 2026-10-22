# kit check: render the pin again into a scratch dir and compare it with the
# consumer. Sourced after lib/common.sh, lib/config.sh and lib/render.sh;
# uses only bash, git and jq. It never writes into the consumer.
#
# Each row is a check_<row> function. A row reports a problem with
# check_problem, which prints it at once and counts it, and a notice with
# check_notice, which holds it until every row has run. Rows run in table
# order, so problems print in row order, then the notices, then the summary.
# The objects row (NOT PRESENT) is bin/kit's: it runs before any command.

CHECK_PROBLEMS=0
CHECK_NOTICES=()

check_problem() {
  say "$1"
  CHECK_PROBLEMS=$((CHECK_PROBLEMS + 1))
}

check_notice() { CHECK_NOTICES+=("$1"); }

# A line that is the stamp, in .md form or after the shell comment marker.
_CHECK_STAMP_RE='^(# )?<!-- kit: rendered from slices/.+ — edit the source in the kit, never this copy -->'$'\r''?$'

# _check_stamped <file>: the file carries the kit stamp.
_check_stamped() {
  [ -f "$1" ] && LC_ALL=C grep -Eq -- "$_CHECK_STAMP_RE" "$1"
}

# dirty: the vendored checkout has no local edits. --no-optional-locks keeps
# git status from refreshing the submodule's index.
check_dirty() {
  local st
  st="$(git --no-optional-locks -C "$VENDOR" status --porcelain)" \
    || die "internal error: cannot read the state of .claude/vendor/kit"
  if [ -n "$st" ]; then
    check_problem "DIRTY .claude/vendor/kit has local edits; kit source is edited in the kit's own clone"
  fi
}

# off-pin: a checkout at another commit is only a notice; kit runs the pin.
check_off_pin() {
  local head
  head="$(git -C "$VENDOR" rev-parse -q --verify HEAD)" || head=""
  if [ -n "$head" ] && [ "$head" != "$CHECK_PIN" ]; then
    check_notice ".claude/vendor/kit is checked out at ${head:0:7}, pinned at $CHECK_PIN7 (run: git submodule update .claude/vendor/kit)"
  fi
}

# config: render the pin afresh into $CHECK_TMP/exp. Every CONFIG or RENDER
# line is a problem; when there is any, CHECK_EXP stays empty and the rows
# that need the fresh render are skipped.
check_config() {
  local rc=0 n=0 line
  mkdir -p -- "$CHECK_TMP/exp" || die "internal error: cannot write the scratch directory"
  render_expected "$CHECK_TMP/exp" > "$CHECK_TMP/render.out" || rc=$?
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      check_problem "$line"
      n=$((n + 1))
    fi
  done < "$CHECK_TMP/render.out"
  case "$rc" in
    0) CHECK_EXP="$CHECK_TMP/exp" ;;
    1) [ "$n" != 0 ] || die "internal error: the kit at $CHECK_PIN7 did not render and gave no reason" ;;
    *) die "internal error: cannot render the kit at $CHECK_PIN7" ;;
  esac
}

# missing: every rendered dest is present.
check_missing() {
  local d
  while IFS= read -r d; do
    if [ ! -e "$CON/$d" ]; then
      check_problem "WORKTREE $d is missing: run kit render"
    fi
  done < <(jq -r '.files | keys[]' "$CHECK_EXP/lock.json")
}

# drift: every present rendered dest has the fresh render's blob.
check_drift() {
  local d from want cur
  while IFS=$'\t' read -r d from want; do
    if [ ! -e "$CON/$d" ]; then continue; fi
    cur="$(blob_of "$CON/$d" 2> /dev/null)" || cur=""
    if [ "$cur" != "$want" ]; then
      check_problem "DRIFT $d differs from $from at $CHECK_PIN7: edited in place, or the pin moved without kit render"
    fi
  done < <(jq -r '.files | to_entries | sort_by(.key)[] | "\(.key)\t\(.value.from)\t\(.value.blob)"' "$CHECK_EXP/lock.json")
}

# orphan: every file under .claude/rules/kit/ and .claude/hooks/kit/, and
# every skill whose SKILL.md carries the stamp, is rendered or excluded.
check_orphan() {
  local d f
  local -A named=()
  while IFS= read -r d; do
    named["$d"]=1
  done < <(jq -r '(.files | keys[]), (.excluded | keys[])' "$CHECK_EXP/lock.json")
  while IFS= read -r -d '' f; do
    d="${f#"$CON"/}"
    if [ -z "${named[$d]+x}" ]; then
      check_problem "ORPHAN $d is not rendered by any enabled slice: delete it or run kit render"
    fi
  done < <(find "$CON/.claude/rules/kit" "$CON/.claude/hooks/kit" ! -type d -print0 2> /dev/null | LC_ALL=C sort -z)
  for f in "$CON"/.claude/skills/*/SKILL.md; do
    d="${f#"$CON"/}"
    if [ -z "${named[$d]+x}" ] && _check_stamped "$f"; then
      check_problem "ORPHAN $d is not rendered by any enabled slice: delete it or run kit render"
    fi
  done
}

# stamp: an excluded dest the consumer keeps must be its own file (R9).
check_stamp() {
  local d
  while IFS= read -r d; do
    if _check_stamped "$CON/$d"; then
      check_problem "STAMP $d is excluded but still carries the kit stamp: replace it with your own file"
    fi
  done < <(jq -r '.excluded | keys[]' "$CHECK_EXP/lock.json")
}

# excluded changed: the kit's source for an excluded dest has a new blob
# compared with the one the on-disk lock recorded. A notice, not a problem.
check_excluded_changed() {
  local d b
  local -A old=()
  if [ ! -f "$LOCK" ]; then return 0; fi
  while IFS=$'\t' read -r d b; do
    old["$d"]="$b"
  done < <(jq -r '(.excluded // {}) | to_entries[] | select(.value | type == "string")
                  | "\(.key)\t\(.value)"' "$LOCK" 2> /dev/null)
  while IFS=$'\t' read -r d b; do
    if [ -n "${old[$d]+x}" ] && [ "${old[$d]}" != "$b" ]; then
      check_notice "$d is excluded; the kit changed its source at $CHECK_PIN7"
    fi
  done < <(jq -r '.excluded | to_entries | sort_by(.key)[] | "\(.key)\t\(.value)"' "$CHECK_EXP/lock.json")
}

# lock: the on-disk lock equals the fresh render's, compared as jq -S.
check_lock() {
  jq -S . "$CHECK_EXP/lock.json" > "$CHECK_TMP/lock.fresh" || die "internal error: cannot read the fresh lock"
  if [ -f "$LOCK" ] && jq -S . "$LOCK" > "$CHECK_TMP/lock.disk" 2> /dev/null \
      && cmp -s -- "$CHECK_TMP/lock.disk" "$CHECK_TMP/lock.fresh"; then
    return 0
  fi
  check_problem "STALE LOCK .claude/kit.lock.json differs from a fresh render at $CHECK_PIN7: run kit render"
}

# cmd_check [--published]: run every row, then print the notices and the
# summary. Exit 0 when no row found a problem, 1 otherwise.
cmd_check() {
  local n
  CHECK_PUBLISHED=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --published) CHECK_PUBLISHED=1 ;;
      *) die "usage: kit check [--published]" ;;
    esac
    shift
  done
  ctx_consumer
  CHECK_PIN="$(pin_of)"
  [ -n "$CHECK_PIN" ] || die "not a kit consumer: check runs in a repo that vendors the kit at .claude/vendor/kit"
  CHECK_PIN7="${CHECK_PIN:0:7}"
  CHECK_PROBLEMS=0
  CHECK_NOTICES=()
  CHECK_EXP=""
  scratch_new CHECK_TMP || die "check: cannot make a scratch directory"

  check_dirty
  check_off_pin
  check_config
  if [ -n "$CHECK_EXP" ]; then
    check_missing
    check_drift
    check_orphan
    check_stamp
    check_excluded_changed
    check_lock
  fi

  for n in "${CHECK_NOTICES[@]}"; do
    note "$n"
  done
  if [ "$CHECK_PROBLEMS" = 0 ]; then
    say "kit check: ok"
    return 0
  fi
  say "kit check: $CHECK_PROBLEMS problems"
  return 1
}
