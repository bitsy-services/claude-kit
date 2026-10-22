---
paths:
  - "**/hugo.toml"
  - "**/wrangler.*"
  - "**/layouts/**"
  - "**/scripts/**"
---
<!-- kit: rendered from slices/hugo-wiki/rules/hugo-on-workers.md — edit the source in the kit, never this copy -->

# Hugo on Workers

- Cloudflare Workers Builds uses the Hugo on its build image, which moves on Cloudflare's schedule and can be older than the site needs: a build that passes locally can fail there on a function or config key the older Hugo lacks. When a deploy fails and the local build passes, suspect the version first.
- Pin the version in the repo's build command (`build.command` in `wrangler.*`, or the script it runs): fetch the wanted Hugo when the image's differs, and build with it. A local run of that command then shows what the deploy will do; an older `hugo` first on `PATH` simulates the image.
- Do not pin it through the dashboard's `HUGO_VERSION` build variable. No local run tests it, it is easily confused with the runtime variable of the same name, and it is scoped per environment, so a preview build may not get it. `build.environment` in `wrangler.*` is not a key wrangler reads, so a `HUGO_VERSION` there does nothing.
- Also set `[module.hugoVersion] min` in `hugo.toml`, so too old a Hugo says so on the first line of the build log.
