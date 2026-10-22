<!-- kit: rendered from slices/core/rules/tool-use.md — edit the source in the kit, never this copy -->
# Tool use

- Avoid compound statements (`;`, `&&`, `|`) in a Bash call. Make separate Bash calls instead, in parallel when they are independent, so each command is matched against the permission rules on its own.
- Use a compound statement only for a genuine dependency that separate calls cannot express.
