# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this?

Two Docker images that extend the official Tdarr images with a compiled AV1 encoding stack (av1an + ab-av1 + dependencies):

- `ghcr.io/empaa/tdarr` — extends `ghcr.io/haveagitgat/tdarr`
- `ghcr.io/empaa/tdarr_node` — extends `ghcr.io/haveagitgat/tdarr_node`

The goal is deployable images usable directly with `docker run`, with av1an and ab-av1 available inside the container for use by Tdarr plugins.

## Load these docs before working in specific areas

- **Dockerfile or component versions** → read `docs/constraints.md` first
- **Image structure, stack layout, plugin integration** → read `docs/architecture.md` first
- **Building locally or publishing to GHCR** → read `docs/build-and-publish.md` first

## Git hooks

A pre-commit hook that blocks files over 10 MB lives in `hooks/pre-commit`. Install it once per clone:

```bash
cp hooks/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

## Memory

User feedback and preferences are tracked in the memory system and should inform all suggestions. Check memory at the start of sessions.
