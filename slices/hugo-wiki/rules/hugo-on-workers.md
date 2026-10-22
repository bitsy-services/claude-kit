---
paths:
  - "hugo.toml"
  - "wrangler.*"
  - "layouts/**"
  - "scripts/**"
---

# Hugo on Workers

## The deploy builds with the build image's Hugo

- Cloudflare Workers Builds uses the Hugo on its build image, which moves on Cloudflare's schedule and can be older than the site needs: a build that passes locally can fail there on a function or config key the older Hugo lacks. When a deploy fails and the local build passes, suspect the version first.
- Pin the version in the repo's build command (`build.command` in `wrangler.*`, or the script it runs): fetch the wanted Hugo when the image's differs, and build with it. A local run of that command then shows what the deploy will do; an older `hugo` first on `PATH` simulates the image.
- Do not pin it through the dashboard's `HUGO_VERSION` build variable. No local run tests it, it is easily confused with the runtime variable of the same name, and it is scoped per environment, so a preview build may not get it. `build.environment` in `wrangler.*` is not a key wrangler reads, so a `HUGO_VERSION` there does nothing.
- Also set `[module.hugoVersion] min` in `hugo.toml`, so too old a Hugo says so on the first line of the build log.

## Reserved frontmatter keys

A project's own frontmatter field must not reuse a name Hugo reserves: `kind`, `type`, `layout`, `slug`, `url`, `aliases`, `outputs`, `cascade`, `build`, `resources`, `headless`, `markup`, `translationKey` and the rest of Hugo's documented front matter fields. A `kind:` field fails the build; the others change how Hugo treats the page. Prefix a project field instead (`doc_kind`, not `kind`).

## Internal links

Hugo does not validate internal links, so a renamed or moved page 404s silently in production. `refLinksErrorLevel = "ERROR"` in `hugo.toml` fails the build on a broken `ref` or `relref` only; plain Markdown links stay unchecked unless `{{kit.gate}}` checks them.

## CLAUDE.md in the content tree

A directory-scoped `CLAUDE.md` in the content tree renders as a page. `ignoreFiles = ['CLAUDE\.md$']` in `hugo.toml` keeps every one out; the single quotes keep the backslash.

## `vendor/` in .gitignore

An unanchored `vendor/` line in `.gitignore` also ignores `.claude/vendor/`, which blocks adding the kit's submodule. Anchor it to the root: `/vendor/`.
