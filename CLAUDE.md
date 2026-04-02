# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

Two Docker images that extend the official Tdarr images with a compiled AV1 encoding stack (av1an + ab-av1 + dependencies):

- `ghcr.io/empaa/tdarr` — extends `ghcr.io/haveagitgat/tdarr`
- `ghcr.io/empaa/tdarr_node` — extends `ghcr.io/haveagitgat/tdarr_node`

The goal is deployable images usable directly with `docker run`, with av1an and ab-av1 available inside the container for use by Tdarr plugins.

## Load these docs before working in specific areas

- **Dockerfile or component versions** → read `docs/constraints.md` first
- **Image structure, stack layout** → read `docs/architecture.md` first
- **Building locally or publishing to GHCR** → read `docs/build-and-publish.md` first

## Git hooks

A pre-commit hook that blocks files over 10 MB lives in `hooks/pre-commit`. Install it once per clone:

```bash
cp hooks/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

## Binary paths provided by these images

Plugins in the sibling `tdarr-plugins` repo depend on these paths at runtime:

- `/usr/local/bin/av1an`
- `/usr/local/bin/ab-av1`
- `/usr/local/bin/ffmpeg`
- `/usr/local/bin/mkvmerge`
- `/usr/local/bin/vspipe`
- `/usr/local/share/vmaf/vmaf_v0.6.1.json`

If any of these paths change, message the sibling repo.

## Memory

User feedback and preferences are tracked in the memory system and should inform all suggestions. Check memory at the start of sessions.

## Sibling Protocol

This repo is part of a two-repo project. The sibling repo is at `../tdarr-plugins` (Tdarr FlowPlugins for AV1 encoding).

### Inbox

Agent-to-agent async messages between repos. Check your inbox at session start.

- Own inbox: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/`
- Sibling inbox: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/`

Message format (one file per message, `YYYY-MM-DD-from-<repo>-<slug>.md`):

    ---
    from: <repo-name>
    date: YYYY-MM-DD
    ---

    <precise description of what changed and what it affects>

Lifecycle:
1. Session start: read own inbox, summarize to user, clear after acknowledgment
2. Session end: if work affects sibling, write message to sibling inbox
3. User can also say "tell <sibling> that..." to write manually

### When to Message

- Binary path or version changes
- Deploy path or config structure changes
- Breaking changes affecting sibling
- New dependencies or removed features

### Test instance plugin path

The sibling's `build.sh --deploy` copies bundled plugins to:
`test/tdarr_config/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins/`
