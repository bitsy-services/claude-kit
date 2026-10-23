#!/usr/bin/env bash
# The README's steps with the real slices: git submodule add and kit init,
# then kit apply, take a repo to kit check: ok. A fresh repo; a Hugo site
# whose hugo-book theme is a submodule in site/; a site whose pages are
# mounted from elsewhere; a repo with its own settings, skill, memory index
# and master branch.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
mk_kit "$TEST_ROOT/slices"

# repo <dir> <branch>: a new repo with one empty commit.
repo() {
  git init -q -b "$2" "$1"
  git -C "$1" commit -q --allow-empty -m init
}

# adopt <dir>: vendor the kit in the repo at <dir>, with .gitmodules naming
# the https URL as a real consumer's does, then run kit init there.
adopt() {
  CON="$1"
  git -C "$CON" -c protocol.file.allow=always submodule add -q "file://$T/kit" .claude/vendor/kit
  git config -f "$CON/.gitmodules" submodule..claude/vendor/kit.url https://github.com/bitsy-services/claude-kit
  GIT_ALLOW_PROTOCOL=file kit_run init
}

t_fresh() {
  local h
  repo "$T/fresh" main
  adopt "$T/fresh"
  is "$RC" 0 "fresh: init exits 0"
  is "$(jq -c .slices "$CON/.claude/kit.json")" '["core","self-improvement","session-branch"]' "fresh: every slice but hugo-wiki"
  like "$OUT" '^  skipped hugo-wiki: no themes/hugo-book found$' "fresh: says why hugo-wiki is left out"
  kit_run apply
  is "$RC" 0 "fresh: apply exits 0"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "kit check: ok" "fresh: apply ends with kit check: ok"
  like "$OUT" '^NOTICE gate is kit check' "fresh: the fallback gate keeps its notice"
  for h in Deploy Gate "Conflict stops" "Branch names"; do
    like "$(cat "$CON/.claude/rules/repo.md")" "^## $h$" "fresh: repo.md has ## $h"
  done
  like "$(cat "$CON/CLAUDE.md")" '^@\.claude/memory/MEMORY\.md$' "fresh: CLAUDE.md imports the memory index"
  is "$(cat "$CON/.gitattributes")" '.claude/** text=auto eol=lf' "fresh: .gitattributes keeps .claude/ text in LF"
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "Adopt claude-kit"
  is "$(git -C "$CON" status --porcelain)" "" "fresh: the commit leaves nothing behind"
  kit_run apply
  unlike "$OUT" '^(created|added|filled) ' "fresh: a second apply changes nothing"
  # With .gitattributes in place, a CRLF copy of a rendered hook still shows
  # as drift, and apply --discard writes it back in LF.
  sed -i 's/$/\r/' "$CON/.claude/hooks/kit/guard-git.sh"
  kit_run check
  like "$OUT" '^DRIFT \.claude/hooks/kit/guard-git\.sh ' "fresh: a CRLF hook is drift"
  kit_run apply --discard
  is "$RC" 0 "fresh: apply --discard repairs it"
  is "$(grep -c $'\r' "$CON/.claude/hooks/kit/guard-git.sh")" 0 "fresh: the hook is LF again"
}

t_hugo() {
  repo "$T/theme" main
  repo "$T/hugo" main
  mkdir -p "$T/hugo/site/content/wiki" "$T/hugo/scripts"
  printf -- '---\ntitle: Page\n---\n\n## Body\n' > "$T/hugo/site/content/wiki/page.md"
  printf '#!/usr/bin/env bash\n' > "$T/hugo/scripts/check.sh"
  git -C "$T/hugo" add -A
  git -C "$T/hugo" commit -q -m site
  git -C "$T/hugo" -c protocol.file.allow=always submodule add -q "file://$T/theme" site/themes/hugo-book
  git -C "$T/hugo" commit -q -m theme
  adopt "$T/hugo"
  is "$(jq -c . "$CON/.claude/kit.json")" \
    '{"format":1,"slices":["core","hugo-wiki","self-improvement","session-branch"],"params":{"gate":"bash scripts/check.sh","wiki_dir":"site/content"},"exclude":[]}' \
    "hugo: hugo-wiki from the theme's submodule, wiki_dir beside it"
  kit_run apply
  is "$RC" 0 "hugo: apply exits 0"
  unlike "$OUT" '^NOTICE' "hugo: a gate it found leaves no notice"
}

t_mounted() {
  local r="$T/mounted"
  repo "$r" main
  mkdir -p "$r/site/themes/hugo-book/layouts" "$r/site/content" "$r/wiki"
  echo x > "$r/site/themes/hugo-book/layouts/baseof.html"
  printf -- '---\ntitle: Home\n---\n' > "$r/site/content/_index.md"
  printf -- '---\ntitle: Accueil\n---\n' > "$r/site/content/_index.fr.md"
  printf -- '---\ntitle: Page\n---\n' > "$r/wiki/page.md"
  git -C "$r" add -A
  git -C "$r" commit -q -m site
  adopt "$r"
  like "$(jq -c .slices "$CON/.claude/kit.json")" 'hugo-wiki' "mounted: a theme copied in, not a submodule, still counts"
  like "$OUT" '^NOTICE site/content holds no pages besides _index\.md: set "wiki_dir" in \.claude/kit\.json to the folder that holds them$' \
    "mounted: wiki_dir is asked for, not guessed (section indexes are no pages)"
  is "$(jq -r '.params.wiki_dir // "unset"' "$CON/.claude/kit.json")" unset "mounted: wiki_dir is not written"
  kit_run apply
  is "$RC" 0 "mounted: apply exits 0"
  like "$OUT" '^NOTICE wiki_dir is content, which holds no pages besides _index\.md: set "wiki_dir" in \.claude/kit\.json to the folder that holds them$' \
    "mounted: check repeats the wiki_dir notice"
  jq '.params.wiki_dir = "wiki"' "$CON/.claude/kit.json" > "$T/k.json"
  cp "$T/k.json" "$CON/.claude/kit.json"
  kit_run apply
  unlike "$OUT" 'holds no pages' "mounted: the notice ends once wiki_dir holds pages"
}

t_existing() {
  local r="$T/existing"
  git init -q -b master "$r"
  mkdir -p "$r/.claude/skills/merge-to-main" "$r/brain"
  printf '# Project\n\nNotes.\n@brain/MEMORY.md' > "$r/CLAUDE.md"
  printf '# Memory\n' > "$r/brain/MEMORY.md"
  echo '{"permissions":{"allow":["Bash(git *)","Bash(make test)"]}}' > "$r/.claude/settings.json"
  printf -- '---\nname: merge-to-main\ndescription: Ours.\n---\n\nOurs.\n' > "$r/.claude/skills/merge-to-main/SKILL.md"
  echo '{"scripts":{"test":"vitest run"}}' > "$r/package.json"
  git -C "$r" add -A
  git -C "$r" commit -q -m existing
  adopt "$r"
  is "$(jq -c .params "$CON/.claude/kit.json")" '{"gate":"npm test","memory_root":"brain","trunk":"master"}' \
    "existing: gate, memory_root and trunk from the repo"
  kit_run apply
  is "$RC" 1 "existing: apply stops on the repo's own skill"
  like "$OUT" '^REFUSE \.claude/skills/merge-to-main/SKILL\.md: exists and is not rendered by the kit' "existing: the REFUSE line"
  kit_run apply --discard
  is "$RC" 1 "existing: then the check finds the broad git entry"
  like "$OUT" '^FORBID Bash\(git \*\) in permissions\.allow \(core\)' "existing: the FORBID line"
  jq '.permissions.allow -= ["Bash(git *)"]' "$CON/.claude/settings.json" > "$T/s.json"
  cp "$T/s.json" "$CON/.claude/settings.json"
  kit_run apply
  is "$RC" 0 "existing: apply passes once that entry is gone"
  is "$(jq '.permissions.allow | index("Bash(make test)") != null' "$CON/.claude/settings.json")" true \
    "existing: the repo's own entries stay"
  is "$(grep -c 'MEMORY\.md' "$CON/CLAUDE.md")" 1 "existing: CLAUDE.md keeps its one import"
  git -C "$CON" add -A
  git -C "$CON" commit -q -m "Adopt claude-kit"
  is "$(git -C "$CON" status --porcelain)" "" "existing: the commit leaves nothing behind"
  is "$(git -C "$CON" ls-files brain/friction/.gitkeep)" brain/friction/.gitkeep "existing: the memory folder outside .claude is committed"
}

t_fresh
t_hugo
t_mounted
t_existing
done_testing
