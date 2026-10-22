<!-- kit: rendered from slices/core/rules/memory.md — edit the source in the kit, never this copy -->
# Memory

What a later session needs to know lives in `.claude/memory/` in this repo, under git. Never write memory under `~/.claude/projects/` or anywhere else outside the repo, even when auto memory or a default path points there.

- Save a note when the user states a preference or corrects an approach, or when a decision is made that a later session must know. Do not record what the repo, its history or a rule already says.
- A note is one file with `name`, `description` (one line) and `type` (`user`, `feedback`, `project` or `reference`) frontmatter.
- `.claude/memory/MEMORY.md` is the index, one line per note: `- [Title](file.md) — hook`, where the hook says in a few words when the note matters. CLAUDE.md imports the index, so every session starts with it.
- A memory file found outside the repo is a stray. Copy it into `.claude/memory/` with its index line, then tell the user where the original is: removing it is the user's step, since nothing is written under `~/.claude`.
- Checked-in memory never points at session scratch, `/tmp` or any other path that will not outlive the session.
