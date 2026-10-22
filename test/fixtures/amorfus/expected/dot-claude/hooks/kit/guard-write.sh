#!/usr/bin/env bash
# <!-- kit: rendered from slices/core/hooks/guard-write.sh — edit the source in the kit, never this copy -->
#
# PreToolUse(Edit|Write|NotebookEdit) guard of the core slice: makes "never
# edit these" structural instead of advisory. A PreToolUse deny fires before
# any permission-mode check, so it holds in every mode.
#
#   ~/.claude/              outside source control; plan files under
#                           ~/.claude/plans/ are the one exception
#   rendered kit files      every dest named in the lock's files: the source
#                           is in the kit, and the deny names it
#   .claude/kit.lock.json   written by kit render
#   .claude/vendor/kit/     the vendored kit checkout, kept at the pin
#
# Fail closed. Without jq the path is read with sed, and a path sed cannot
# decode is denied. The lock cannot be read without jq (or when jq cannot
# parse it), so then everything under .claude/rules/kit/, .claude/hooks/kit/
# and a skill dir whose SKILL.md carries the kit stamp is denied.
# It takes no parameters: the kit's own sessions run this file unrendered.
set -uo pipefail

input=$(cat)
have_jq=0
if command -v jq >/dev/null 2>&1; then have_jq=1; fi

# deny <reason>: a deny decision. Without jq, exit 2 with the reason on
# stderr, which Claude Code also treats as a block.
deny() {
  if [ "$have_jq" = 1 ]; then
    jq -nc --arg r "$1" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }' && exit 0
  fi
  printf '%s\n' "$1" >&2
  exit 2
}

# sed_path <key>: "=<raw JSON string body>" for "<key>": "...", or nothing.
# A quote inside any JSON string is escaped, so only a real key matches.
sed_path() {
  printf '%s' "$input" | LC_ALL=C sed -n -E \
    's/^.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*$/=\1/p'
}

# unjson <raw>: decode \" \\ \/ into DECODED. Any other escape fails.
unjson() {
  local s="$1" out=""
  while :; do
    case "$s" in *\\*) ;; *) out+=$s; break ;; esac
    out+=${s%%\\*}
    s=${s#*\\}
    case "$s" in
      [\"\\/]*) out+=${s:0:1}; s=${s:1} ;;
      *) return 1 ;;
    esac
  done
  DECODED=$out
}

# norm <path>: the lexical normal form, into NORM: no ., .. or empty
# segments. Symlinks are not followed.
norm() {
  local rest="$1" seg out=""
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    case "$seg" in
      '' | .) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  NORM=${out:-/}
}

# stamp_from <file>: the kit source named by the file's stamp, if it has one.
stamp_from() {
  [ -f "$1" ] || return 0
  LC_ALL=C sed -n 's/^.*<!-- kit: rendered from \(slices\/[^ ]*\) — edit the source in the kit, never this copy -->.*$/\1/p' "$1"
}

rendered() {
  deny "$1 is rendered from $2: edit the source in the kit's clone, never this copy (see: kit edit $1)"
}

if [ "$have_jq" = 1 ]; then
  file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty') ||
    deny "the hook input is not JSON, so its path cannot be checked"
else
  raw=""
  for key in file_path notebook_path; do
    IFS= read -r raw < <(sed_path "$key") || true
    [ -n "$raw" ] && break
  done
  if [ -z "$raw" ]; then
    case "$input" in
      *'"file_path"'* | *'"notebook_path"'*) deny "jq is missing and sed cannot read the path, so it cannot be checked: install jq" ;;
    esac
    exit 0
  fi
  unjson "${raw#=}" || deny "jq is missing and the path holds an escape sed cannot decode: install jq"
  file=$DECODED
fi
[ -n "$file" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$file" in '~/'*) file="${HOME:-}/${file:2}" ;; esac
case "$file" in /*) ;; *) file="$root/$file" ;; esac
norm "$file"
file=$NORM
norm "$root"
root=${NORM%/}

if [ -n "${HOME:-}" ]; then
  norm "$HOME"
  dot="${NORM%/}/.claude"
  case "$file" in
    "$dot"/plans/?*) ;;
    "$dot" | "$dot"/*)
      deny "$file is outside source control: put the change in this repo (config in .claude/, memory in the memory root) so it is reviewable and revertible, or propose a kit change if every repo needs it"
      ;;
  esac
fi

case "$file" in
  "$root"/?*) rel="${file#"$root"/}" ;;
  *) exit 0 ;;   # elsewhere on disk (a scratchpad): not this repo's
esac

case "$rel" in
  .claude/kit.lock.json)
    deny "$rel is written by kit render and never edited by hand: change .claude/kit.json or the kit, then run kit render"
    ;;
  .claude/vendor/kit | .claude/vendor/kit/*)
    deny "$rel is in the vendored kit checkout, which stays at the pin: edit the source in the kit's clone, never this copy"
    ;;
esac

lock="$root/.claude/kit.lock.json"
[ -e "$lock" ] || exit 0
if [ "$have_jq" = 1 ]; then
  if from=$(jq -r --arg d "$rel" '(.files // {})[$d] // empty
      | if type == "object" and (.from | type) == "string" then .from else "the kit" end' "$lock" 2>/dev/null); then
    [ -n "$from" ] && rendered "$rel" "$from"
    exit 0
  fi
  cause="the lock cannot be read"
else
  cause="jq is missing"
fi

# The lock cannot say what is rendered: deny the kit's directories wholesale.
case "$rel" in
  .claude/rules/kit/?* | .claude/hooks/kit/?*) ;;
  .claude/skills/?*/?*)
    skill=${rel#.claude/skills/}
    skill=${skill%%/*}
    [ -n "$(stamp_from "$root/.claude/skills/$skill/SKILL.md")" ] || exit 0
    ;;
  *) exit 0 ;;
esac
from=""
IFS= read -r from < <(stamp_from "$file") || true
[ -n "$from" ] && rendered "$rel" "$from"
deny "$rel may be rendered by the kit, and $cause, so the guard cannot tell: edit the source in the kit's clone, never this copy (see: kit edit $rel)"
