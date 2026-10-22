# Wiki linking

- Link richly between the pages under `{{kit.wiki_dir}}/`. A link in body text points to another page there, not to an external site.
- When a link target does not exist yet, create it as a stub: the frontmatter its sibling pages carry, and a body of external references (docs, Wikipedia, blog posts) on the topic.
- Link a domain-specific term on its first mention in a page only; later mentions stay plain text.
- When a concept is a narrow subtopic of a broader page, link to the section that covers it.
- A renamed or moved page breaks the links to it. Hugo fails the build on a broken `ref` or `relref` (unless `refLinksErrorLevel` is lowered to `WARNING`) but never checks a plain Markdown link. hugo-book's `BookPortableLinks = "error"` fails the build on a Markdown link to a missing page, but it resolves links as content paths: it reports a URL-relative link such as `../page/` as missing, and a `relref` inside a link breaks. Without it, `{{kit.gate}}` must check links.
