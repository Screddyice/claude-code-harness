# Local marketplace stub

This directory is a placeholder showing the structure of a local plugin marketplace
that Claude Code can load via `extraKnownMarketplaces` in `~/.claude/settings.json`.

To use:

1. Copy this directory somewhere persistent on your machine (e.g.
   `~/projects/local-marketplaces/my-local/`).
2. Add an entry to your `~/.claude/settings.json`:

   ```json
   "extraKnownMarketplaces": {
     "my-local": {
       "source": {
         "source": "directory",
         "path": "/Users/you/projects/local-marketplaces/my-local"
       },
       "autoUpdate": true
     }
   }
   ```

3. Drop your own plugin directories under `plugins/` and reference them in
   `marketplace.json`.

Use a local marketplace when you want to install in-house plugins on your own machine
without publishing them to a public registry.
