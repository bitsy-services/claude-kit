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

# settings: permissions.allow, ask and deny hold only strings, and every kit
# entry the fresh render carries is in the consumer's settings, compared as
# flattened lists. The slice of an entry is the first enabled slice whose
# fragment holds it; hooks are reported without one. A list that is not an
# array never gets here: render refuses it, so the config row reports it.
check_settings() {
  local s cur="$CHECK_TMP/cur.json" names=() defs line
  defs="$(sed -n '/^def uniq/,/^def merge/{/^def merge/!p}' "$KIT_SELF/lib/settings.jq")"
  case "$defs" in *"def flatten"*) ;; *) die "internal error: cannot read flatten from lib/settings.jq" ;; esac
  if [ -f "$SETTINGS" ] && jq -e 'type == "object"' "$SETTINGS" > /dev/null 2>&1; then
    cp -- "$SETTINGS" "$cur" || die "internal error: cannot copy settings"
  else
    echo '{}' > "$cur"
  fi
  while IFS= read -r s; do
    if [ -f "$CHECK_EXP/tree/slices/$s/settings.json" ]; then names+=("$s"); fi
  done < <(jq -r '.slices[]' "$CHECK_EXP/config.json")
  while IFS= read -r line; do
    check_problem "$line"
  done < <(jq -nr --slurpfile lock "$CHECK_EXP/lock.json" --slurpfile cur "$cur" \
      --slurpfile fr "$CHECK_EXP/frags.jsonl" --argjson names "$(jq -nc '$ARGS.positional' --args "${names[@]}")" \
      "$defs"'
      ($cur[0] | flatten) as $cf
      | def owner($k; $x):
          first(range(0; $names | length) | select(any(($fr[.] | flatten)[$k][]; . == $x)) | $names[.]) // "?";
      ( ["allow", "ask", "deny"][] as $k
        | $cf[$k] | if type == "array" then .[] else empty end
        | select(type != "string")
        | "SETTINGS permissions.\($k) entry \(tojson) is not a string" ),
      ( ["allow", "ask", "deny"][] as $k
        | ($lock[0].settings.kit[$k] // [])[] | . as $x
        | select(any($cf[$k][]; . == $x) | not)
        | "SETTINGS missing \($k) \($x) (\(owner($k; $x)))" ),
      ( ($lock[0].settings.kit.hooks // [])[] | . as $h
        | select(any($cf.hooks[]; . == $h) | not)
        | "SETTINGS missing hook \(.[0]) \(.[1]) \(.[2].command // (.[2] | tojson))" )')
}

# forbid: no allow entry is a forbidden entry, the same rule spelled another
# way, or a broader rule. Both sides are normalised first, a trailing ":*)"
# read as " *)" and bare Bash as Bash(*). An allow entry covers a forbidden
# one when the two are equal, or when both are Bash(...) and the allow
# entry's text before its first * is a prefix of the forbidden entry's text.
# Entries of other tools compare exactly. One line per allow entry, naming
# the forbidden entry it is, else the first one it covers.
check_forbid() {
  local line
  while IFS= read -r line; do
    check_problem "$line"
  done < <(jq -r --slurpfile cur "$CHECK_TMP/cur.json" '
      def norm: if . == "Bash" then "Bash(*)"
                elif test("^Bash\\(.*:\\*\\)$") then .[:-3] + " *)"
                else . end;
      def inner: if startswith("Bash(") and endswith(")") then .[5:-1] else null end;
      def covers($f):
        norm as $a | ($f | norm) as $n
        | $a == $n
          or (($a | inner) as $ai | ($n | inner) as $ni
              | $ai != null and $ni != null and ($ai | contains("*"))
                and ($ni | startswith($ai | split("*")[0])));
      .forbid as $fb
      | $cur[0].permissions | if type == "object" then .allow else null end
      | if type == "array" then .[] | strings else empty end
      | . as $x
      | (first($fb[] | select(.entry == $x)) // first($fb[] | select(. as $f | $x | covers($f.entry))))
      | if $x == .entry then "FORBID \(.entry) in permissions.allow (\(.slice)): \(.reason)"
        else "FORBID \($x) in permissions.allow covers \(.entry) (\(.slice)): \(.reason)" end' \
      "$CHECK_EXP/config.json")
}

# breadth: no allow entry has a wildcard that starts an argument.
check_breadth() {
  local e
  while IFS= read -r e; do
    check_problem "BREADTH $e"
  done < <(jq -r '.permissions | if type == "object" then .allow else null end
                  | if type == "array" then .[] | strings else empty end' "$CHECK_TMP/cur.json" \
      | grep -E -- '\*[[:space:]]+[^*[:space:])]' || true)
}

# set: each key a slice sets has that value in the consumer's settings.
check_set() {
  local s line
  : > "$CHECK_TMP/owners.jsonl"
  while IFS= read -r s; do
    if [ -f "$CHECK_EXP/tree/slices/$s/slice.json" ]; then
      jq -c --arg s "$s" '{($s): (.set // {})}' "$CHECK_EXP/tree/slices/$s/slice.json" >> "$CHECK_TMP/owners.jsonl" \
        || die "internal error: cannot read slices/$s/slice.json"
    fi
  done < <(jq -r '.slices[]' "$CHECK_EXP/config.json")
  while IFS= read -r line; do
    check_problem "$line"
  done < <(jq -nr --slurpfile lock "$CHECK_EXP/lock.json" --slurpfile cur "$CHECK_TMP/cur.json" \
      --slurpfile so "$CHECK_TMP/owners.jsonl" \
      '$cur[0] as $c | $lock[0].set | to_entries[] | .key as $k | .value as $v
       | select(($c | has($k) | not) or $c[$k] != $v)
       | ([ $so[] | to_entries[] | select(.value | has($k)) | .key ] | last) as $s
       | "SET \($k) is \(if $c | has($k) then $c[$k] | tojson else "unset" end); \($s) sets \($v | tojson)"')
}

# memory: CLAUDE.md has a line that imports the memory index.
check_memory() {
  local root want line
  root="$(jq -r '.params.memory_root // empty' "$CHECK_EXP/config.json")"
  if [ -z "$root" ]; then return 0; fi
  want="@$root/MEMORY.md"
  if [ -f "$CON/CLAUDE.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//$'\r'/}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      if [ "$line" = "$want" ]; then return 0; fi
    done < "$CON/CLAUDE.md"
  fi
  check_problem "MEMORY CLAUDE.md does not import $want"
}

# _check_heading <heading>: print absent, empty or ok for "## <heading>" in
# repo.md. The body runs to the next heading of level 1 or 2.
_check_heading() {
  local line st=absent
  if [ ! -f "$REPO_MD" ]; then echo absent; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    if [ "$st" = absent ]; then
      line="${line%"${line##*[![:space:]]}"}"
      if [ "$line" = "## $1" ]; then st=empty; fi
    elif [[ $line =~ ^#{1,2}[[:space:]] ]]; then
      break
    elif [[ $line =~ [^[:space:]] ]]; then
      st=ok
      break
    fi
  done < "$REPO_MD"
  echo "$st"
}

# repo.md: every heading an enabled slice declares is present and not empty.
check_repo() {
  local s h st
  while IFS=$'\t' read -r s h; do
    st="$(_check_heading "$h")"
    case "$st" in
      absent) check_problem "REPO repo.md lacks ## $h ($s)" ;;
      empty) check_problem "REPO repo.md ## $h is empty ($s)" ;;
    esac
  done < <(jq -r '.headings | to_entries[] | .key as $s | .value[] | "\($s)\t\(.)"' "$CHECK_EXP/config.json")
}

# md_links <file>: print each relative link target in a Markdown file, one
# per line, without its #fragment. Fenced blocks, inline code spans, scheme:
# URLs and anchor-only links are skipped. The kit's links lint uses it too.
md_links() {
  local line fence=0 t
  local fence_re='^[[:space:]]*(```|~~~)' span_re='^([^`]*)`[^`]*`(.*)$' link_re='\]\(([^)]*)\)(.*)$'
  local scheme_re='^[A-Za-z][A-Za-z0-9+.-]*:'
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    if [[ $line =~ $fence_re ]]; then fence=$((1 - fence)); continue; fi
    if [ "$fence" = 1 ]; then continue; fi
    while [[ $line =~ $span_re ]]; do line="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; done
    while [[ $line =~ $link_re ]]; do
      t="${BASH_REMATCH[1]}"
      line="${BASH_REMATCH[2]}"
      t="${t#"${t%%[![:space:]]*}"}"
      t="${t%%[[:space:]]*}"
      t="${t#<}"
      t="${t%>}"
      if [ -z "$t" ] || [[ $t == '#'* ]] || [[ $t =~ $scheme_re ]]; then continue; fi
      t="${t%%#*}"
      if [ -n "$t" ]; then printf '%s\n' "$t"; fi
    done
  done < "$1"
}

# _check_links_in <file> <rel>: LINK for each relative link whose target does
# not exist. A target with a leading / is skipped, as a scheme: URL is: in a
# site repo it is a URL path on the site, not a path in the repo.
_check_links_in() {
  local f="$1" rel="$2" t base
  base="${f%/*}"
  while IFS= read -r t; do
    if [[ $t == /* ]] || [ -e "$base/${t//%20/ }" ]; then continue; fi
    check_problem "LINK $rel -> $t"
  done < <(md_links "$f")
}

# links: relative links in CLAUDE.md and .claude/**/*.md (not the vendored
# kit) point at something that exists.
check_links() {
  local f
  if [ -f "$CON/CLAUDE.md" ]; then _check_links_in "$CON/CLAUDE.md" "CLAUDE.md"; fi
  while IFS= read -r -d '' f; do
    _check_links_in "$f" "${f#"$CON"/}"
  done < <(find "$CON/.claude" -path "$CON/.claude/vendor" -prune -o -type f -name '*.md' -print0 2> /dev/null \
      | LC_ALL=C sort -z)
}

# dangling: no broken symlink under .claude (not the vendored kit).
check_dangling() {
  local f
  while IFS= read -r -d '' f; do
    check_problem "DANGLING ${f#"$CON"/}"
  done < <(find "$CON/.claude" -path "$CON/.claude/vendor" -prune -o -xtype l -print0 2> /dev/null \
      | LC_ALL=C sort -z)
}

# eol: a rendered hook has no CRLF line endings.
check_eol() {
  local d
  while IFS= read -r d; do
    if [ -f "$CON/$d" ] && LC_ALL=C grep -q $'\r' -- "$CON/$d"; then
      check_problem "EOL $d has CRLF line endings"
    fi
  done < <(jq -r '.files | keys[] | select(startswith(".claude/hooks/kit/"))' "$CHECK_EXP/lock.json")
}

# url: .gitmodules records the vendored kit over https.
check_url() {
  local key name url=""
  if [ -f "$CON/.gitmodules" ]; then
    key="$(git config -f "$CON/.gitmodules" --get-regexp '^submodule\..*\.path$' '^\.claude/vendor/kit$' | head -n 1 | cut -d' ' -f1)" || key=""
    if [ -n "$key" ]; then
      name="${key%.path}"
      url="$(git config -f "$CON/.gitmodules" --get "$name.url")" || url=""
    fi
  fi
  case "$url" in
    https://*) ;;
    *) check_problem "URL .gitmodules records .claude/vendor/kit as ${url:-(nothing)}; use https://" ;;
  esac
}

# clone: push.recurseSubmodules is "check" (kit init sets it).
check_clone() {
  local v
  v="$(git -C "$CON" config --get push.recurseSubmodules)" || v=""
  if [ "$v" != check ]; then
    if [ "$CHECK_PUBLISHED" = 1 ]; then
      check_problem "CLONE push.recurseSubmodules is not \"check\": run kit init"
    else
      check_notice "push.recurseSubmodules is not \"check\": run kit init"
    fi
  fi
}

# published (--published only): the pin is on the kit's origin/main.
check_published() {
  if [ "$CHECK_PUBLISHED" != 1 ]; then return 0; fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$VENDOR" fetch -q origin main > /dev/null 2>&1; then
    check_problem "UNPUBLISHED cannot reach the kit's origin to verify $CHECK_PIN7"
  elif ! git -C "$VENDOR" merge-base --is-ancestor "$CHECK_PIN" refs/remotes/origin/main 2> /dev/null; then
    check_problem "UNPUBLISHED $CHECK_PIN7 is not on the kit's origin/main"
  fi
}

# cmd_check [--published]: run every row, then print the notices and the
# summary. Exit 0 when no row found a problem, 1 otherwise.
cmd_check() {
  local n
  if ! command -v jq > /dev/null 2>&1; then
    say "NEED jq"
    say "kit check: 1 problems"
    return 1
  fi
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
    check_settings
    check_forbid
    check_breadth
    check_set
    check_memory
    check_repo
  fi
  check_links
  check_dangling
  if [ -n "$CHECK_EXP" ]; then check_eol; fi
  check_url
  check_clone
  check_published

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
