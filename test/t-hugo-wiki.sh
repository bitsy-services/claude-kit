#!/usr/bin/env bash
# The real hugo-wiki slice, rendered with core and wiki_dir "content/wiki":
# wiki_dir reaches the rules, hugo-on-workers alone is path-scoped, the hugo
# allows render, kit check passes, and the slice's forbid is enforced.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp" "$T/in"
export TMPDIR="$T/tmp"

# basic's inputs (CLAUDE.md import, memory index, repo.md, settings).
cp -R "$TEST_ROOT/test/consumers/basic/." "$T/in/"
echo '{"format":1,"slices":["core","hugo-wiki"],"params":{"gate":"bash scripts/check.sh","wiki_dir":"content/wiki"},"exclude":[]}' > "$T/in/kit.json"
mk_kit "$TEST_ROOT/slices"
mk_consumer "$T/in"
kit_run render
is "$RC" 0 "render exits 0"
RULES="$CON/.claude/rules/kit"
SETTINGS="$CON/.claude/settings.json"

# frontmatter <file>: print the lines between a line-1 "---" and the next
# "---"; print nothing when line 1 is not "---".
frontmatter() {
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    if [ "$n" = 1 ]; then
      [ "$line" = "---" ] || return 0
      continue
    fi
    [ "$line" = "---" ] && return 0
    printf '%s\n' "$line"
  done < "$1"
}

t_wiki_dir_rendered() {
  like "$(cat "$RULES/wiki-linking.md" 2> /dev/null)" 'content/wiki' "wiki-linking: contains content/wiki"
}

t_on_workers_scoped() {
  local f="$RULES/hugo-on-workers.md" fm got
  has_file "$f"
  is "$(head -n 1 "$f" 2> /dev/null)" '---' "hugo-on-workers: starts with ---"
  fm="$(frontmatter "$f" 2> /dev/null)"
  like "$fm" '^paths:' "hugo-on-workers: frontmatter has paths:"
  unlike "$fm" '^globs:' "hugo-on-workers: frontmatter has no globs:"
  got="$(printf '%s\n' "$fm" | sed -n 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | tr '\n' ' ')"
  is "$got" '**/hugo.toml **/wrangler.* **/layouts/** **/scripts/** ' \
    "hugo-on-workers: paths are **/hugo.toml, **/wrangler.*, **/layouts/** and **/scripts/**"
}

# R29: knowledge needed while writing a page is always on; the vendor/
# gitignore trap is not in this slice.
t_moved() {
  like "$(cat "$RULES/wiki-content.md" 2> /dev/null)" "ignoreFiles = \['CLAUDE\\\\\.md\\$'\]" \
    "wiki-content: carries the ignoreFiles line"
  like "$(cat "$RULES/wiki-content.md" 2> /dev/null)" '`kind`' "wiki-content: carries the reserved keys"
  like "$(cat "$RULES/wiki-linking.md" 2> /dev/null)" '`bash scripts/check\.sh` must check links' \
    "wiki-linking: the gate checks plain links"
  is "$(cat "$RULES"/wiki-*.md "$RULES/hugo-on-workers.md" 2> /dev/null | grep -c 'vendor/')" 0 \
    "rules: no vendor/ gitignore trap"
}

t_always_on() {
  local n f
  for n in wiki-linking wiki-content wiki-workflow; do
    f="$RULES/$n.md"
    has_file "$f"
    unlike "$(frontmatter "$f" 2> /dev/null)" '^(paths|globs):' "$n: no frontmatter paths"
  done
}

t_no_placeholder_left() {
  local d dests left=""
  dests="$(jq -r '.files | keys[]' "$CON/.claude/kit.lock.json" 2> /dev/null)" || left=" (no lock)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if grep -qF '{{kit.' "$CON/$d"; then left="$left $d"; fi
  done <<< "$dests"
  if grep -qF '{{kit.' "$SETTINGS"; then left="$left .claude/settings.json"; fi
  is "${left:-none}" none "render: no rendered file contains {{kit."
}

t_allows() {
  is "$(jq '[.permissions.allow // [] | .[] | select(IN("Bash(hugo)", "Bash(hugo version)", "Bash(hugo env)",
      "Bash(hugo --minify *)", "Bash(hugo -D *)", "Bash(hugo server *)"))] | unique | length' "$SETTINGS" 2> /dev/null)" 6 \
    "allow: the six hugo verbs"
}

t_check() {
  kit_run check
  is "$RC" 0 "check: kit check exits 0"
  like "$OUT" '^kit check: ok$' "check: kit check reports ok"
}

t_forbid() {
  local e re
  cp "$SETTINGS" "$T/settings.bak"
  for e in 'Bash(hugo *)' 'Bash(hugo:*)' 'Bash(hugo deploy *)' 'Bash(hugo deploy:*)'; do
    jq --arg e "$e" '.permissions.allow += [$e]' "$T/settings.bak" > "$SETTINGS"
    kit_run check
    is "$RC" 1 "forbid $e: check exits 1"
    re="$(printf '%s' "$e" | sed 's/[][\.*^$()+?{}|]/\\&/g')"
    like "$OUT" "^FORBID $re in permissions\\.allow \\(hugo-wiki\\): " "forbid $e: named"
  done
  cp "$T/settings.bak" "$SETTINGS"
}

t_wiki_dir_rendered
t_on_workers_scoped
t_moved
t_always_on
t_no_placeholder_left
t_allows
t_check
t_forbid
done_testing
