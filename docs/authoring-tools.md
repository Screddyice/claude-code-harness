# Authoring tools

The Claude harness uses two layers for document work:

- The Gstack skills `document-generate`, `document-release`, and `make-pdf` cover
  Markdown and PDF workflows.
- The official `carbone-skill` plugin covers DOCX, XLSX, PPTX, PDF, and reusable
  templates from structured data.

Install the format and template skill from the configured Claude marketplace:

```bash
claude plugin install carbone-skill@claude-plugins-official
```

Restart Claude Code after installation so it reloads the plugin registry. The plugin
does not include credentials or external account connections.
