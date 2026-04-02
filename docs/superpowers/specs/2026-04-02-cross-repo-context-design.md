# Cross-Repo Context Design

**Date:** 2026-04-02
**Status:** Approved

## Problem

Two repos (`tdarr-av1` and `tdarr-plugins`) are developed by the same person with
Claude Code, often in alternating sessions. Work in one repo frequently affects the
other (binary versions, paths, flags). Currently only `tdarr-av1` has Claude context.
`tdarr-plugins` has none, and there is no mechanism for sessions in one repo to pass
context to the other.

## Solution

1. Give each repo its own CLAUDE.md, memory, and docs.
2. Add an agent-to-agent inbox system for passing precise, ephemeral messages between
   repos via Claude's project directory structure.
3. Define a lightweight integration protocol in both CLAUDE.md files so each repo
   knows what the other depends on.

## Inbox System

### Location

```
~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/
~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/
```

### Message Format

Agent-to-agent — optimized for precision and low token usage, not human readability.

```markdown
---
from: tdarr-plugins
date: 2026-04-02
---

av1anEncode now depends on FFmpeg `--enable-libsvtav1` >= 2.3.0 for the
`--enable-libsvtav1-grain` flag. Affects: Dockerfile build-ffmpeg stage
configure flags.
```

One file per message. Filename: `YYYY-MM-DD-from-<repo>-<slug>.md`.

### Lifecycle

1. **Write:** At session end, Claude detects cross-repo impact and writes to the
   other repo's inbox. Or the user says "tell tdarr-av1 that..." and Claude writes
   it directly.
2. **Read:** At session start, Claude checks its own inbox. If messages exist, it
   summarizes each one to the user before starting work.
3. **Clear:** After summarizing, Claude deletes the consumed message files. If the
   user corrects the understanding, Claude adjusts before clearing.

### When to Write Messages

- Changes to binary paths or version requirements
- Changes to deploy paths or config structure
- Breaking changes that affect the other repo
- New dependencies or removed features

## Integration Protocol

Both CLAUDE.md files include an identical "Sibling Protocol" block.

### tdarr-av1 Declares

- Binary paths plugins depend on: `/usr/local/bin/av1an`, `/usr/local/bin/ab-av1`,
  `/usr/local/bin/ffmpeg`, `/usr/local/bin/mkvmerge`, `/usr/local/bin/vspipe`
- VMAF model path: `/usr/local/share/vmaf/vmaf_v0.6.1.json`
- Test instance config path: `test/tdarr_config/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins/`
- Sibling repo location: `../tdarr-plugins`

### tdarr-plugins Declares

- Deploy target path (relative to sibling `tdarr-av1`)
- Binary paths assumed to exist at runtime
- Sibling repo location: `../tdarr-av1`

### Shared Sibling Protocol Block

Included identically in both CLAUDE.md files:

```markdown
## Sibling Protocol

This repo is part of a two-repo project. The sibling repo is at `../<sibling>`.

### Inbox

Agent-to-agent async messages between repos. Check your inbox at session start.

- Own inbox: `~/.claude/projects/<this-project-path>/inbox/`
- Sibling inbox: `~/.claude/projects/<sibling-project-path>/inbox/`

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
```

## CLAUDE.md Updates

### tdarr-av1/CLAUDE.md

Update existing file to add:
- Sibling protocol block
- Integration protocol (binary paths, test instance path)
- Inbox check/write instructions

### tdarr-plugins/CLAUDE.md (new)

Create with:
- Project description (esbuild-bundled FlowPlugins for Tdarr)
- Docs references (similar pattern to tdarr-av1)
- Integration protocol (deploy target, runtime binary dependencies)
- Sibling protocol block

## Memory Migration

### tdarr-av1 Memory

- `feedback_old_resources.md` — stays (specific to this repo)
- `feedback_git_staging.md` — stays
- `user_profile.md` — stays
- `project_status.md` — rewrite to reflect plugins moved out, stack-only focus

### tdarr-plugins Memory (new)

Create `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/`:

- `MEMORY.md` — new index
- `user_profile.md` — copy from tdarr-av1 (same user, same preferences)
- `feedback_git_staging.md` — copy from tdarr-av1 (same rule applies)
- `project_status.md` — new, reflecting initial setup state
