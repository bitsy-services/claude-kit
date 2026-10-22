#!/usr/bin/env bash
# kit selftest's lints. The real kit gives no LINT line; one planted
# violation per lint, in a copy of the kit's bin/, lib/ and slices/, gives
# exactly its LINT line. A copy has no test/run.sh, so selftest runs only the
# lints there (R3).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
t_setup
# Keep every scratch dir the kit makes inside $T, which the harness removes.
mkdir -p "$T/tmp"
export TMPDIR="$T/tmp"
N=0

# fresh: a new copy of the kit in $K, a git work tree with nothing committed.
fresh() {
  N=$((N + 1))
  K="$T/k$N"
  mkdir -p "$K"
  cp -R "$TEST_ROOT/bin" "$TEST_ROOT/lib" "$TEST_ROOT/slices" "$K/"
  git -C "$K" init -q -b main
}

# selftest [args]: run bin/kit selftest in $K. LINTS holds its LINT lines.
selftest() {
  OUT="$(cd "$K" && bash "$K/bin/kit" selftest "$@" 2>&1)" && RC=0 || RC=$?
  LINTS="$(printf '%s\n' "$OUT" | grep '^LINT ' || true)"
}

# planted <label> <line>: selftest in $K finds exactly the one LINT <line>.
planted() {
  selftest
  is "$LINTS" "$2" "$1: the LINT line"
  is "$RC" 1 "$1: selftest exits 1"
  like "$OUT" '^selftest: 1 problems$' "$1: one problem"
}

# json_edit <file> <jq program>: rewrite a JSON file in place.
json_edit() {
  jq "$2" "$1" > "$1.new"
  mv "$1.new" "$1"
}

t_clean_copy() {
  fresh
  selftest
  is "$LINTS" "" "clean: the real slices give no LINT line"
  is "$RC" 0 "clean: selftest exits 0"
  like "$OUT" '^NOTICE no test suite at test/run\.sh$' "clean: no test suite is a notice (R3)"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "selftest: ok" "clean: ends with selftest: ok"
}

# The whole kit repo as it stands, test/ and the fixtures included.
t_real_root() {
  local out rc
  out="$(
    for f in "$TEST_ROOT"/lib/*.sh; do . "$f"; done
    selftest_lints "$TEST_ROOT"
  )" && rc=0 || rc=$?
  is "$out" "" "real root: no LINT line"
  is "$rc" 0 "real root: selftest_lints returns 0"
}

t_syntax() {
  fresh
  printf '#!/usr/bin/env bash\nif then\n' > "$K/slices/core/hooks/bad.sh"
  selftest
  like "$LINTS" '^LINT syntax slices/core/hooks/bad\.sh: line 2: syntax error' "syntax: the LINT line"
  is "$(printf '%s\n' "$LINTS" | grep -c '^LINT')" 1 "syntax: one LINT line"
  is "$RC" 1 "syntax: selftest exits 1"
}

t_voice() {
  fresh
  printf '# Extra\n\nDownstream repos read this.\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted voice "LINT voice slices/hugo-wiki/rules/extra.md: line 3: Downstream"
}

t_public() {
  fresh
  printf '# Extra\n\nNotes live in /home/someone/notes.\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted public "LINT public slices/hugo-wiki/rules/extra.md: line 3: /home/"
}

# R19: every file but LICENSE and test/, tracked or not yet added; an
# ignored file is not the kit's.
t_public_scope() {
  fresh
  printf 'Mail a.person@example.org.\n' > "$K/README.md"
  printf 'Copyright a.person@example.org\n' > "$K/LICENSE"
  mkdir -p "$K/test" "$K/notes"
  printf 'git@github.com:someone/x.git\n' > "$K/test/x.md"
  printf 'notes/\n' > "$K/.gitignore"
  printf '/home/someone\n' > "$K/notes/a.md"
  git -C "$K" add README.md
  planted "public scope" "LINT public README.md: line 1: a.person@example.org"
}

t_public_git_url() {
  fresh
  printf '# x\n# clone git@github.com:someone/x.git\n' > "$K/lib/zz.sh"
  planted "public git@" "LINT public lib/zz.sh: line 2: git@github.com"
}

t_frontmatter_flow() {
  fresh
  printf -- '---\npaths: ["**"]\n---\n\n# Extra\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted "frontmatter flow" \
    'LINT frontmatter slices/hugo-wiki/rules/extra.md: line 2: paths "**" matches every file; an always-on rule has no paths'
}

t_frontmatter_block() {
  fresh
  printf -- "---\npaths:\n  - \"**/*.md\"\n  - '**'\n---\n\n# Extra\n" > "$K/slices/hugo-wiki/rules/extra.md"
  planted "frontmatter block" \
    'LINT frontmatter slices/hugo-wiki/rules/extra.md: line 4: paths "**" matches every file; an always-on rule has no paths'
}

t_frontmatter_globs() {
  fresh
  printf -- '---\nglobs: "*.md"\n---\n\n# Extra\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted "frontmatter globs" 'LINT frontmatter slices/hugo-wiki/rules/extra.md: line 2: globs: is forbidden; use paths'
}

t_frontmatter_unclosed() {
  local i
  fresh
  {
    printf -- '---\n'
    for i in $(seq 1 35); do printf 'k%s: v\n' "$i"; done
    printf -- '---\n\n# Extra\n'
  } > "$K/slices/hugo-wiki/rules/extra.md"
  planted "frontmatter unclosed" 'LINT frontmatter slices/hugo-wiki/rules/extra.md: frontmatter is not closed within 30 lines'
}

t_frontmatter_line() {
  fresh
  printf -- '---\ntitle = "x"\n---\n\n# Extra\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted "frontmatter line" \
    'LINT frontmatter slices/hugo-wiki/rules/extra.md: line 2: not "key: value", a list item or blank'
}

# A link may target what its own slice or a required slice renders, or
# repo.md; code, URLs and anchors are not links to check.
t_links() {
  fresh
  cat > "$K/slices/session-branch/rules/extra.md" <<'EOF'
# Extra

- [repo](../repo.md), [rules](session-branches.md) and [memory](memory.md)
- [skill](../../skills/merge-to-main/SKILL.md#steps), [top](#extra) and [web](https://example.org/x.md)
- `[code](nowhere.md)`

```
[fenced](nowhere.md)
```

- [wiki](wiki-content.md)
EOF
  planted links \
    'LINT links slices/session-branch/rules/extra.md: wiki-content.md resolves to .claude/rules/kit/wiki-content.md, which neither session-branch nor a slice it requires renders'
}

t_fragment_top() {
  fresh
  json_edit "$K/slices/hugo-wiki/settings.json" '. + {model: "opus"}'
  planted "fragment-keys top" 'LINT fragment-keys slices/hugo-wiki/settings.json: top-level key "model"'
}

t_fragment_permissions() {
  fresh
  json_edit "$K/slices/hugo-wiki/settings.json" '.permissions.defaultMode = "plan"'
  planted "fragment-keys permissions" 'LINT fragment-keys slices/hugo-wiki/settings.json: permissions key "defaultMode"'
}

t_json_settings() {
  fresh
  printf '{\n' > "$K/slices/hugo-wiki/settings.json"
  planted "json settings" 'LINT json slices/hugo-wiki/settings.json: not valid JSON'
}

# A slice.json that does not parse is reported once, not again as every
# parameter its files use.
t_json_slice() {
  fresh
  printf '[]\n' > "$K/slices/hugo-wiki/slice.json"
  planted "json slice" 'LINT json slices/hugo-wiki/slice.json: not a JSON object'
}

# Only core rules without paths count, each with its stamp line.
t_core_budget() {
  local i
  fresh
  rm "$K"/slices/core/rules/*.md
  for i in $(seq 1 149); do printf 'line %s\n' "$i"; done > "$K/slices/core/rules/long.md"
  {
    printf -- '---\npaths:\n  - "**/*.x"\n---\n'
    for i in $(seq 1 200); do printf 'line %s\n' "$i"; done
  } > "$K/slices/core/rules/scoped.md"
  selftest
  is "$LINTS" "" "core-budget: 150 rendered lines is within the budget"
  printf 'one more\n' >> "$K/slices/core/rules/long.md"
  planted core-budget 'LINT core-budget slices/core/rules: always-on rules render to 151 lines, over the budget of 150'
}

t_undeclared_param() {
  fresh
  printf '# Extra\n\nThe trunk is {{kit.trunk}}.\n' > "$K/slices/hugo-wiki/rules/extra.md"
  planted undeclared-param \
    'LINT undeclared-param slices/hugo-wiki/rules/extra.md: {{kit.trunk}} is declared by neither hugo-wiki nor a slice it requires'
}

t_param_no_pattern() {
  fresh
  json_edit "$K/slices/hugo-wiki/slice.json" 'del(.params.wiki_dir.pattern)'
  planted "param-pattern missing" 'LINT param-pattern slices/hugo-wiki/slice.json: wiki_dir has no pattern'
}

t_param_loose_pattern() {
  fresh
  json_edit "$K/slices/hugo-wiki/slice.json" '.params.wiki_dir.pattern = "^[A-Za-z|]+$"'
  planted "param-pattern loose" "LINT param-pattern slices/hugo-wiki/slice.json: wiki_dir's pattern accepts \"|\""
}

t_gitmodules() {
  fresh
  : > "$K/.gitmodules"
  planted gitmodules 'LINT gitmodules .gitmodules: the kit has no submodules'
}

t_rm_r() {
  fresh
  printf '# helpers\n# then: rm -rf "$tmp"\n' > "$K/lib/zz.sh"
  planted rm-r 'LINT rm-r lib/zz.sh: line 2: rm -rf'
}

# R10: only lib/common.sh's scratch_cleanup may use find's delete action.
t_rm_delete() {
  fresh
  printf '# then: find "$d" -delete\n' > "$K/lib/zz.sh"
  planted "rm-r delete" 'LINT rm-r lib/zz.sh: line 1: -delete'
}

t_skill_name() {
  local f
  fresh
  f="$K/slices/core/skills/kit/SKILL.md"
  sed 's/^name: kit$/name: kits/' "$f" > "$f.new"
  mv "$f.new" "$f"
  planted "skill-frontmatter name" \
    'LINT skill-frontmatter slices/core/skills/kit/SKILL.md: name is "kits", not the directory name "kit"'
}

t_skill_description() {
  local f
  fresh
  f="$K/slices/core/skills/kit/SKILL.md"
  grep -v '^description:' "$f" > "$f.new"
  mv "$f.new" "$f"
  planted "skill-frontmatter description" 'LINT skill-frontmatter slices/core/skills/kit/SKILL.md: description is missing'
}

# R33: nothing under test/ may load as instructions in a session that reads
# it. One line per .claude directory, however many files it holds; the
# stored names dot-claude and CLAUDE.md.in pass.
t_instruction_dir() {
  local x
  fresh
  x="$K/test/fixtures/x"
  mkdir -p "$x/expected/.claude/rules" "$x/files/dot-claude"
  printf 'rule\n' > "$x/expected/.claude/rules/a.md"
  printf '{}\n' > "$x/expected/.claude/settings.json"
  printf 'note\n' > "$x/files/dot-claude/m.md"
  printf '@m.md\n' > "$x/CLAUDE.md.in"
  planted "instruction-source dir" \
    'LINT instruction-source test/fixtures/x/expected/.claude: a .claude directory under test/ can load into a session that reads files here; store it as dot-claude'
}

t_instruction_file() {
  fresh
  mkdir -p "$K/test/consumers/y"
  printf '@.claude/memory/MEMORY.md\n' > "$K/test/consumers/y/CLAUDE.md"
  planted "instruction-source file" \
    'LINT instruction-source test/consumers/y/CLAUDE.md: a CLAUDE.md under test/ can load into a session that reads files here; store it as CLAUDE.md.in'
}

# selftest counts a failing suite as one problem, after the lints.
t_suite() {
  fresh
  mkdir -p "$K/test"
  printf 'echo suite ran\n' > "$K/test/run.sh"
  selftest
  is "$RC" 0 "suite: a passing suite exits 0"
  like "$OUT" '^suite ran$' "suite: test/run.sh ran"
  unlike "$OUT" '^NOTICE' "suite: no notice when the suite exists"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "selftest: ok" "suite: ends with selftest: ok"
  printf 'exit 1\n' > "$K/test/run.sh"
  selftest
  is "$RC" 1 "suite: a failing suite exits 1"
  like "$OUT" '^TESTS test/run\.sh failed$' "suite: says the suite failed"
  is "$(printf '%s\n' "$OUT" | tail -n 1)" "selftest: 1 problems" "suite: a failing suite is one problem"
}

t_usage() {
  fresh
  selftest extra
  is "$RC" 2 "usage: an argument exits 2"
}

t_clean_copy
t_real_root
t_syntax
t_voice
t_public
t_public_scope
t_public_git_url
t_frontmatter_flow
t_frontmatter_block
t_frontmatter_globs
t_frontmatter_unclosed
t_frontmatter_line
t_links
t_fragment_top
t_fragment_permissions
t_json_settings
t_json_slice
t_core_budget
t_undeclared_param
t_param_no_pattern
t_param_loose_pattern
t_gitmodules
t_rm_r
t_rm_delete
t_skill_name
t_skill_description
t_instruction_dir
t_instruction_file
t_suite
t_usage
done_testing
