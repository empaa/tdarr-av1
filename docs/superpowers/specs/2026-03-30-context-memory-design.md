# Context & Memory Design

**Date:** 2026-03-30
**Status:** Approved

## Problem

Two pain points before development begins:

1. Claude loading too much context for simple, focused sessions
2. Claude lacking architectural awareness to make suggestions that fit the project

## Approach: Tiered context

### CLAUDE.md (always loaded, ~40 lines)
- What the project is and what the two output images are
- Explicit pointers telling Claude which doc to read before working in each area
- Reminder to check memory for user feedback

### docs/ (load on demand)
- `docs/constraints.md` — component version locks and why they exist. Read before touching Dockerfile.
- `docs/architecture.md` — image structure, stack layout, plugin integration. Read before feature work.
- `docs/build-and-publish.md` — local build commands, GHCR publish workflow, tagging. Read before CI/build work.

All three files start empty and are filled in as the project is built. This ensures decisions are documented at the time they are made, not reverse-engineered from old code.

### Memory system (persisted across sessions)
- `feedback` type — corrections and confirmations from the user, so Claude does not repeat mistakes or abandon validated approaches
- `user` type — user preferences and working style
- `project` type — key decisions, scope changes, blockers

### No custom skills or hooks at this stage
The project scope is contained (two Dockerfiles, a build script, one plugin). Custom skills are worth adding only when a recurring multi-step workflow emerges. This will be re-evaluated as development progresses.

## Key principle

`old_resources/` is reference material only. It must not bias design decisions. Architecture and constraints are determined fresh during development and documented in `docs/` at the time decisions are made.
