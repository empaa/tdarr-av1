# Unified Build Script Design

Consolidate `test-stack.sh`, `test-tdarr.sh`, and `publish.sh` into a single
`build.sh` that builds, tests, and publishes — ensuring what you test is exactly
what you ship.

---

## Core Principle

Images are built into the local Docker daemon during the test phase. Publishing
retags and pushes those exact images — no rebuild. This guarantees byte-for-byte
identity between tested and shipped artifacts.

---

## Script Interface

### Flags

| Flag | Effect |
|---|---|
| _(no flags)_ | Build `tdarr` + `tdarr_node` for native arch, run binary checks + startup check |
| `--stack-only` | Build only `av1-stack`, run binary checks (no startup check) |
| `--encode` | Add encode tests (works with both default and `--stack-only`) |
| `--all-platforms` | Build for both `linux/amd64` and `linux/arm64` |
| `--arm64` | Build for `linux/arm64` specifically |
| `--amd64` | Build for `linux/amd64` specifically |
| `--publish` | Push previously tested images to GHCR (or combine with build flags to build+test+publish) |
| `--clean` | Remove all local images + test output, stop builder |
| `--clean-cache` | Same as `--clean` plus prune the buildx cache |

### Platform flag rules

- `--all-platforms`, `--arm64`, and `--amd64` are mutually exclusive.
- Omitting all three defaults to native architecture.

### Invalid combinations

- `--stack-only --publish` — rejected with error. `av1-stack` is never published.
- `--clean` / `--clean-cache` with any build/test/publish flag — rejected. Clean is standalone.

---

## Build-Then-Publish Mechanism

### Combined with build flags (e.g. `./build.sh --arm64 --publish` or `./build.sh --all-platforms --publish`)

When `--publish` is combined with platform/build flags, the script always
builds + tests + publishes in one shot.

**Single platform:**

1. Build + test.
2. Retag: `tdarr:<arch>` -> `ghcr.io/empaa/tdarr:latest` (same for `tdarr_node`).
3. Push each image.

**Multi-platform (`--all-platforms`):**

1. Build + test both platforms.
2. Push each arch-specific image with an arch tag:
   - `ghcr.io/empaa/tdarr:amd64`, `ghcr.io/empaa/tdarr:arm64`
   - `ghcr.io/empaa/tdarr_node:amd64`, `ghcr.io/empaa/tdarr_node:arm64`
3. Create and push a manifest list for `:latest` combining both architectures.
4. Clean up the arch-specific tags from the registry (implementation details).

### Standalone `--publish` (no build flags)

Checks that the required local images exist for the requested platform scope. If
any are missing, errors with a clear message:

```
Missing test images for linux/arm64: tdarr:arm64, tdarr_node:arm64
Run: ./build.sh --arm64    (or --all-platforms)
```

GHCR auth check runs early, before any build work.

---

## Test Result Summary

Individual test functions print a short progress line as they complete (e.g.
"Binary checks (linux/amd64)... done"). Detailed pass/fail results are collected
into an array and only displayed in a summary table at the end.

### Example output (`./build.sh --all-platforms --encode`)

```
==> Building tdarr (linux/amd64)...
[... build output ...]
==> Building tdarr_node (linux/amd64)...
[... build output ...]
Binary checks (linux/amd64)... done
Startup check (linux/amd64)... done
Encode tests (linux/amd64)... done

==> Building tdarr (linux/arm64)...
[... build output ...]
==> Building tdarr_node (linux/arm64)...
[... build output ...]
Binary checks (linux/arm64)... done
Startup check (linux/arm64)... done
Encode tests (linux/arm64)... done

════════════════════════════════════════
  Test Summary
════════════════════════════════════════
  linux/amd64
    av1an (tdarr)          OK
    ab-av1 (tdarr)         OK
    ffmpeg (tdarr)         OK
    av1an (tdarr_node)     OK
    ab-av1 (tdarr_node)    OK
    ffmpeg (tdarr_node)    OK
    tdarr server           OK
    tdarr_node alive       OK
    encode av1an+aom       OK
    encode av1an+svtav1    OK
    encode ab-av1          OK

  linux/arm64
    av1an (tdarr)          OK
    ab-av1 (tdarr)         FAILED
    ...
════════════════════════════════════════
  FAILED: 1 check(s) failed
════════════════════════════════════════
```

The summary table adapts to `--stack-only` mode — shows only stack-level results,
no tdarr/tdarr_node rows.

---

## `--stack-only` Mode

Builds only the `av1-stack` stage and runs a reduced test suite:

- Binary checks against `av1-stack:<arch>` image.
- Encode tests if `--encode` is also passed.
- No startup check (no tdarr server/node to start).

Combinable with platform flags: `./build.sh --stack-only --arm64 --encode`

---

## Clean Modes

### `--clean`

- Remove all local images: `tdarr:amd64`, `tdarr:arm64`, `tdarr_node:amd64`,
  `tdarr_node:arm64`, `av1-stack:amd64`, `av1-stack:arm64`
- Delete test output: `test/output/stack/`, `test/output/tdarr/`
- Stop the buildx builder

### `--clean-cache`

- Everything `--clean` does, plus:
- `docker buildx prune --builder multiplatform --force` to wipe the build cache.

Both are standalone operations — exit after cleaning, cannot be combined with
build/test/publish flags.

---

## Files Changed

| Action | File |
|---|---|
| Create | `build.sh` |
| Delete | `test-stack.sh` |
| Delete | `test-tdarr.sh` |
| Delete | `publish.sh` |
| Update | `docs/build-and-publish.md` — rewrite for single-script workflow |
