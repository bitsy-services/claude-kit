# Kit-repo commands. selftest runs the lints over the kit's working tree, then
# the test suite; publish lands a topic branch on the kit's main and pushes it.
# Sourced by bin/kit; uses bash, git, jq and POSIX tools (R14).
#
# Each lint is a _lint_<name> function that reports one line per problem
# with _lint: LINT <name> <file>: <detail>. The lints read the kit's files:
# tracked ones and untracked ones git does not ignore. A pattern below that
# names text the kit must not contain is spelled so that it does not match
# its own line, since lib/ is scanned too.

SELFTEST_LINTS=0
KD_ROOT=""
KD_FILES=()
KD_SLICES=()
KD_FM=()
KD_FM_END=0
KD_DEST=""
KD_NORM=""
KD_V=""
declare -gA KD_REQ=() KD_PARAMS=() KD_BAD=() KD_DESTS=() KD_CLOSURE=()

KD_BUDGET=150
_KD_VOICE_RE='this kit|downstream|every consumer|consumer repos|our consumers'
_KD_PUBLIC_RE='/hom[e]/|gi[t]@|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# rm with a recursive option anywhere among its options (T13.1).
_KD_RMR_RE='(^|[^A-Za-z0-9_.-])rm([[:space:]]+(-[a-zA-Z]+|--[a-z][a-z-]*))*[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'
# find's delete action, also inside $(...) or before ; (T13.1).
_KD_DELETE_RE='(^|[[:space:]])-delete([^A-Za-z0-9_-]|$)'
_KD_PARAM_RE='\{\{kit\.[A-Za-z0-9_]+\}\}'

# A settings fragment holds permissions.allow/ask/deny and hooks, nothing else.
_KD_FRAGMENT_JQ='
(keys_unsorted[] | select(IN("permissions", "hooks") | not) | "top-level key \(tojson)"),
(if has("permissions") then
   (.permissions | if type == "object"
                   then keys_unsorted[] | select(IN("allow", "ask", "deny") | not) | "permissions key \(tojson)"
                   else "permissions is not an object" end)
 else empty end)'

# Every param has a pattern, and the pattern rejects each character that is
# unsafe in .sh and .json: double and single quote, $, backtick, ;, &, | and
# newline (probed mid-value). The characters are built from their code points
# so that this single-quoted program holds no quote or backtick.
_KD_PATTERN_JQ='
([39] | implode) as $apos
| (.params // {}) | if type == "object" then to_entries[] else empty end
| .key as $k
| (.value | if type == "object" then .pattern else null end) as $p
| if ($p | type) != "string" then "\($k) has no pattern"
  elif (try ("" | test($p) | false) catch true) then "\($k)\($apos)s pattern is not a valid regex"
  else [ (34, 39, 36, 96, 59, 38, 124, 10) | [.] | implode as $c
         | select(("a" + $c + "a") | test($p)) | $c | tojson ]
       | if length > 0 then "\($k)\($apos)s pattern accepts \(join(" "))" else empty end
  end'

# _lint <name> <file> <detail>: print one LINT line and count it.
_lint() {
  printf 'LINT %s %s: %s\n' "$1" "$2" "$3"
  SELFTEST_LINTS=$((SELFTEST_LINTS + 1))
}

# _kd_list: KD_FILES, the kit's files relative to KD_ROOT, sorted. In a git
# work tree whose top is KD_ROOT: tracked files and untracked ones git does
# not ignore. Elsewhere: every file under KD_ROOT.
_kd_list() {
  local top f
  KD_FILES=()
  top="$(git -C "$KD_ROOT" rev-parse --show-toplevel 2> /dev/null)" || top=""
  if [ -n "$top" ] && [ "$top" -ef "$KD_ROOT" ]; then
    while IFS= read -r -d '' f; do
      if [ -f "$KD_ROOT/$f" ]; then KD_FILES+=("$f"); fi
    done < <(git -C "$KD_ROOT" ls-files -z -co --exclude-standard | LC_ALL=C sort -z)
  else
    while IFS= read -r -d '' f; do
      KD_FILES+=("${f#./}")
    done < <(cd -- "$KD_ROOT" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z)
  fi
}

# _kd_dest <path in a slice>: KD_DEST, where the file renders, as config.sh
# maps it. Returns 1 for a file that does not render.
_kd_dest() {
  KD_DEST=""
  case "$1" in
    rules/*/* | hooks/*/* | skills/*/*/*) return 1 ;;
    rules/?*.md) KD_DEST=".claude/rules/kit/${1#rules/}" ;;
    skills/?*/SKILL.md) KD_DEST=".claude/skills/${1#skills/}" ;;
    hooks/?*.sh) KD_DEST=".claude/hooks/kit/${1#hooks/}" ;;
    *) return 1 ;;
  esac
}

# _kd_close <slice>: KD_CLOSURE[<slice>], the slice and every slice it
# requires, transitively, space-separated.
_kd_close() {
  local -a todo=("$1") reqs=()
  local -A seen=()
  local s out=""
  while [ "${#todo[@]}" -gt 0 ]; do
    s="${todo[0]}"
    todo=("${todo[@]:1}")
    if [ -n "${seen[$s]+x}" ]; then continue; fi
    seen[$s]=1
    out+="$s "
    read -ra reqs <<< "${KD_REQ[$s]:-}"
    todo+=("${reqs[@]}")
  done
  KD_CLOSURE[$1]="$out"
}

# _kd_load: for each slice dir, KD_REQ (requires), KD_PARAMS (declared
# params), KD_DESTS (rendered dests, one per line) and KD_CLOSURE. A
# slice.json that is not a JSON object marks the slice in KD_BAD; the json
# lint reports it.
_kd_load() {
  local d s f rest
  KD_SLICES=()
  KD_REQ=()
  KD_PARAMS=()
  KD_BAD=()
  KD_DESTS=()
  KD_CLOSURE=()
  for d in "$KD_ROOT"/slices/*/; do
    [ -d "$d" ] || continue
    s="${d%/}"
    s="${s##*/}"
    KD_SLICES+=("$s")
    KD_REQ[$s]=""
    KD_PARAMS[$s]=""
    KD_DESTS[$s]=""
    f="$KD_ROOT/slices/$s/slice.json"
    if [ ! -e "$f" ]; then continue; fi
    if ! jq -e 'type == "object"' "$f" > /dev/null 2>&1; then
      KD_BAD[$s]=1
      continue
    fi
    KD_REQ[$s]="$(jq -r '(.requires // []) | if type == "array" then .[] | strings else empty end' "$f" | tr '\n' ' ')" || true
    KD_PARAMS[$s]="$(jq -r '(.params // {}) | if type == "object" then keys[] else empty end' "$f" | tr '\n' ' ')" || true
  done
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*) ;; *) continue ;; esac
    rest="${f#slices/}"
    s="${rest%%/*}"
    if _kd_dest "${rest#*/}"; then KD_DESTS[$s]+="$KD_DEST"$'\n'; fi
  done
  for s in "${KD_SLICES[@]}"; do _kd_close "$s"; done
}

# _kd_grep <grep flags> <ere> <files...>: grep the files from KD_ROOT and
# print <file>:<line>:<match> for each match. Prints nothing without files.
_kd_grep() {
  local flags="$1" re="$2"
  shift 2
  if [ $# = 0 ]; then return 0; fi
  (cd -- "$KD_ROOT" && LC_ALL=C grep -HnoI"$flags" -e "$re" -- "$@") || true
}

# _kd_unquote <text>: KD_V, the text trimmed of surrounding blanks and of one
# pair of surrounding quotes.
_kd_unquote() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\" | \'*\') v="${v:1:${#v}-2}" ;;
  esac
  KD_V="$v"
}

# _kd_fm <file>: KD_FM, the frontmatter lines (without CR), and KD_FM_END,
# the line number of the closing ---. KD_FM_END is 0 when line 1 is not ---,
# and -1 when no --- closes the frontmatter by line 30. KD_FM[i] is line i+2.
_kd_fm() {
  local line n=0
  KD_FM=()
  KD_FM_END=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [ "$n" = 1 ]; then
      if [ "$line" != "---" ]; then return 0; fi
      KD_FM_END=-1
      continue
    fi
    if [ "$line" = "---" ]; then
      KD_FM_END="$n"
      return 0
    fi
    if [ "$n" -ge 30 ]; then return 0; fi
    KD_FM+=("$line")
  done < "$1"
}

# _kd_norm <path>: KD_NORM, the path without ., .. or empty segments.
# Returns 1 when .. climbs above the root.
_kd_norm() {
  local rest="$1" seg out=""
  KD_NORM=""
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      '' | .) ;;
      ..)
        if [ -z "$out" ]; then return 1; fi
        out="${out%/*}"
        ;;
      *) out="$out/$seg" ;;
    esac
  done
  KD_NORM="${out#/}"
}

# syntax: bash -n passes on every .sh and on bin/kit.
_lint_syntax() {
  local f msg
  for f in "${KD_FILES[@]}"; do
    case "$f" in *.sh | bin/kit) ;; *) continue ;; esac
    if msg="$(cd -- "$KD_ROOT" && LC_ALL=C bash -n -- "$f" 2>&1)"; then continue; fi
    msg="${msg%%$'\n'*}"
    _lint syntax "$f" "${msg#"$f: "}"
  done
}

# json: each slice.json and settings.json is a JSON object.
_lint_json() {
  local f
  for f in "${KD_FILES[@]}"; do
    case "$f" in
      slices/*/*/*) continue ;;
      slices/*/slice.json | slices/*/settings.json) ;;
      *) continue ;;
    esac
    if ! jq empty "$KD_ROOT/$f" > /dev/null 2>&1; then
      _lint json "$f" "not valid JSON"
    elif ! jq -e 'type == "object"' "$KD_ROOT/$f" > /dev/null 2>&1; then
      _lint json "$f" "not a JSON object"
    fi
  done
}

# voice: slice text is written to the repo that renders it, never about the
# kit and the repos that use it.
_lint_voice() {
  local f n m
  local -a files=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*) files+=("$f") ;; esac
  done
  while IFS=: read -r f n m; do
    _lint voice "$f" "line $n: $m"
  done < <(_kd_grep iE "$_KD_VOICE_RE" "${files[@]}")
}

# public (R19): no home path, email or ssh remote in any file but LICENSE
# and test/.
_lint_public() {
  local f n m
  local -a files=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in LICENSE | test/*) ;; *) files+=("$f") ;; esac
  done
  while IFS=: read -r f n m; do
    _lint public "$f" "line $n: $m"
  done < <(_kd_grep E "$_KD_PUBLIC_RE" "${files[@]}")
}

# _kd_path_item <file> <line> <item>: a paths entry that matches every file.
_kd_path_item() {
  local all_re='^[*/]+$'
  _kd_unquote "$3"
  if [[ $KD_V =~ $all_re ]]; then
    _lint frontmatter "$1" "line $2: paths \"$KD_V\" matches every file; an always-on rule has no paths"
  fi
}

# _kd_paths <file> <line> <value>: a paths value on the key's own line, as a
# flow list or a scalar.
_kd_paths() {
  local v="$3" item
  local -a items=()
  case "$v" in
    \[*\])
      v="${v#\[}"
      v="${v%\]}"
      IFS=, read -ra items <<< "$v"
      for item in "${items[@]}"; do _kd_path_item "$1" "$2" "$item"; done
      ;;
    *) _kd_path_item "$1" "$2" "$v" ;;
  esac
}

# frontmatter: in every slice .md, the frontmatter closes by line 30, holds
# only key lines, list items and blanks, has no globs: and no paths entry
# that matches every file.
_lint_frontmatter() {
  local f i n line key val inpaths
  local key_re='^([A-Za-z_][A-Za-z0-9_-]*):([[:space:]].*)?$' item_re='^[[:space:]]*-([[:space:]].*)?$'
  local blank_re='^[[:space:]]*$'
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*.md) ;; *) continue ;; esac
    _kd_fm "$KD_ROOT/$f"
    case "$KD_FM_END" in
      0) continue ;;
      -1)
        _lint frontmatter "$f" "frontmatter is not closed within 30 lines"
        continue
        ;;
    esac
    inpaths=0
    for i in "${!KD_FM[@]}"; do
      line="${KD_FM[$i]}"
      n=$((i + 2))
      if [[ $line =~ $key_re ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        inpaths=0
        case "$key" in
          globs) _lint frontmatter "$f" "line $n: globs: is forbidden; use paths" ;;
          paths) if [ -z "$val" ]; then inpaths=1; else _kd_paths "$f" "$n" "$val"; fi ;;
        esac
      elif [[ $line =~ $item_re ]]; then
        if [ "$inpaths" = 1 ]; then _kd_path_item "$f" "$n" "${BASH_REMATCH[1]}"; fi
      elif [[ $line =~ $blank_re ]]; then
        :
      else
        _lint frontmatter "$f" "line $n: not \"key: value\", a list item or blank"
      fi
    done
  done
}

# skill-frontmatter: a rendered skill's name is its directory, and it has a
# description.
_lint_skill_frontmatter() {
  local f rest dir line name desc
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*) ;; *) continue ;; esac
    rest="${f#slices/*/}"
    _kd_dest "$rest" || continue
    case "$KD_DEST" in .claude/skills/*) ;; *) continue ;; esac
    dir="${rest#skills/}"
    dir="${dir%/SKILL.md}"
    _kd_fm "$KD_ROOT/$f"
    case "$KD_FM_END" in
      0)
        _lint skill-frontmatter "$f" "no frontmatter; a skill needs name and description"
        continue
        ;;
      -1) continue ;;
    esac
    name=""
    desc=""
    for line in "${KD_FM[@]}"; do
      case "$line" in
        name:*) _kd_unquote "${line#name:}"; name="$KD_V" ;;
        description:*) _kd_unquote "${line#description:}"; desc="$KD_V" ;;
      esac
    done
    if [ -z "$name" ]; then
      _lint skill-frontmatter "$f" "name is missing"
    elif [ "$name" != "$dir" ]; then
      _lint skill-frontmatter "$f" "name is \"$name\", not the directory name \"$dir\""
    fi
    if [ -z "$desc" ]; then _lint skill-frontmatter "$f" "description is missing"; fi
  done
}

# links: each link in a rendered slice .md, resolved from the file's dest,
# targets a dest its slice or a slice it requires renders, or repo.md.
_lint_links() {
  local f s rest dest t p c allowed
  local -a cl=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*.md) ;; *) continue ;; esac
    rest="${f#slices/}"
    s="${rest%%/*}"
    _kd_dest "${rest#*/}" || continue
    dest="$KD_DEST"
    allowed=$'\n.claude/rules/repo.md\n'
    read -ra cl <<< "${KD_CLOSURE[$s]:-}"
    for c in "${cl[@]}"; do allowed+="${KD_DESTS[$c]:-}"; done
    while IFS= read -r t; do
      p="${t//%20/ }"
      case "$p" in
        /*) p="${p#/}" ;;
        *) p="${dest%/*}/$p" ;;
      esac
      if _kd_norm "$p" && [[ $allowed == *$'\n'"$KD_NORM"$'\n'* ]]; then continue; fi
      _lint links "$f" "$t resolves to ${KD_NORM:-a path outside the repo}, which neither $s nor a slice it requires renders"
    done < <(md_links "$KD_ROOT/$f")
  done
}

# fragment-keys: a slice's settings.json holds only permissions and hooks,
# and permissions only allow, ask and deny.
_lint_fragment_keys() {
  local f line
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*/*) continue ;; slices/*/settings.json) ;; *) continue ;; esac
    jq -e 'type == "object"' "$KD_ROOT/$f" > /dev/null 2>&1 || continue
    while IFS= read -r line; do
      _lint fragment-keys "$f" "$line"
    done < <(jq -r "$_KD_FRAGMENT_JQ" "$KD_ROOT/$f" 2> /dev/null)
  done
}

# core-budget: core's always-on rules (no paths) render, stamp included, to
# at most KD_BUDGET lines.
_lint_core_budget() {
  local f line n scoped total=0
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/core/rules/*/*) continue ;; slices/core/rules/*.md) ;; *) continue ;; esac
    _kd_fm "$KD_ROOT/$f"
    scoped=0
    if [ "$KD_FM_END" -gt 0 ]; then
      for line in "${KD_FM[@]}"; do
        case "$line" in paths:*) scoped=1 ;; esac
      done
    fi
    if [ "$scoped" = 1 ]; then continue; fi
    n="$(wc -l < "$KD_ROOT/$f")"
    if [ -n "$(tail -c 1 "$KD_ROOT/$f")" ]; then n=$((n + 1)); fi
    total=$((total + n + 1))
  done
  if [ "$total" -gt "$KD_BUDGET" ]; then
    _lint core-budget slices/core/rules "always-on rules render to $total lines, over the budget of $KD_BUDGET"
  fi
}

# undeclared-param: each {{kit.<name>}} in a slice's files is declared by
# the slice or a slice it requires. A slice whose closure holds a bad
# slice.json is skipped; the json lint has reported it.
_lint_undeclared_param() {
  local f m s rest c bad declared name
  local -a files=() cl=()
  local -A seen=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*) files+=("$f") ;; esac
  done
  while IFS=: read -r f _ m; do
    if [ -n "${seen[$f:$m]+x}" ]; then continue; fi
    seen[$f:$m]=1
    rest="${f#slices/}"
    s="${rest%%/*}"
    bad=0
    declared=" "
    read -ra cl <<< "${KD_CLOSURE[$s]:-}"
    for c in "${cl[@]}"; do
      if [ -n "${KD_BAD[$c]+x}" ]; then bad=1; fi
      declared+="${KD_PARAMS[$c]:-} "
    done
    if [ "$bad" = 1 ]; then continue; fi
    name="${m#\{\{kit.}"
    name="${name%\}\}}"
    case "$declared" in *" $name "*) continue ;; esac
    _lint undeclared-param "$f" "$m is declared by neither $s nor a slice it requires"
  done < <(_kd_grep E "$_KD_PARAM_RE" "${files[@]}")
}

# param-pattern: every param a slice declares has a safe pattern.
_lint_param_pattern() {
  local f line
  for f in "${KD_FILES[@]}"; do
    case "$f" in slices/*/*/*) continue ;; slices/*/slice.json) ;; *) continue ;; esac
    jq -e 'type == "object"' "$KD_ROOT/$f" > /dev/null 2>&1 || continue
    while IFS= read -r line; do
      _lint param-pattern "$f" "$line"
    done < <(jq -r "$_KD_PATTERN_JQ" "$KD_ROOT/$f" 2> /dev/null)
  done
}

# gitmodules: the kit has no submodules (consumers clone it as one).
_lint_gitmodules() {
  if [ -e "$KD_ROOT/.gitmodules" ]; then
    _lint gitmodules .gitmodules "the kit has no submodules"
  fi
}

# rm-r (R10): no recursive rm in bin/ or lib/, and find's delete action only
# in lib/common.sh, where scratch_cleanup is.
_lint_rm_r() {
  local f n m
  local -a files=() others=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in
      bin/* | lib/*)
        files+=("$f")
        if [ "$f" != lib/common.sh ]; then others+=("$f"); fi
        ;;
    esac
  done
  while IFS=: read -r f n m; do
    _lint rm-r "$f" "line $n: rm${m#*rm}"
  done < <(_kd_grep E "$_KD_RMR_RE" "${files[@]}")
  while IFS=: read -r f n m; do
    m="${m#"${m%%[![:space:]]*}"}"
    _lint rm-r "$f" "line $n: ${m:0:7}"
  done < <(_kd_grep E "$_KD_DELETE_RE" "${others[@]}")
}

# instruction-source (R33): nothing under test/ carries a name Claude Code
# loads as instructions when a session reads files in that subtree, which in
# a consumer would leak a fixture's rules and skills from the vendored kit.
# Fixture and consumer trees store .claude as dot-claude and CLAUDE.md as
# CLAUDE.md.in, and the tests map the names back. One line per .claude
# directory.
_lint_instruction_source() {
  local f d
  local -A seen=()
  for f in "${KD_FILES[@]}"; do
    case "$f" in test/*) ;; *) continue ;; esac
    case "/$f" in
      */.claude/*)
        d="/$f"
        d="${d%%/.claude/*}/.claude"
        d="${d#/}"
        if [ -z "${seen[$d]+x}" ]; then
          seen[$d]=1
          _lint instruction-source "$d" "a .claude directory under test/ can load into a session that reads files here; store it as dot-claude"
        fi
        ;;
    esac
    if [ "${f##*/}" = CLAUDE.md ]; then
      _lint instruction-source "$f" "a CLAUDE.md under test/ can load into a session that reads files here; store it as CLAUDE.md.in"
    fi
  done
}

# selftest_lints <kit_root> (R4): run every lint over the kit at <kit_root>.
# Prints the LINT lines, sets SELFTEST_LINTS to their count and returns it
# (capped at 255).
selftest_lints() {
  KD_ROOT="${1%/}"
  SELFTEST_LINTS=0
  _kd_list
  _kd_load
  _lint_syntax
  _lint_json
  _lint_voice
  _lint_public
  _lint_frontmatter
  _lint_skill_frontmatter
  _lint_links
  _lint_fragment_keys
  _lint_core_budget
  _lint_undeclared_param
  _lint_param_pattern
  _lint_gitmodules
  _lint_rm_r
  _lint_instruction_source
  if [ "$SELFTEST_LINTS" -gt 255 ]; then return 255; fi
  return "$SELFTEST_LINTS"
}

# cmd_selftest [--lints-only]: the lints (the syntax check among them), then
# the test suite when test/run.sh exists (R3). --lints-only stops after the
# lints (R35): the kit's Stop hook runs that, while kit publish and CI run
# the whole selftest. A failing suite counts as one problem. Exit 0 when
# there is no problem, 1 otherwise.
cmd_selftest() {
  local n lints_only=0
  if [ $# = 1 ] && [ "$1" = --lints-only ]; then
    lints_only=1
  elif [ $# -gt 0 ]; then
    die "usage: kit selftest [--lints-only]"
  fi
  if ! command -v jq > /dev/null 2>&1; then
    say "NEED jq"
    say "selftest: 1 problems"
    return 1
  fi
  selftest_lints "$KIT_SELF" || true
  n="$SELFTEST_LINTS"
  if [ "$lints_only" = 1 ]; then
    :
  elif [ -f "$KIT_SELF/test/run.sh" ]; then
    if ! (cd -- "$KIT_SELF" && bash test/run.sh); then
      say "TESTS test/run.sh failed"
      n=$((n + 1))
    fi
  else
    note "no test suite at test/run.sh"
  fi
  if [ "$n" = 0 ]; then
    say "selftest: ok"
    return 0
  fi
  say "selftest: $n problems"
  return 1
}

# cmd_publish: land the current topic branch on main and push main to
# origin. It runs on a clean topic branch, after a passing selftest, and a
# branch that changes slices/, bin/ or lib/ must also change CHANGELOG.md
# (M6: consumers run the CLI too). main moves only by fast-forward, and must
# then be the topic head, which the selftest ran on (T14.1); otherwise, or if
# the push fails, main goes back to where it was and the topic is checked out
# again, so a retry starts from the same state.
cmd_publish() {
  local topic old sha want
  if [ $# -gt 0 ]; then die "usage: kit publish"; fi
  topic="$(git -C "$KIT_SELF" symbolic-ref --short -q HEAD)" || topic=""
  if [ -z "$topic" ] || [ "$topic" = main ]; then die "publish: run it on the topic branch"; fi
  old="$(git -C "$KIT_SELF" rev-parse -q --verify refs/heads/main)" || die "publish: there is no local main branch"
  want="$(git -C "$KIT_SELF" rev-parse HEAD)" || die "publish: cannot read the head of $topic"
  if [ -n "$(git -C "$KIT_SELF" status --porcelain)" ]; then
    say "publish: the tree is dirty; commit the changes on $topic first"
    return 1
  fi
  if ! cmd_selftest; then
    say "publish: selftest failed"
    return 1
  fi
  if [ -n "$(git -C "$KIT_SELF" diff --name-only main...HEAD -- slices bin lib)" ] &&
    [ -z "$(git -C "$KIT_SELF" diff --name-only main...HEAD -- CHANGELOG.md)" ]; then
    say "publish: slices/, bin/ or lib/ changed without a CHANGELOG entry"
    return 1
  fi
  git -C "$KIT_SELF" switch -q main || die "publish: cannot switch to main"
  if ! git -C "$KIT_SELF" merge -q --ff-only "$topic"; then
    git -C "$KIT_SELF" switch -q "$topic" || die "publish: cannot switch back to $topic"
    say "publish: main cannot fast-forward to $topic; bring main into $topic first"
    return 1
  fi
  sha="$(git -C "$KIT_SELF" rev-parse HEAD)"
  if [ "$sha" != "$want" ]; then
    git -C "$KIT_SELF" switch -q "$topic" || die "publish: main is not at $topic's head, and cannot switch back to $topic"
    git -C "$KIT_SELF" update-ref refs/heads/main "$old" "$sha" || die "publish: main is not at $topic's head, and cannot restore main to ${old:0:7}"
    say "publish: main is at ${sha:0:7}, not at the head of $topic (${want:0:7}): main holds commits $topic lacks, which the selftest did not run on; bring main into $topic first"
    return 1
  fi
  if ! git -C "$KIT_SELF" push -q origin main; then
    git -C "$KIT_SELF" switch -q "$topic" || die "publish: the push failed, and cannot switch back to $topic"
    git -C "$KIT_SELF" update-ref refs/heads/main "$old" "$sha" || die "publish: the push failed, and cannot restore main to ${old:0:7}"
    say "publish: the push failed; main is back at ${old:0:7}"
    return 1
  fi
  say "published ${sha:0:7}"
}
