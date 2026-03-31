# Dev Workflow Design

**Date:** 2026-03-31
**Status:** Approved (revised)

## Problem

No development workflow or CI exists yet. Need to establish:
- How development work flows from `dev` to `main`
- A test suite that gates merges on whether the AV1 stack builds cleanly and binaries work
- Automated publishing to GHCR, triggered only by a clean merge to `main`

## Branch Strategy

- **`dev`** — all development happens here. Push freely as work progresses or when ending a session.
- **`main`** — protected. Only accepts merges via PR from `dev`. Direct pushes blocked. Merges require the test workflow to pass.

## What Gets Tested

The real health check is `Dockerfile.stack` — a multi-stage build that compiles the entire AV1 encoding stack from source (SVT-AV1, libaom, libvmaf, VapourSynth, ffmpeg, av1an, ab-av1). `Dockerfile.tdarr` and `Dockerfile.tdarr_node` are trivial wrappers that `COPY --from=ghcr.io/empaa/av1-stack:latest` — they contain no compilation and are not interesting to test independently.

## Test Workflow: `test.sh` + `test.yml`

### `test.sh` (local)

Run before opening a PR or merging. Builds `Dockerfile.stack` for linux/amd64, loads the image locally, runs binary version checks. Reports pass/fail. Mirrors GitHub CI.

```
./test.sh
```

### `test.yml` (GitHub Actions)

Failsafe in case the local test was skipped. Runs automatically on PR to main and via manual dispatch (`workflow_dispatch`).

- Builds `Dockerfile.stack` for **linux/amd64 only** (arm64 via QEMU would take hours for a full source compile)
- Runs binary version checks: `av1an`, `ab-av1`, `ffmpeg`
- Summary job named **"Tests passed"** gates the PR merge via branch protection

## `publish.yml` — GHCR release

**Triggers:** push to `main` only (fires after PR merge).

Two sequential stages:

1. **`publish-stack`** — builds `Dockerfile.stack` multi-platform (amd64+arm64) and pushes `ghcr.io/empaa/av1-stack:latest`
2. **`publish-tdarr`** — runs after `publish-stack`. Builds `Dockerfile.tdarr` and `Dockerfile.tdarr_node` multi-platform and pushes to GHCR. Sequential because the tdarr Dockerfiles `COPY --from=ghcr.io/empaa/av1-stack:latest` at build time.

## Branch Protection (GitHub Settings)

Configured on `main`:
- Require a pull request before merging (no direct pushes)
- Require the **"Tests passed"** status check to pass before merge
- No required reviewers (solo project)

## Future: Encode Test Gate

At a later stage, an actual encode test will be added as a release gate — likely a separate workflow rather than a PR check, given its longer runtime.
