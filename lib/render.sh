# Render the pinned slices into stamped copies and a lock; install them.
# Sourced after lib/common.sh and lib/config.sh; uses only bash, git and jq.

# Rendered text. Input: one raw file (-Rs). --slurpfile p: resolved params;
# --arg kind: md or sh; --arg stamp: the stamp text. {{kit.<name>}} is
# replaced in a single pass, so a value that itself holds {{kit.x}} stays
# literal. The stamp goes after the shebang (.sh), after the frontmatter's
# closing --- (.md), or on line 1.
_RENDER_TEXT_JQ='
def at($i; $s): .[:$i] + [$s] + .[$i:];
$p[0] as $v
| gsub("\\{\\{kit\\.(?<n>[A-Za-z0-9_]+)\\}\\}"; $v[.n])
| split("\n")
| if $kind == "sh" then
    at(if (.[0] | startswith("#!")) then 1 else 0 end; "# " + $stamp)
  elif .[0] == "---" and (.[1:] | index("---")) != null then
    at((.[1:] | index("---")) + 2; $stamp)
  else at(0; $stamp) end
| join("\n")
'

# Names used as {{kit.<name>}} that the resolved params do not carry.
_RENDER_REFS_JQ='
[ scan("\\{\\{kit\\.([A-Za-z0-9_]+)\\}\\}") | .[0] | select(. as $n | $p[0] | has($n) | not) ]
| unique[]
'

# The lock, from index.tsv lines: kind (f|x) <TAB> dest <TAB> src <TAB> blob.
# Maps are built in sorted key order so two renders write identical bytes.
_RENDER_LOCK_JQ='
[ inputs | split("\t") ] as $rows
| {
    format: 1,
    pin: $pin,
    files: ([ $rows[] | select(.[0] == "f") | {key: .[1], value: {from: .[2], blob: .[3]}} ]
            | sort_by(.key) | from_entries),
    excluded: ([ $rows[] | select(.[0] == "x") | {key: .[1], value: .[3]} ]
               | sort_by(.key) | from_entries)
  }
'

# render_text <src_file> <slice> <src_rel> <params.json>: print the
# substituted, stamped text. On a {{kit.<name>}} that no resolved param
# carries, print one RENDER line per name and return 1.
render_text() {
  local src="$1" slice="$2" rel="$3" params="$4" kind=md bad n
  case "$rel" in *.sh) kind=sh ;; esac
  bad="$(jq -Rrs --slurpfile p "$params" "$_RENDER_REFS_JQ" "$src")" || return 2
  if [ -n "$bad" ]; then
    while IFS= read -r n; do
      say "RENDER undeclared {{kit.$n}} in slices/$slice/$rel"
    done <<< "$bad"
    return 1
  fi
  jq -Rsj --slurpfile p "$params" --arg kind "$kind" \
    --arg stamp "<!-- kit: rendered from slices/$slice/$rel — edit the source in the kit, never this copy -->" \
    "$_RENDER_TEXT_JQ" "$src" || return 2
}

# render_expected <outdir>: render the pin into <outdir>:
#   files/<dest>     each rendered destination that is not excluded
#   excluded/<dest>  each excluded destination, rendered only for its blob
#   lock.json        {format, pin, files, excluded}
# plus working files (tree/, config.json, params.json, index.tsv).
# Needs ctx_consumer. Prints CONFIG or RENDER lines and returns 1 on problems.
render_expected() {
  local out="$1" pin dest src slice rel target blob r rc=0
  local -A excl=()
  pin="$(pin_of)"
  [ -n "$pin" ] || return 2
  extract "$pin" "$out/tree" slices || return 2
  config_resolve "$out/tree" "$out/config.json" || return $?
  jq '.params' "$out/config.json" > "$out/params.json" || return 2
  while IFS= read -r dest; do
    excl["$dest"]=1
  done < <(jq -r '.exclude[]' "$out/config.json")
  : > "$out/index.tsv"
  while IFS=$'\t' read -r dest src slice; do
    rel="${src#slices/"$slice"/}"
    if [ -n "${excl[$dest]+x}" ]; then target="$out/excluded/$dest"; else target="$out/files/$dest"; fi
    mkdir -p "${target%/*}" || return 2
    if render_text "$out/tree/$src" "$slice" "$rel" "$out/params.json" > "$target"; then
      blob="$(blob_of "$target")" || return 2
      if [ -n "${excl[$dest]+x}" ]; then r=x; else r=f; fi
      printf '%s\t%s\t%s\t%s\n' "$r" "$dest" "$src" "$blob" >> "$out/index.tsv"
    else
      r=$?
      [ "$r" = 1 ] || return 2
      cat "$target"
      rc=1
    fi
  done < <(jq -r '.paths[] | join("\t")' "$out/config.json")
  [ "$rc" = 0 ] || return 1
  jq -Rn --arg pin "$pin" "$_RENDER_LOCK_JQ" < "$out/index.tsv" > "$out/lock.json" || return 2
}

# A lock entry is removable only if it has the shape of a kit destination.
_render_dest_ok() {
  case "$1" in
    */../* | */./* | *//*) return 1 ;;
    .claude/rules/kit/*/* | .claude/hooks/kit/*/* | .claude/skills/*/*/*) return 1 ;;
    .claude/rules/kit/?*.md | .claude/hooks/kit/?*.sh | .claude/skills/?*/SKILL.md) return 0 ;;
  esac
  return 1
}

# cmd_render [--discard]: install the rendered pin into the consumer. Every
# destination is checked before anything is written. Only lock-named paths
# that are neither rendered nor excluded are removed, then empty skill
# directories. An excluded dest is never written, refused or removed: it
# leaves `files` for `excluded` and stays on disk as it is (R9).
cmd_render() {
  local discard=0 tmp d b p cur bad=0
  local -a dests=() olds=() orphans=()
  local -A want=() owned=() have=() excl=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --discard) discard=1 ;;
      *) die "usage: kit render [--discard]" ;;
    esac
    shift
  done
  ctx_consumer
  scratch_new tmp || die "render: cannot make a scratch directory"
  render_expected "$tmp" || return $?

  while IFS=$'\t' read -r d b; do
    dests+=("$d")
    want["$d"]="$b"
  done < <(jq -r '.files | to_entries[] | "\(.key)\t\(.value.blob)"' "$tmp/lock.json")
  while IFS= read -r d; do
    excl["$d"]=1
  done < <(jq -r '.excluded | keys[]' "$tmp/lock.json")
  if [ -e "$LOCK" ]; then
    if ! jq -e 'type == "object" and ((.files // {}) | type == "object"
          and all(.[]; type == "object" and (.blob | type) == "string"))' "$LOCK" > /dev/null 2>&1; then
      say "RENDER .claude/kit.lock.json is not a valid kit lock; restore it from git"
      return 1
    fi
    while IFS=$'\t' read -r d b; do
      olds+=("$d")
      owned["$d"]="$b"
    done < <(jq -r '(.files // {}) | to_entries | sort_by(.key)[] | "\(.key)\t\(.value.blob)"' "$LOCK")
  fi

  for d in "${dests[@]}"; do
    if [ ! -e "$CON/$d" ]; then continue; fi
    cur="$(blob_of "$CON/$d")" || die "render: cannot read $d"
    have["$d"]="$cur"
    if [ "$cur" = "${want[$d]}" ] || [ "$discard" = 1 ]; then continue; fi
    if [ -z "${owned[$d]+x}" ]; then
      say "REFUSE $d: exists and is not rendered by the kit; rerun with --discard to overwrite"
      bad=1
    elif [ "$cur" != "${owned[$d]}" ]; then
      say "REFUSE $d: edited in place (blob differs from the lock); rerun with --discard to overwrite"
      bad=1
    fi
  done
  for d in "${olds[@]}"; do
    if [ -n "${want[$d]+x}" ] || [ -n "${excl[$d]+x}" ]; then continue; fi
    if ! _render_dest_ok "$d"; then
      say "RENDER .claude/kit.lock.json names $d, which is not a kit destination"
      bad=1
      continue
    fi
    orphans+=("$d")
    if [ ! -e "$CON/$d" ] || [ "$discard" = 1 ]; then continue; fi
    cur="$(blob_of "$CON/$d")" || die "render: cannot read $d"
    if [ "$cur" != "${owned[$d]}" ]; then
      say "REFUSE $d: edited in place (blob differs from the lock); rerun with --discard to remove"
      bad=1
    fi
  done
  if [ "$bad" != 0 ]; then return 1; fi

  for d in "${dests[@]}"; do
    if [ "${have[$d]:-}" = "${want[$d]}" ]; then continue; fi
    p="$CON/$d"
    mkdir -p -- "${p%/*}" || die "render: cannot write $d"
    cp -- "$tmp/files/$d" "$p" || die "render: cannot write $d"
  done
  for d in "${orphans[@]}"; do
    rm -f -- "$CON/$d" || die "render: cannot remove $d"
    case "$d" in
      .claude/skills/*/SKILL.md) rmdir -- "$CON/${d%/SKILL.md}" 2> /dev/null || true ;;
    esac
  done
  cp -- "$tmp/lock.json" "$LOCK" || die "render: cannot write .claude/kit.lock.json"
}
