# This repository is public. Everything below either carries credentials
# or is machine-local noise that should not be published.

# MCP server config. Written by `claude mcp add -s project` and by the
# 21st.dev CLI, and can contain API keys in plaintext headers.
.mcp.json

# Credentials
.env
.env.*
*.pem
*.key
secrets.json

# Local Claude Code state, specific to one machine
.claude/settings.local.json

# Tool logs, written into whatever directory the CLI is run from
vibe-session.log

# Dependencies and build output
node_modules/
dist/
build/
.next/

# Python bytecode
__pycache__/
*.py[cod]

# OS noise
.DS_Store
Thumbs.db

# Working notes from a build session — plans, review diffs, reports and
# screenshots. Machine-local scratch, not the masjid's website. It was
# committed once by accident on 29 September (a `git add -A`) and would have
# published 2.6 MB of internal notes to a public repository.
.superpowers/
