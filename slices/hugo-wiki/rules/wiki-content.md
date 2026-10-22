# Wiki content

- Start a page body with `##` sections, never a `# H1`. A page's title is its frontmatter `title`, by convention: the pinned hugo-book theme renders no page h1 itself (its `single.html` is a stub, and the title appears as an h3 in `_partials/docs/header.html`), and a site that wants an h1 renders `title` in its own layout. A body H1 duplicates the title.
- Explain a term, name or detail before or alongside its first use, never in a later section.
- Show a repeated pattern in full once; later examples show only what differs.
