# Consumer commands: status, init, scaffold, edit, bump.
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

# cmd_init: fetch the pinned checkout and make pushes check submodules.
cmd_init() {
  ctx_consumer
  git -C "$CON" submodule update --init .claude/vendor/kit || return 1
  git -C "$CON" config push.recurseSubmodules check || return 1
}

# _scaffold_item <path> <content|->: create the file only when absent.
_scaffold_item() {
  local p="$1" body="$2" rel="${1#"$CON"/}"
  if [ -e "$p" ]; then say "kept $rel"; return 0; fi
  mkdir -p -- "${p%/*}" || die "scaffold: cannot create $rel"
  if [ "$body" = "-" ]; then : > "$p"; else printf '%s' "$body" > "$p"; fi
  say "created $rel"
}

# cmd_scaffold: create only what is absent.
cmd_scaffold() {
  local pin tmp tree mroot=.claude/memory body h cfg
  ctx_consumer
  pin="$(pin_of)"
  scratch_new tmp || die "scaffold: cannot make a scratch directory"
  tree="$tmp/tree"
  extract "$pin" "$tree" slices || die "scaffold: cannot read the kit at ${pin:0:7}"

  if [ ! -e "$KITJSON" ]; then
    # Core's required params, as "".
    if ! jq -c -n --slurpfile d "$tree/slices/core/slice.json" '
        {format: 1, slices: ["core"],
         params: ({gate: ""} + ([ ($d[0].params // {}) | to_entries[] | select(.value.required == true) | {(.key): ""} ] | add // {})),
         exclude: []}' > "$tmp/kit.min" 2> /dev/null; then
      echo '{"format":1,"slices":["core"],"params":{"gate":""},"exclude":[]}' > "$tmp/kit.min"
    fi
    _scaffold_item "$KITJSON" "$(cat "$tmp/kit.min")
"
  else
    _scaffold_item "$KITJSON" ""
  fi

  # repo.md: the headings of the slices listed in an existing kit.json.
  body=""
  if [ -f "$KITJSON" ] && jq -e 'type == "object"' "$KITJSON" > /dev/null 2>&1; then
    while IFS= read -r h; do
      body+="## $h

"
    done < <(
      while IFS= read -r cfg; do
        case "$cfg" in '' | *[!A-Za-z0-9_-]*) continue ;; esac
        [ -f "$tree/slices/$cfg/slice.json" ] || continue
        jq -r '(.headings // []) | if type == "array" then .[] | strings else empty end' "$tree/slices/$cfg/slice.json" 2> /dev/null
      done < <(jq -r '(.slices // []) | if type == "array" then .[] | strings else empty end' "$KITJSON")
    )
  fi
  _scaffold_item "$REPO_MD" "$body"

  if [ -f "$KITJSON" ] && config_resolve "$tree" "$tmp/config.json" > /dev/null 2>&1; then
    mroot="$(jq -r '.params.memory_root // ".claude/memory"' "$tmp/config.json")"
  fi
  _scaffold_item "$CON/$mroot/MEMORY.md" "# Memory

"
  _scaffold_item "$CON/$mroot/friction/.gitkeep" -
  _scaffold_item "$CON/$mroot/patterns/.gitkeep" -
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
2. Claude states the change and why. A kit change reaches every consumer, so Paul confirms first, as for any rules change.
3. In the standalone clone: `git -C ~/git/bitsy-services/claude-kit switch -c <topic>`, edit the slice, add a CHANGELOG line, run `bin/kit selftest`, and commit on the topic branch. Writes outside the consumer prompt unless Paul runs `/add-dir` for the clone.
4. Optional preview: `kit bump --from ~/git/bitsy-services/claude-kit <topic>` on the consumer's session branch. Landing stays `UNPUBLISHED`, and a push of that branch aborts under `push.recurseSubmodules=check`.
5. `kit publish` in the clone. It prompts, and the prompt is the review.
6. `kit bump` in the consumer to the published sha, then commit and land. A fast-forward of kit `main` keeps the sha, so a preview needs no re-bump.
STEPS
}

# cmd_bump [<rev>] [--from <path>]: move the gitlink, render with the new
# pin's code, show the CHANGELOG lines added. Never commits.
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
    git -C "$VENDOR" checkout -q --detach "$old" || die "bump: cannot restore ${old:0:7}"
    git -C "$CON" add .claude/vendor/kit || die "bump: cannot re-stage ${old:0:7}"
    say "bump: render failed; restored ${old:0:7}"
    return 1
  fi
  say "bumped ${old:0:7} -> ${new:0:7}"
  git -C "$VENDOR" diff "$old" "$new" -- CHANGELOG.md | sed -n 's/^+\([^+].*\)$/\1/p'
}
