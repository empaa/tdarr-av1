# Cross-Repo Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up Claude Code context for both repos with an agent-to-agent inbox system, integration protocol, and migrated memories.

**Architecture:** Each repo gets its own CLAUDE.md and memory. Both CLAUDE.md files include an identical sibling protocol block defining inbox paths, message format, and lifecycle. Inbox directories live in Claude's project config dirs.

**Tech Stack:** Markdown files, Claude Code memory system

---

## File Structure

```
tdarr-av1/
  CLAUDE.md                                          # Update: add sibling protocol + integration

tdarr-plugins/
  CLAUDE.md                                          # Create: project description + sibling protocol

~/.claude/projects/-...-tdarr-av1/
  inbox/                                             # Create: empty directory
  memory/
    project_status.md                                # Update: reflect plugins moved out
    MEMORY.md                                        # Update: fix stale project_status description

~/.claude/projects/-...-tdarr-plugins/
  inbox/                                             # Create: empty directory
  memory/
    MEMORY.md                                        # Create: index
    user_profile.md                                  # Create: copy from tdarr-av1
    feedback_git_staging.md                          # Create: copy from tdarr-av1
    project_status.md                                # Create: new, initial plugin repo state
```

---

### Task 1: Create tdarr-plugins CLAUDE.md

**Files:**
- Create: `~/ClaudeProjects/tdarr-plugins/CLAUDE.md`

- [ ] **Step 1: Create CLAUDE.md**

Create `~/ClaudeProjects/tdarr-plugins/CLAUDE.md` with this content:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

AV1 encoding FlowPlugins for Tdarr, bundled with esbuild into self-contained single-file plugins.

- **av1anEncode** — scene-based chunked AV1 encoding via av1an (aomenc or SVT-AV1)
- **abAv1Encode** — automatic VMAF-targeted CRF search via ab-av1 (SVT-AV1)

Shared modules in `src/shared/` are inlined by esbuild at build time. Each plugin in `dist/` is a single `index.js` with no external dependencies beyond Node builtins.

## Build

```bash
npm install          # once
npm run build        # bundle plugins to dist/
npm run deploy       # build + copy to tdarr-av1 test instance
```

## Project structure

- `src/shared/` — shared modules (logger, processManager, encoderFlags, downscale, audioMerge, progressTracker)
- `src/<pluginName>/index.js` — plugin source, imports from `../shared/`
- `dist/LocalFlowPlugins/<pluginName>/1.0.0/index.js` — bundled output (gitignored)
- `build.sh` — esbuild bundler, `--deploy` copies to test instance
- `.github/workflows/release.yml` — builds + creates GitHub Release on push to main

## Runtime binary dependencies

These binaries must exist on the Tdarr node at runtime (provided by the sibling `tdarr-av1` Docker images):

- `/usr/local/bin/av1an`
- `/usr/local/bin/ab-av1`
- `/usr/local/bin/ffmpeg`
- `/usr/local/bin/mkvmerge`
- `/usr/local/bin/vspipe`
- `/usr/local/share/vmaf/vmaf_v0.6.1.json`

## Memory

User feedback and preferences are tracked in the memory system and should inform all suggestions. Check memory at the start of sessions.

## Sibling Protocol

This repo is part of a two-repo project. The sibling repo is at `../tdarr-av1` (Docker images with the AV1 encoding stack).

### Inbox

Agent-to-agent async messages between repos. Check your inbox at session start.

- Own inbox: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/`
- Sibling inbox: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/`

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

### Deploy integration

`build.sh --deploy` copies bundled plugins to the sibling's test instance at:
`../tdarr-av1/test/tdarr_config/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins/`
```

- [ ] **Step 2: Commit**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with project context and sibling protocol"
```

---

### Task 2: Update tdarr-av1 CLAUDE.md

**Files:**
- Modify: `~/ClaudeProjects/tdarr-av1/CLAUDE.md`

- [ ] **Step 1: Rewrite CLAUDE.md**

Replace the entire contents of `~/ClaudeProjects/tdarr-av1/CLAUDE.md` with:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
cd ~/ClaudeProjects/tdarr-av1
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with sibling protocol and binary path declarations"
```

---

### Task 3: Create tdarr-plugins memory and inbox

**Files:**
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/MEMORY.md`
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/user_profile.md`
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/feedback_git_staging.md`
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/project_status.md`
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/` (empty directory)

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory
mkdir -p ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox
```

- [ ] **Step 2: Create MEMORY.md**

Create `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/MEMORY.md`:

```markdown
# Memory Index

- [User profile](user_profile.md) — Short focused sessions, outcome-oriented, not Docker/git expert
- [Never stage test/output or test/samples](feedback_git_staging.md) — Copyright risk; always stage by explicit path, never git add .
- [Project status](project_status.md) — Initial setup complete, dev branch on GitHub, not yet tested end-to-end
```

- [ ] **Step 3: Create user_profile.md**

Create `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/user_profile.md`:

```markdown
---
name: User profile
description: Emil's working style, background, and preferences for this project
type: user
---

Works in short focused sessions — typically "this is broken, fix it" or "I have an idea for this feature".

Not deeply familiar with Docker/git internals but knows exactly what end result he wants. Frame technical explanations in terms of outcomes, not mechanics.

End goal for this project: self-contained Tdarr FlowPlugins distributed via GitHub Releases, usable with the empaa/tdarr_node Docker image.
```

- [ ] **Step 4: Create feedback_git_staging.md**

Create `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/feedback_git_staging.md`:

```markdown
---
name: Never use git add on test/output or test/samples
description: Staging these directories risks committing copyrighted sample/encoded media into git history
type: feedback
---

Never run `git add test/output/` or `git add test/samples/` or `git add .` / `git add -A` in this repo. Always stage specific files by name.

**Why:** `test/output/` contains encoded video derived from copyrighted samples. Once committed, they persist in git history even after `git rm`. Scrubbing requires `git filter-repo` + force push. This happened once in the sibling tdarr-av1 repo and required a full history rewrite.

**How to apply:** Always stage with explicit paths (`git add src/av1anEncode/index.js build.sh`). If a broad `git add` is ever needed, run `git status` first and verify no media files are staged before committing.
```

- [ ] **Step 5: Create project_status.md**

Create `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/project_status.md`:

```markdown
---
name: Project status
description: Initial plugin repo setup complete, dev branch on GitHub, pending end-to-end testing
type: project
---

Repository created on 2026-04-02. Initial setup complete.

**Current state:**
- GitHub: github.com/empaa/tdarr-plugins (public)
- Only `dev` branch pushed — `main` exists locally but not pushed (to avoid triggering release workflow)
- esbuild bundles 2 plugins (av1anEncode, abAv1Encode) into self-contained single files
- `build.sh --deploy` copies to sibling tdarr-av1 test instance
- GitHub Actions release workflow ready but untriggered
- Not yet tested end-to-end in a running Tdarr instance

**Next steps:**
- Test plugins via `npm run deploy` + `build.sh --interactive` in tdarr-av1
- Once verified, push main to trigger first release
```

- [ ] **Step 6: Verify files exist**

```bash
ls -la ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/memory/
ls -la ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/
```

Expected: 4 files in memory/ (MEMORY.md, user_profile.md, feedback_git_staging.md, project_status.md), empty inbox/.

---

### Task 4: Update tdarr-av1 memory and create inbox

**Files:**
- Modify: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/memory/project_status.md`
- Modify: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/memory/MEMORY.md`
- Create: `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/` (empty directory)

- [ ] **Step 1: Create inbox directory**

```bash
mkdir -p ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox
```

- [ ] **Step 2: Update project_status.md**

Replace the entire contents of `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/memory/project_status.md` with:

```markdown
---
name: Project status
description: AV1 stack Docker images — plugins moved to separate repo, images are stack-only
type: project
---

Docker images are purely the AV1 encoding stack. Plugin development moved to sibling repo `empaa/tdarr-plugins` on 2026-04-02.

**Current state:**
- `plugins/` directory removed from this repo
- Dockerfile no longer COPYs FlowPlugins
- `build.sh --interactive` spins up test Tdarr instance at localhost:8265
- Sibling tdarr-plugins repo deploys built plugins to `test/tdarr_config/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins/`

**How to apply:** This repo only deals with Docker image building and the AV1 encoding stack. Plugin questions should be directed to the sibling repo.
```

- [ ] **Step 3: Update MEMORY.md**

Replace the entire contents of `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/memory/MEMORY.md` with:

```markdown
# Memory Index

- [old_resources is reference only](feedback_old_resources.md) — Never read old_resources/ unless user explicitly asks; it must not bias new project design
- [User profile](user_profile.md) — Short focused sessions, outcome-oriented, not Docker/git expert, wants two GHCR image tags
- [Project status](project_status.md) — AV1 stack Docker images; plugins moved to sibling tdarr-plugins repo
- [Never stage test/output or test/samples](feedback_git_staging.md) — Copyright risk; always stage by explicit path, never git add .
```

- [ ] **Step 4: Verify**

```bash
cat ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/memory/MEMORY.md
ls -la ~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/
```

---

### Task 5: Push CLAUDE.md changes

**Files:** No new files — pushing existing commits.

- [ ] **Step 1: Push tdarr-plugins dev branch**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git push origin dev
```

- [ ] **Step 2: Verify tdarr-plugins remote is up to date**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git log --oneline origin/dev -1
```

Expected: The CLAUDE.md commit is at the tip.

Note: tdarr-av1 CLAUDE.md changes are on the local dev branch. Push only if the user has previously been pushing dev to origin. Otherwise leave for the user to push.
