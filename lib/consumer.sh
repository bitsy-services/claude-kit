# Consumer commands: status, init, scaffold, apply, edit, bump.
# Sourced after lib/common.sh and lib/config.sh; uses only bash, git and jq.

# cmd_status: one offline line. Never renders, never touches the network.
cmd_status() {
  local pin lockpin d b cur ndiff=0 files lockst jqst co head
  ctx_consumer
  pin="$(pin_of)"
  if command -v jq > /dev/null 2>&1; then jqst=ok; else jqst=MISSING; fi
  files="?"
  lockst="?"
  if [ "$jqst" = ok ]; then
    if [ -f "$LOCK" ] && jq -e 'type == "object"' "$LOCK" > /dev/null 2>&1; then
      lockpin="$(jq -r '.pin // ""' "$LOCK")"
      if [ "$lockpin" = "$pin" ]; then lockst=ok; else lockst=stale; fi
      while IFS=$'\t' read -r d b; do
        if [ ! -e "$CON/$d" ]; then ndiff=$((ndiff + 1)); continue; fi
        cur="$(blob_of "$CON/$d")" || cur=""
        if [ "$cur" != "$b" ]; then ndiff=$((ndiff + 1)); fi
      done < <(jq -r '(.files // {}) | to_entries | sort_by(.key)[] | "\(.key)\t\(.value.blob)"' "$LOCK" 2> /dev/null)
    else
      lockst=stale
    fi
    if [ "$ndiff" = 0 ]; then files=ok; else files="$ndiff differ"; fi
  fi
  if [ ! -e "$VENDOR/.git" ] || ! git -C "$VENDOR" rev-parse --git-dir > /dev/null 2>&1; then
    co=absent
  elif [ -n "$(git -C "$VENDOR" status --porcelain 2> /dev/null)" ]; then
    co=dirty
  else
    head="$(git -C "$VENDOR" rev-parse HEAD 2> /dev/null)" || head=""
    if [ "$head" = "$pin" ]; then co=clean; else co=off-pin; fi
  fi
  say "kit ${pin:0:7} · files $files · lock $lockst · jq $jqst · checkout $co"
  return 0
}

# The slices of a new kit.json. Inputs: --slurpfile sl (one {name, decl} per
# slice directory) and --rawfile files (the repo's paths, NUL-separated, as
# git ls-files -z -co --exclude-standard lists them, a submodule as one
# path). Emits {chosen, skipped: [{name, why}], dirs: {slice: folder}}, in
# the order core, then by name. A slice with detect is chosen only when one
# of its paths appears, as whole path segments, in a listed path; its folder
# is what precedes the shallowest match ("" at the root). A slice that
# conflicts, either way, with one chosen before it is skipped, then each
# slice whose requires are not all chosen, until none is left.
_INIT_SLICES_JQ='
($files | split("\u0000") | map(select(. != ""))) as $fs
| ($sl | map({(.name): .decl}) | add // {}) as $d
| def arr: if type == "array" then [ .[] | strings ] else [] end;
  def folders($p): [ $fs[] | ("/" + . + "/") | split("/" + $p + "/") | select(length > 1)
                     | .[0] | ltrimstr("/") | if . == "" then "" else . + "/" end ];
  def clash($a; $b): (($d[$a].conflicts | arr) | index($b)) != null
                     or (($d[$b].conflicts | arr) | index($a)) != null;
  def missing: . as $st | [ $st.chosen[] as $s
                 | {name: $s, miss: (($d[$s].requires | arr) - $st.chosen)} | select(.miss | length > 0) ];
  ([ $sl[].name ] | sort) as $all
| reduce ([ $all[] | select(. == "core") ] + [ $all[] | select(. != "core") ])[] as $n
    ({chosen: [], skipped: [], dirs: {}};
    ($d[$n].detect | arr) as $det
    | ([ $det[] as $p | folders($p)[] ] | sort_by([(split("/") | length), .])) as $hits
    | if ($det | length) > 0 and ($hits | length) == 0 then
        .skipped += [{name: $n, why: "no \($det | join(" or ")) found"}]
      elif any(.chosen[]; clash($n; .)) then
        .skipped += [{name: $n, why: "conflicts with \([ .chosen[] | select(clash($n; .)) ] | first)"}]
      else
        .chosen += [$n] | if ($hits | length) > 0 then .dirs[$n] = $hits[0] else . end
      end)
| until((missing | length) == 0;
    missing as $m
    | .skipped += [ $m[] | {name, why: "requires \(.miss | join(" and "))"} ]
    | .chosen -= [ $m[].name ])
'

# The params of the chosen slices ($c) that name an init detector, first
# declaration winning as in config.sh: name, slice, detector, required (1
# or 0) and default, tab-separated. The default, which may be empty, comes
# last, since read joins adjacent tabs.
_INIT_PARAMS_JQ='
($sl | map({(.name): .decl}) | add // {}) as $d
| reduce ($c[] as $s | ($d[$s].params // {}) | if type == "object" then to_entries[] else empty end
          | {name: .key, slice: $s, v: (.value | if type == "object" then . else {} end)}) as $p
    ({}; if has($p.name) then . else .[$p.name] = $p end)
| .[] | select((.v.init | type) == "string")
| [.name, .slice, .v.init, (if .v.required == true then "1" else "0" end),
   (.v.default | if type == "string" then . else "" end)]
| @tsv'

# Each init detector sets INIT_VAL (empty when it found nothing), INIT_SRC
# (why that value) and INIT_NOTE (a notice for the owner, or empty).

# _init_check_command <param>: the command that checks this repo, else the
# kit's own check, with a notice to set a real one.
_init_check_command() {
  INIT_VAL="" INIT_SRC="" INIT_NOTE=""
  if [ -f "$CON/scripts/check.sh" ]; then
    INIT_VAL="bash scripts/check.sh"
    INIT_SRC="scripts/check.sh exists"
  elif jq -e '.scripts.check | strings' "$CON/package.json" > /dev/null 2>&1; then
    INIT_VAL="npm run check"
    INIT_SRC="package.json has a check script"
  elif jq -e '.scripts.test | strings | select(contains("no test specified") | not)' "$CON/package.json" > /dev/null 2>&1; then
    INIT_VAL="npm test"
    INIT_SRC="package.json has a test script"
  else
    INIT_VAL="$KIT_GATE_FALLBACK"
    INIT_SRC="no check command found"
    INIT_NOTE="no scripts/check.sh and no check or test script in package.json, so $1 is kit check, which checks only the kit's own files: set \"$1\" in .claude/kit.json to the command that checks this repo"
  fi
}

# _init_default_branch <param> <default>: the default when a local branch
# has its name, else the branch origin/HEAD names, else master, else the
# current branch.
_init_default_branch() {
  local head
  INIT_VAL="" INIT_SRC="" INIT_NOTE=""
  head="$(git -C "$CON" symbolic-ref -q --short refs/remotes/origin/HEAD 2> /dev/null)" || head=""
  head="${head#origin/}"
  if [ -n "$2" ] && git -C "$CON" rev-parse -q --verify "refs/heads/$2" > /dev/null; then
    INIT_VAL="$2"
    INIT_SRC="a local $2 branch exists"
  elif [ -n "$head" ]; then
    INIT_VAL="$head"
    INIT_SRC="origin/HEAD names it"
  elif git -C "$CON" rev-parse -q --verify refs/heads/master > /dev/null; then
    INIT_VAL=master
    INIT_SRC="a local master branch exists"
  else
    INIT_VAL="$(git -C "$CON" symbolic-ref -q --short HEAD 2> /dev/null)" || INIT_VAL=""
    INIT_SRC="it is the current branch"
    if [ -z "$INIT_VAL" ]; then
      INIT_NOTE="no local $2 or master branch, no origin/HEAD and no current branch, so $1 stays $2: set \"$1\" in .claude/kit.json to the branch that sessions land on"
    fi
  fi
  if [ -n "$head" ] && [ -n "$INIT_VAL" ] && [ "$head" != "$INIT_VAL" ]; then
    INIT_SRC+="; origin/HEAD names $head"
  fi
}

# _init_beside_detect <param> <folder> <default>: <folder><default>, the
# default inside the folder where the slice's detect path was found, when
# it holds a Markdown page other than an _index.md.
_init_beside_detect() {
  local dir="$2$3"
  INIT_VAL="" INIT_SRC="" INIT_NOTE=""
  if has_pages "$dir"; then
    INIT_VAL="$dir"
    INIT_SRC="it holds pages"
  else
    INIT_NOTE="$dir holds no pages besides _index.md: set \"$1\" in .claude/kit.json to the folder that holds them"
  fi
}

# _init_memory_import <param>: the folder of a MEMORY.md that CLAUDE.md
# already imports.
_init_memory_import() {
  local line d
  INIT_VAL="" INIT_SRC="" INIT_NOTE=""
  [ -f "$CON/CLAUDE.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in @?*/MEMORY.md) ;; *) continue ;; esac
    d="${line#@}"
    d="${d%/MEMORY.md}"
    if [ -f "$CON/$d/MEMORY.md" ]; then
      INIT_VAL="$d"
      INIT_SRC="CLAUDE.md imports $line"
      return 0
    fi
  done < "$CON/CLAUDE.md"
}

# init_kitjson <tree>: write .claude/kit.json from the slices in <tree> and
# say what was chosen and why; INIT_WROTE is 1 once it is written. A param
# is written when its detector found a value that matches the param's
# pattern and is required or not its default.
init_kitjson() {
  local tree="$1" work d name slice init def req chosen params='{}' folder
  INIT_WROTE=0
  if ! _inside_repo "$KITJSON"; then
    say "skipped .claude/kit.json: $KIT_PATH_WHY"
    return 0
  fi
  scratch_new work || die "init: cannot make a scratch directory"
  : > "$work/sl.jsonl"
  : > "$work/lines"
  : > "$work/notes"
  for d in "$tree"/slices/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"
    name="${name##*/}"
    case "$name" in '' | *[!A-Za-z0-9_-]*) continue ;; esac
    if ! jq -c --arg n "$name" '{name: $n, decl: (if type == "object" then . else {} end)}' "$d/slice.json" >> "$work/sl.jsonl" 2> /dev/null; then
      jq -nc --arg n "$name" '{name: $n, decl: {}}' >> "$work/sl.jsonl"
    fi
  done
  git -C "$CON" ls-files -z -co --exclude-standard > "$work/files" || die "init: cannot list the repo's files"
  jq -n --slurpfile sl "$work/sl.jsonl" --rawfile files "$work/files" "$_INIT_SLICES_JQ" > "$work/sel.json" \
    || die "internal error: init cannot choose the slices"
  chosen="$(jq -c '.chosen' "$work/sel.json")"
  while IFS=$'\t' read -r name slice init req def; do
    folder="$(jq -r --arg s "$slice" '.dirs[$s] // ""' "$work/sel.json")"
    case "$init" in
      check_command) _init_check_command "$name" ;;
      default_branch) _init_default_branch "$name" "$def" ;;
      beside_detect) _init_beside_detect "$name" "$folder" "$def" ;;
      memory_import) _init_memory_import "$name" ;;
      *) continue ;;
    esac
    if [ -n "$INIT_VAL" ]; then
      if ! jq -s -e --arg s "$slice" --arg k "$name" --arg v "$INIT_VAL" \
          '(map(select(.name == $s))[0].decl.params[$k].pattern) as $p | $p == null or ($v | test($p))' \
          "$work/sl.jsonl" > /dev/null 2>&1; then
        printf 'NOTICE %s is not set: %s (%s) does not match its pattern; set "%s" in .claude/kit.json\n' \
          "$name" "$INIT_VAL" "$INIT_SRC" "$name" >> "$work/notes"
      else
        printf '  %s: %s (%s)\n' "$name" "$INIT_VAL" "$INIT_SRC" >> "$work/lines"
        if [ "$req" = 1 ] || [ "$INIT_VAL" != "$def" ]; then
          params="$(jq -c --arg k "$name" --arg v "$INIT_VAL" '. + {($k): $v}' <<< "$params")"
        fi
      fi
    fi
    if [ -n "$INIT_NOTE" ]; then printf 'NOTICE %s\n' "$INIT_NOTE" >> "$work/notes"; fi
  done < <(jq -n -r --argjson c "$chosen" --slurpfile sl "$work/sl.jsonl" "$_INIT_PARAMS_JQ")
  mkdir -p -- "${KITJSON%/*}" || die "init: cannot create .claude"
  jq -n --argjson s "$chosen" --argjson p "$params" '{format: 1, slices: $s, params: $p, exclude: []}' > "$KITJSON" \
    || die "init: cannot write .claude/kit.json"
  INIT_WROTE=1
  say "created .claude/kit.json"
  say "  slices: $(jq -r '.chosen | join(", ")' "$work/sel.json")"
  jq -r '.skipped[] | "  skipped \(.name): \(.why)"' "$work/sel.json"
  cat -- "$work/lines" "$work/notes"
  config_resolve "$tree" "$work/config.json" || true
}

# cmd_init: fetch the pinned checkout, make pushes check submodules, and
# write .claude/kit.json when the repo has none.
cmd_init() {
  local pin tmp
  ctx_consumer
  git -C "$CON" submodule update --init .claude/vendor/kit || return 1
  git -C "$CON" config push.recurseSubmodules check || return 1
  if [ -e "$KITJSON" ]; then return 0; fi
  pin="$(pin_of)"
  scratch_new tmp || die "init: cannot make a scratch directory"
  extract "$pin" "$tmp/tree" slices || die "init: cannot read the kit at ${pin:0:7}"
  init_kitjson "$tmp/tree"
  if [ "$INIT_WROTE" = 1 ]; then
    say "next: change .claude/kit.json if you want, then run: bash .claude/vendor/kit/bin/kit apply"
  fi
}

# _inside_repo <path>: a write to the path stays in this repo: every
# symlink on the way, followed, leads into it, and none dangles. The path
# and its folders may be missing. Otherwise sets KIT_PATH_WHY and fails.
_inside_repo() {
  local p="$1" t r
  r="$(readlink -f -- "$CON")" || r="$CON"
  while [ -n "$p" ] && [ ! -e "$p" ]; do
    if [ -L "$p" ]; then
      KIT_PATH_WHY="it goes through a dangling symlink"
      return 1
    fi
    p="${p%/*}"
  done
  t="$(readlink -f -- "${p:-/}")" || t=""
  if [ "$t" = "$r" ] || [[ $t == "$r"/* ]]; then return 0; fi
  KIT_PATH_WHY="it leads outside this repo"
  return 1
}

# _scaffold_item <path> <content|-> <mode>: create the file only when
# absent; the verbose mode says when it is kept.
_scaffold_item() {
  local p="$1" body="$2" rel="${1#"$CON"/}"
  if [ -e "$p" ]; then
    if [ "$3" = verbose ]; then say "kept $rel"; fi
    return 0
  fi
  if ! _inside_repo "$p"; then
    say "skipped $rel: $KIT_PATH_WHY"
    return 0
  fi
  mkdir -p -- "${p%/*}" || die "scaffold: cannot create $rel"
  if [ "$body" = "-" ]; then
    : > "$p" || die "scaffold: cannot create $rel"
  else
    printf '%s' "$body" > "$p" || die "scaffold: cannot create $rel"
  fi
  say "created $rel"
}

# _scaffold_line <file> <line>: add the line at the end of the file unless
# one of its lines equals it (CR and surrounding blanks ignored, as
# check_memory reads it), creating the file when absent. A dangling symlink,
# or one that leads outside this repo, is left alone.
_scaffold_line() {
  local f="$1" want="$2" rel="${1#"$CON"/}" line
  if [ -L "$f" ] && [ ! -e "$f" ]; then
    say "skipped $rel: it is a dangling symlink; add the line $want to its target"
    return 0
  fi
  if [ -e "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//$'\r'/}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      if [ "$line" = "$want" ]; then return 0; fi
    done < "$f"
  fi
  if ! _inside_repo "$f"; then
    say "skipped $rel: $KIT_PATH_WHY; add the line $want to it yourself"
    return 0
  fi
  if [ ! -e "$f" ]; then
    printf '%s\n' "$want" > "$f" || die "scaffold: cannot create $rel"
    say "created $rel"
    return 0
  fi
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then
    printf '\n' >> "$f" || die "scaffold: cannot write $rel"
  fi
  printf '%s\n' "$want" >> "$f" || die "scaffold: cannot write $rel"
  say "added $want to $rel"
}

# _repo_md_append <heading> <body>: add "## <heading>" and its body at the
# end of repo.md, a blank line after the text already there.
_repo_md_append() {
  if [ -s "$REPO_MD" ]; then
    if [ -n "$(tail -c 1 "$REPO_MD")" ]; then
      printf '\n' >> "$REPO_MD" || die "scaffold: cannot write .claude/rules/repo.md"
    fi
    if [[ $(tail -n 1 "$REPO_MD") =~ [^[:space:]] ]]; then
      printf '\n' >> "$REPO_MD" || die "scaffold: cannot write .claude/rules/repo.md"
    fi
  fi
  if [ -n "$2" ]; then
    printf '## %s\n\n%s\n' "$1" "$2" >> "$REPO_MD" || die "scaffold: cannot write .claude/rules/repo.md"
  else
    printf '## %s\n' "$1" >> "$REPO_MD" || die "scaffold: cannot write .claude/rules/repo.md"
  fi
}

# _repo_md_fill <line> <body> <scratch file>: put the body under the empty
# heading on line <line> of repo.md, keeping every other line as it is.
_repo_md_fill() {
  local n="$1" i m
  local -a lines=()
  mapfile -t lines < "$REPO_MD"
  m=${#lines[@]}
  for ((i = n; i < ${#lines[@]}; i++)); do
    if [[ ${lines[$i]//$'\r'/} =~ ^#{1,2}[[:space:]] ]]; then
      m=$i
      break
    fi
  done
  {
    printf '%s\n' "${lines[@]:0:n}"
    printf '\n%s\n' "$2"
    if [ "$m" -lt "${#lines[@]}" ]; then
      printf '\n'
      printf '%s\n' "${lines[@]:m}"
    fi
  } > "$3" || die "scaffold: cannot write .claude/rules/repo.md"
  cat -- "$3" > "$REPO_MD" || die "scaffold: cannot write .claude/rules/repo.md"
}

# _scaffold_repo_md <tree> <tmp> <resolved> <mode>: create repo.md when
# absent. When the config resolved (<tmp>/config.json), each heading an
# enabled slice declares that is absent, or empty while the slice has
# default text for it, gets that text from slices/<slice>/repo.md in <tree>.
# repo.md is written only when something is missing.
_scaffold_repo_md() {
  local tree="$1" tmp="$2" ok="$3" mode="$4" s h st body made=0
  : > "$tmp/headings.tsv"
  if [ "$ok" = 1 ]; then
    while IFS=$'\t' read -r s h; do
      st="$(md_section "$REPO_MD" "$h")"
      case "$st" in
        ok*) continue ;;
        empty*) [ -n "$(md_section_body "$tree/slices/$s/repo.md" "$h")" ] || continue ;;
      esac
      printf '%s\t%s\n' "$s" "$h" >> "$tmp/headings.tsv"
    done < <(jq -r '.headings | to_entries[] | .key as $s | .value[] | "\($s)\t\(.)"' "$tmp/config.json")
  fi
  if [ -e "$REPO_MD" ] && [ ! -s "$tmp/headings.tsv" ]; then
    if [ "$mode" = verbose ]; then say "kept .claude/rules/repo.md"; fi
    return 0
  fi
  if ! _inside_repo "$REPO_MD"; then
    say "skipped .claude/rules/repo.md: $KIT_PATH_WHY"
    return 0
  fi
  if [ ! -e "$REPO_MD" ]; then
    mkdir -p -- "${REPO_MD%/*}" || die "scaffold: cannot create .claude/rules/repo.md"
    : > "$REPO_MD" || die "scaffold: cannot create .claude/rules/repo.md"
    made=1
  fi
  while IFS=$'\t' read -r s h; do
    st="$(md_section "$REPO_MD" "$h")"
    body="$(md_section_body "$tree/slices/$s/repo.md" "$h")"
    case "$st" in
      absent)
        _repo_md_append "$h" "$body"
        if [ "$made" = 0 ]; then say "added ## $h to .claude/rules/repo.md"; fi
        ;;
      empty*)
        _repo_md_fill "${st#empty }" "$body" "$tmp/repo.md"
        say "filled ## $h in .claude/rules/repo.md"
        ;;
    esac
  done < "$tmp/headings.tsv"
  if [ "$made" = 1 ]; then say "created .claude/rules/repo.md"; fi
}

# _scaffold <verbose|quiet>: create what is missing, never changing text
# already there: kit.json (as kit init writes it), the default text of each
# repo.md heading that is absent or empty, the memory index, the CLAUDE.md
# line that imports it and the .gitattributes line that keeps .claude/ in
# LF. The verbose mode also names each file it keeps.
_scaffold() {
  local mode="$1" pin tmp tree mroot=.claude/memory ok=0
  ctx_consumer
  pin="$(pin_of)"
  scratch_new tmp || die "scaffold: cannot make a scratch directory"
  tree="$tmp/tree"
  extract "$pin" "$tree" slices || die "scaffold: cannot read the kit at ${pin:0:7}"
  if [ -e "$KITJSON" ]; then
    if [ "$mode" = verbose ]; then say "kept .claude/kit.json"; fi
  else
    init_kitjson "$tree"
  fi
  if [ -f "$KITJSON" ] && config_resolve "$tree" "$tmp/config.json" > /dev/null 2>&1; then
    ok=1
    mroot="$(jq -r '.params.memory_root // ".claude/memory"' "$tmp/config.json")"
  fi
  _scaffold_repo_md "$tree" "$tmp" "$ok" "$mode"
  _scaffold_item "$CON/$mroot/MEMORY.md" "# Memory

" "$mode"
  _scaffold_item "$CON/$mroot/friction/.gitkeep" - "$mode"
  _scaffold_item "$CON/$mroot/patterns/.gitkeep" - "$mode"
  if [ "$ok" = 1 ]; then
    _scaffold_line "$CON/CLAUDE.md" "@$mroot/MEMORY.md"
  else
    say "skipped the repo.md sections and the CLAUDE.md import: .claude/kit.json has problems, which kit check names"
  fi
  _scaffold_line "$CON/.gitattributes" ".claude/** text=auto eol=lf"
}

# cmd_scaffold: create only what is missing, naming what is kept.
cmd_scaffold() { _scaffold verbose; }

# cmd_apply [--discard]: create what is missing, render, then check. Under
# bin/kit's set -e a failed render ends apply with render's own status.
cmd_apply() {
  local -a ra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --discard) ra+=(--discard) ;;
      *) die "usage: kit apply [--discard]" ;;
    esac
    shift
  done
  _scaffold quiet
  cmd_render "${ra[@]}"
  cmd_check
}

# cmd_edit <dest>: where a rendered file comes from, and how to change it.
cmd_edit() {
  local dest="${1:-}" from pin
  [ -n "$dest" ] || die "usage: kit edit <dest>"
  ctx_consumer
  pin="$(pin_of)"
  from=""
  if [ -f "$LOCK" ]; then
    from="$(jq -r --arg d "$dest" '.files[$d].from // empty' "$LOCK" 2> /dev/null)" || from=""
  fi
  if [ -z "$from" ]; then
    say "$dest is not rendered by the kit"
    return 1
  fi
  say "$dest is rendered from $from at ${pin:0:7}."
  cat <<'STEPS'
2. Claude states the change and why. A kit change reaches every consumer, so the user confirms first, as for any rules change.
3. In the kit's own clone (ask the user where it is), never in .claude/vendor/kit: `git -C <clone> switch -c <topic>`, edit the slice, add a CHANGELOG line, run `bin/kit selftest`, and commit on the topic branch. Writes outside the consumer prompt unless the user runs `/add-dir` for the clone.
4. Optional preview: `kit bump --from <clone> <topic>` on the consumer's session branch. Landing stays `UNPUBLISHED`, and a push of that branch aborts under `push.recurseSubmodules=check`.
5. `kit publish` in the clone. It prompts, and the prompt is the review.
6. `kit bump` in the consumer to the published sha, then commit and land. A fast-forward of kit `main` keeps the sha, so a preview needs no re-bump.
STEPS
}

# _bump_changelog <old> <new>: the CHANGELOG lines added between two pins.
_bump_changelog() {
  git -C "$VENDOR" diff "$1" "$2" -- CHANGELOG.md | sed -n 's/^+\([^+].*\)$/\1/p'
}

# cmd_bump [<rev>] [--from <path>]: move the gitlink, render with the new
# pin's code, show the CHANGELOG lines added. Never commits. When the render
# fails, the CHANGELOG lines print before the old pin is restored, since a
# BREAKING entry there names the edit the new pin needs.
cmd_bump() {
  local rev="" from="" old new
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || die "usage: kit bump [<rev>] [--from <path>]"
        from="$2"
        shift
        ;;
      -*) die "usage: kit bump [<rev>] [--from <path>]" ;;
      *)
        [ -z "$rev" ] || die "usage: kit bump [<rev>] [--from <path>]"
        rev="$1"
        ;;
    esac
    shift
  done
  ctx_consumer
  # Checked before the checkout moves: a failed git add would leave the new
  # pin staged, and the next bump would then miss this one's CHANGELOG lines.
  if git -C "$CON" check-ignore -q --no-index .claude/vendor/kit; then
    die "bump: cannot stage the gitlink: .gitignore ignores .claude/vendor/kit (git check-ignore -v --no-index .claude/vendor/kit names the line)"
  fi
  old="$(pin_of)"
  if [ -n "$from" ]; then
    [ -n "$rev" ] || rev=HEAD
    git -C "$VENDOR" fetch -q "$from" "$rev" || die "bump: cannot fetch $rev from $from"
    new="$(git -C "$VENDOR" rev-parse "FETCH_HEAD^{commit}")" || die "bump: cannot resolve $rev"
  else
    [ -n "$rev" ] || rev=origin/main
    git -C "$VENDOR" fetch -q origin || die "bump: cannot fetch origin"
    new="$(git -C "$VENDOR" rev-parse "$rev^{commit}")" || die "bump: cannot resolve $rev"
  fi
  git -C "$VENDOR" checkout -q --detach "$new" || die "bump: cannot check out ${new:0:7}"
  git -C "$CON" add .claude/vendor/kit || die "bump: cannot stage the gitlink"
  if ! env -u KIT_PINNED bash "$VENDOR/bin/kit" render; then
    _bump_changelog "$old" "$new"
    git -C "$VENDOR" checkout -q --detach "$old" || die "bump: cannot restore ${old:0:7}"
    git -C "$CON" add .claude/vendor/kit || die "bump: cannot re-stage ${old:0:7}"
    say "bump: render failed; restored ${old:0:7}"
    return 1
  fi
  say "bumped ${old:0:7} -> ${new:0:7}"
  _bump_changelog "$old" "$new"
}
