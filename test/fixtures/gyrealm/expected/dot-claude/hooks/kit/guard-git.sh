#!/usr/bin/env bash
# <!-- kit: rendered from slices/session-branch/hooks/guard-git.sh — edit the source in the kit, never this copy -->
# PreToolUse(Bash) guard of the session-branch slice.
# Policy: the trunk moves only by fast-forward (git merge --ff-only on the trunk, as
# /merge-to-main runs it, or a plain catch-up from the remote); no branch is deleted;
# in a kit consumer, nothing is pushed while the kit pin is unpublished.
# Method: strip quotes, turn separators, substitutions, subshells and groups into
# segment breaks, scan each segment forward to the word `git`, skip git's global
# options, resolve aliases, track HEAD and cwd across segments. Word-level: it stops
# mistakes, not an adversary (python3 -c, variables and scripts are out of reach).
# Battery: test/guard-git.cases in the kit repo.
set -u
# KIT_TRUNK lets the kit's own sessions run this file unrendered. Two
# assignments, because an unrendered default inside ${KIT_TRUNK:-...} would
# end at its own first closing brace and leave the rest on the value.
TRUNK="main"
TRUNK="${KIT_TRUNK:-$TRUNK}"
refuse() { jq -cn --arg r "$1" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
deny() { refuse "Refusing $1. '$TRUNK' moves only by fast-forward from a session branch (/merge-to-main), and no branch is ever deleted. Work on a session branch: git switch -c <topic>."; }
input=$(cat)
if ! command -v jq >/dev/null 2>&1; then          # fail closed, but only for commands that mention git
  case "$input" in *git*) echo "guard-git: jq is not installed, so this git command cannot be checked. Install jq outside this session, then retry." >&2; exit 2 ;; esac
  exit 0
fi
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty'); [ -z "$cmd" ] && exit 0
case "$cmd" in *git*) ;; *) exit 0 ;; esac
case "$TRUNK" in ''|*'{{'*)                       # unrendered and no KIT_TRUNK: fail closed
  refuse "Refusing every git command: this guard has no trunk name (it was not rendered, and KIT_TRUNK is unset), so it cannot tell the trunk from a session branch. Run kit render, or set KIT_TRUNK where the hook is registered." ;; esac
root="${CLAUDE_PROJECT_DIR:-$PWD}"
is_trunk() { [ "$1" = "$TRUNK" ] || [ "$1" = "refs/heads/$TRUNK" ]; }
head_of() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }
abspath() { local d=$2; case "$d" in '~'|'~/'*) d=$HOME${d:1} ;; '$HOME'|'$HOME/'*) d=$HOME${d:5} ;; esac
  case "$d" in /*) printf '%s' "$d" ;; *) printf '%s/%s' "$1" "$d" ;; esac; }

# A kit consumer (it has a kit lock; the kit's own repo has none) pushes only pins
# that are on the kit's origin/main as of the last fetch, so every clone can fetch
# them. Any git push counts, to any remote. The repo judged is the one pushed: the
# toplevel of its directory (cd, git -C), or the session project when --git-dir,
# --work-tree, GIT_DIR or GIT_WORK_TREE point git elsewhere. The pin is read from
# each pushed ref as <src>:.claude/vendor/kit (the current branch when no refspec
# is given; every branch for --all), and from the gitlink staged in the index when
# a source does not resolve or git was pointed elsewhere.
check_push() {
  local top vendor mode="" ipin="" rest x src pin k
  local -a srcs=() pins=() from=()
  if [ "$alt" = 1 ]; then top=$root
  else top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || return 0; fi
  [ -e "$top/.claude/kit.lock.json" ] || return 0
  vendor="$top/.claude/vendor/kit"
  read -r mode ipin rest < <(git -C "$top" ls-files -s -- .claude/vendor/kit 2>/dev/null) || true
  [ "$mode" = 160000 ] || ipin=""
  if [ "$alt" = 0 ]; then
    for x in "${pos[@]:1}"; do                   # a refspec's source; :dst deletes, refused above
      x=${x#+}; x=${x%%:*}
      case "$x" in '') ;; HEAD) srcs+=("${head:-HEAD}") ;; *) srcs+=("$x") ;; esac
    done
    [ "${#pos[@]}" -gt 1 ] || srcs+=("${head:-HEAD}")
    if [[ $a =~ \ (--all|--branches|--mirror)\  ]]; then
      while IFS= read -r x; do srcs+=("$x"); done < <(git -C "$top" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)
    fi
    if [[ $a =~ \ (--tags|--mirror)\  ]]; then
      while IFS= read -r x; do srcs+=("$x"); done < <(git -C "$top" for-each-ref --format='%(refname)' refs/tags/ 2>/dev/null)
    fi
  fi
  for src in "${srcs[@]}"; do
    if pin=$(git -C "$top" rev-parse -q --verify "$src:.claude/vendor/kit" 2>/dev/null) && [ -n "$pin" ]; then
      pins+=("$pin"); from+=("on ${src#refs/heads/}")
    elif [ -n "$ipin" ]; then
      pins+=("$ipin"); from+=("staged at .claude/vendor/kit")
    else
      refuse "no kit pin is staged at .claude/vendor/kit, and ${src#refs/heads/} carries none, so it cannot be verified: restore the gitlink, or remove .claude/kit.lock.json if this repo no longer uses the kit"
    fi
  done
  if [ "${#srcs[@]}" = 0 ]; then
    [ -n "$ipin" ] || refuse "no kit pin is staged at .claude/vendor/kit, so it cannot be verified: restore the gitlink, or remove .claude/kit.lock.json if this repo no longer uses the kit"
    pins+=("$ipin"); from+=("staged at .claude/vendor/kit")
  fi
  # An uninitialised submodule dir has no .git, and git -C would find the consumer's.
  if [ ! -e "$vendor/.git" ] || ! git -C "$vendor" rev-parse --git-dir >/dev/null 2>&1; then
    refuse "kit checkout is absent, so the pin cannot be verified: run kit init"
  fi
  for k in "${!pins[@]}"; do
    git -C "$vendor" merge-base --is-ancestor "${pins[$k]}" refs/remotes/origin/main 2>/dev/null ||
      refuse "kit pin ${pins[$k]:0:7} ${from[$k]} is not on the kit's origin/main as of the last fetch: publish the kit first, or run kit check --published"
  done
}

cwd=$root; sim_head=""; sim_repo=""
segs=$(printf '%s' "$cmd" | tr -d "\"'\\\\" | sed -E 's/\$\(|`|\(|\)|\{|\}|&&|\|\||;|\||&/\n/g')
while IFS= read -r seg; do
  read -ra w <<<"$seg"; n=${#w[@]}; [ "$n" -gt 0 ] || continue
  if [ "${w[0]}" = cd ] || [ "${w[0]}" = pushd ]; then cwd=$(abspath "$cwd" "${w[1]:-$HOME}"); continue; fi
  i=0; while [ $i -lt $n ] && [ "${w[$i]##*/}" != git ]; do i=$((i+1)); done
  [ $i -lt $n ] || continue
  alt=0                                         # git pointed away from its directory
  for x in "${w[@]:0:$i}"; do case "$x" in GIT_DIR=*|GIT_WORK_TREE=*) alt=1 ;; esac; done
  i=$((i+1)); repo=$cwd
  while [ $i -lt $n ]; do case "${w[$i]}" in
      -C) repo=$(abspath "$repo" "${w[$((i+1))]:-.}"); i=$((i+2)) ;;
      -c) case "${w[$((i+1))]:-}" in alias.*) deny "'git -c alias.*' (it hides the real subcommand)";; esac; i=$((i+2)) ;;
      --git-dir|--work-tree) alt=1; i=$((i+2)) ;;
      --git-dir=*|--work-tree=*) alt=1; i=$((i+1)) ;;
      --namespace|--exec-path|--config-env|--super-prefix) i=$((i+2)) ;;
      -*) i=$((i+1)) ;;
      *) break ;;
    esac; done
  sub=${w[$i]:-}; args=("${w[@]:$((i+1))}")
  if exp=$(git -C "$repo" config --get "alias.$sub" 2>/dev/null); then
    case "$exp" in '!'*) deny "the shell alias 'git $sub'";; esac
    read -ra e <<<"$exp"; sub=${e[0]}; args=("${e[@]:1}" "${args[@]}")
  fi
  if [ "$repo" = "$sim_repo" ] && [ -n "$sim_head" ]; then head=$sim_head; else head=$(head_of "$repo"); fi
  a=" ${args[*]} "
  case "$sub" in                                # options that take a separate value, per subcommand
    rebase) vopt=" --onto -s --strategy -X --strategy-option -x --exec " ;;
    fetch)  vopt=" --depth --deepen --shallow-since --shallow-exclude -j --jobs --negotiation-tip --refmap -o --server-option --upload-pack " ;;
    push)   vopt=" -o --push-option --receive-pack --exec --repo " ;;
    branch) vopt=" -u --set-upstream-to " ;;
    *)      vopt=" " ;;
  esac
  pos=(); skip=0                                # positional args, option values removed
  for x in "${args[@]}"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$x" in --) break ;; -*) [[ $vopt == *" $x "* ]] && skip=1 ;; *) pos+=("$x") ;; esac
  done
  case "$sub" in
    branch)
      [[ $a =~ \ (-d|-D|--delete)\  ]] && deny "branch deletion"
      if [[ $a =~ \ (-f|--force|-m|-M|--move|-c|-C|--copy)\  ]]; then for x in "${pos[@]}"; do is_trunk "$x" && deny "a forced move, rename or copy onto '$TRUNK'"; done; fi ;;
    switch|checkout)
      if [[ $a =~ \ (-C|-B|--force-create)\  ]]; then for x in "${pos[@]}"; do is_trunk "$x" && deny "'git $sub' resetting '$TRUNK'"; done; fi
      if [[ $a =~ \ (-c|-b|-C|-B|--create|--force-create|--orphan)\  ]]; then sim_head=${pos[0]:-other}; sim_repo=$repo
      elif [ "${#pos[@]}" = 1 ] && ! is_trunk "${pos[0]}" && [[ ! $a =~ \ (--|-d|--detach)\  ]] &&
           git -C "$repo" rev-parse -q --verify "refs/heads/${pos[0]}" >/dev/null 2>&1; then
        sim_head=${pos[0]}; sim_repo=$repo          # a plain switch to another local branch, not a path checkout
      else for x in "${pos[@]}"; do is_trunk "$x" && { sim_head=$TRUNK; sim_repo=$repo; }; done; fi ;;
    update-ref)
      [[ $a =~ \ -d\  ]] && deny "ref deletion"
      for x in "${pos[@]}"; do is_trunk "$x" && deny "'git update-ref' on '$TRUNK'"; done ;;
    fetch|push)
      remote=${pos[0]:-}
      for x in "${pos[@]:1}"; do
        case "$x" in :*) [ "$sub" = push ] && deny "a push that deletes a branch";; esac
        [[ $x == *:* ]] || continue
        dst=${x##*:}; src=${x%%:*}; src=${src#+}
        is_trunk "$dst" || continue
        [[ $x == +* ]] && deny "the forced refspec $x"
        [[ $a =~ \ (-f|--force|--force-with-lease[^\ ]*)\  ]] && deny "a forced $sub into '$TRUNK'"
        case "$remote" in .|..|./*|../*|/*) deny "a local $sub into '$TRUNK'";; esac
        if [ "$sub" = push ] && ! is_trunk "$src" && { [ "$src" != HEAD ] || [ "$head" != "$TRUNK" ]; }; then deny "pushing another branch onto '$TRUNK'"; fi
      done
      [ "$sub" = push ] && [[ $a =~ \ (-d|--delete)\  ]] && deny "a push that deletes a branch"
      [ "$sub" = push ] && check_push ;;
    rebase)
      if [ "$head" = "$TRUNK" ]; then [[ $a =~ \ (--abort|--quit)\  ]] || deny "'git rebase' on '$TRUNK'"; fi
      if [[ $a =~ \ --root\  ]]; then is_trunk "${pos[0]:-}" && deny "'git rebase --root $TRUNK'"
      else is_trunk "${pos[1]:-}" && deny "'git rebase <upstream> $TRUNK'"; fi ;;
  esac
  [ "$head" = "$TRUNK" ] || continue
  case "$sub" in
    commit|cherry-pick|revert|am) deny "'git $sub' on '$TRUNK'" ;;
    merge) [[ $a =~ \ (--ff-only|--abort|--continue|--quit)\  ]] || deny "'git merge' without --ff-only on '$TRUNK'" ;;
    pull)  [[ $a =~ \ --ff-only\  ]] || deny "'git pull' without --ff-only on '$TRUNK'" ;;
    reset) [[ $a =~ \ (--hard|--soft|--mixed|--keep|--merge)\  ]] && deny "'git reset' with a mode on '$TRUNK'"
           if [ -n "${pos[0]:-}" ] && c=$(git -C "$repo" rev-parse -q --verify "${pos[0]}^{commit}" 2>/dev/null); then
             [ "$c" = "$(git -C "$repo" rev-parse HEAD)" ] || deny "'git reset ${pos[0]}' on '$TRUNK'"; fi ;;
  esac
done <<<"$segs"
exit 0
