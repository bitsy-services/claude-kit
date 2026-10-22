# Self-improvement

## Friction

Signs of friction:
- The user repeats, rephrases or corrects a request or an assumption.
- The user shows frustration or impatience.
- A task takes several rounds where one should have done.
- The user rejects a tool call or a permission prompt.
- The output is too long or too short, or pitched at the wrong level of detail.

When you notice friction, write a `feedback` note in `{{kit.memory_root}}/friction/` with a hypothesis of the root cause and enough context to test it later. Prefix the filename with its scope:
- `global-`: would hold in any repo.
- `project-`: specific to this repo.
- `topic-`: a narrow subject within this repo.

Write none for a misunderstanding cleared up at once and unlikely to recur, or for friction from outside causes such as a slow network or a tool bug.

## Gen 0 → Gen 1 → Gen 2

- **Gen 0, friction notes:** one per event, cheap to write.
- **Gen 1, patterns,** in `{{kit.memory_root}}/patterns/`: when 2–3 related friction notes accumulate, merge them into one pattern, with the same prefix, that names the recurring issue and the emerging rule. Delete the consumed notes and their index lines.
- **Gen 2, rules:** when a pattern has held across several conversations, propose promoting it.
  - A `project-` or `topic-` pattern becomes a rule in this repo's `.claude/rules/`, outside `.claude/rules/kit/`, once the user confirms. A `topic-` rule gets a file for its topic.
  - A `global-` pattern becomes a proposed kit change, made through the `kit` skill's change flow. Paraphrase it: the kit is public, so its text quotes and names no one.
  - Delete the pattern and its index line once its rule is in place or its kit change lands.

## When

At the end of a substantial conversation, in one batch with any other memory writes, and whenever the user asks to review friction or patterns:
- write the friction notes the conversation warrants;
- merge any cluster that is ready into a pattern;
- drain the prompt log.

## The prompt log

A hook appends a line for each permission prompt to `{{kit.memory_root}}/friction/project-prompt-log.md`. It is a working file, not a memory note: no frontmatter, no index line, never merged into a pattern. Draining empties it:
- Delete every line for a write under `.claude/` at once, and tell the user so in one sentence: no allow entry stops those prompts.
- For each remaining line, propose the exact allow entry that covers it under `permissions.md`, or none if it should keep prompting, and delete the line once the user has decided.
