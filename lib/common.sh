# Shared helpers. Sourced by bin/kit; uses only bash, git and jq.

say() { printf '%s\n' "$1"; }
note() { printf 'NOTICE %s\n' "$1"; }
die() { printf '%s\n' "$1" >&2; exit 2; }

# Sets CON and the consumer's paths. CON is the superproject when the cwd is
# inside the vendored kit checkout, else the git toplevel of the cwd.
ctx_consumer() {
  local sp
  sp="$(git rev-parse --show-superproject-working-tree 2>/dev/null)" || sp=""
  if [ -n "$sp" ]; then
    CON="$sp"
  else
    CON="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository"
  fi
  VENDOR="$CON/.claude/vendor/kit"
  KITJSON="$CON/.claude/kit.json"
  LOCK="$CON/.claude/kit.lock.json"
  SETTINGS="$CON/.claude/settings.json"
  REPO_MD="$CON/.claude/rules/repo.md"
}

# The gitlink staged in the consumer's index for the vendored kit, or nothing.
pin_of() {
  local mode sha _rest
  read -r mode sha _rest < <(git -C "$CON" ls-files -s -- .claude/vendor/kit) || true
  if [ "${mode:-}" = 160000 ]; then printf '%s\n' "$sha"; fi
}

blob_of() { git hash-object -- "$1"; }

# extract <rev> <dest> <paths...>: unpack paths of the vendored kit at <rev>.
extract() {
  local rev="$1" dest="$2"
  shift 2
  mkdir -p "$dest"
  git -C "$VENDOR" archive "$rev" "$@" | tar -x -C "$dest"
}
