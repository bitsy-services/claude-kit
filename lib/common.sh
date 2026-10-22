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

# Scratch directories are made only by scratch_new and removed only by
# scratch_cleanup, which runs from one EXIT trap. rm never recurses in bin/ or lib/.
KIT_SCRATCH=()

# scratch_new <var>: make a scratch dir, register it, and set <var> to it.
# It sets a variable rather than printing because $(...) is a subshell: the
# registration and the trap would end with it and remove the dir at once.
scratch_new() {
  local _kit_sd
  _kit_sd="$(mktemp -d "${TMPDIR:-/tmp}/claude-kit.XXXXXX")" || return 2
  if [ "${#KIT_SCRATCH[@]}" = 0 ]; then trap scratch_cleanup EXIT; fi
  KIT_SCRATCH+=("$_kit_sd")
  printf -v "$1" '%s' "$_kit_sd"
}

# scratch_cleanup: remove every registered scratch dir. A registered path that
# is a symlink, not a directory, or not named claude-kit.?????? is left alone.
# It never fails, so the EXIT trap keeps the command's exit status under set -e.
scratch_cleanup() {
  local d
  for d in "${KIT_SCRATCH[@]}"; do
    if [ -L "$d" ] || [ ! -d "$d" ]; then
      printf 'internal: not removing scratch path %s\n' "$d" >&2
      continue
    fi
    case "${d##*/}" in
      claude-kit.??????) find -- "$d" -depth -delete || true ;;
      *) printf 'internal: not removing scratch path %s\n' "$d" >&2 ;;
    esac
  done
  KIT_SCRATCH=()
  return 0
}

# extract <rev> <dest> <paths...>: unpack paths of the vendored kit at <rev>.
extract() {
  local rev="$1" dest="$2"
  shift 2
  mkdir -p "$dest"
  git -C "$VENDOR" archive "$rev" "$@" | tar -x -C "$dest"
}
