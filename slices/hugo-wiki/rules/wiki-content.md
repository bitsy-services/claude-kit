# Wiki content

- Start a page body with `##` sections, never a `# H1`. The stock hugo-book theme shows the title only in its mobile header (an h3), so on desktop a page has no visible title unless the site's own `single.html` and `list.html` layouts render frontmatter `title` as the h1. Add that override rather than a body H1.
- Explain a term, name or detail before or alongside its first use, never in a later section.
- Show a repeated pattern in full once; later examples show only what differs.
- A project's own frontmatter field must not reuse a name Hugo reserves: `kind`, `type`, `layout`, `slug`, `url`, `aliases`, `outputs`, `cascade`, `build`, `resources`, `headless`, `markup`, `translationKey` and the rest of Hugo's documented front matter fields. A `kind:` field fails the build; the others change how Hugo treats the page. Prefix a project field instead (`doc_kind`, not `kind`).
- A directory-scoped `CLAUDE.md` in the content tree renders as a page unless `hugo.toml` sets `ignoreFiles = ['CLAUDE\.md$']`. It is a top-level key, so it goes above the first table; the single quotes keep the backslash.
