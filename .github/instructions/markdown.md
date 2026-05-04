---
applyTo: "**/*.md, **/*.mdx"
---

Refer to `skills/markdown/SKILL.md` for the full Markdown formatting standards.

Key rules to always apply:

- **No H1 headings** — the title is generated from front matter; start content at `##`
- Use headings hierarchically; restructure if you reach H4, avoid H5+
- Fenced code blocks must specify a language for syntax highlighting
- Line length max 120 characters; use soft line breaks for long paragraphs
- Use `-` for bullet points, `1.` for numbered lists; indent nested lists with two spaces
- Include YAML front matter with required metadata fields at the top of every file
- **Post-edit verification**: run `npx markdownlint-cli2 <file>` and fix all errors before finishing
