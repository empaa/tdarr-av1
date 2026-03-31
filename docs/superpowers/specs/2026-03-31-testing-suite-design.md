# Testing Suite Design

**Date:** 2026-03-31
**Scope:** Extend the existing `test.sh` (av1-stack only) with a new `test-tdarr.sh` that tests the complete `tdarr` and `tdarr_node` images, including binary checks, HTTP startup verification, and encode tests.

---

## Overview

The test suite has two scripts with matching flag interfaces:

| Script | Image tested | Phases |
|---|---|---|
| `test.sh` | `av1-stack-test` | 1: binary checks (always) · 2: encode tests (`--release`) |
| `test-tdarr.sh` | `tdarr-test`, `tdarr_node-test` | 1: binary checks (always) · 2: startup + encode (`--release`) |

Both scripts must pass before a merge or release.

---

## Image Chain

`test-tdarr.sh` builds on top of the local av1-stack image produced by `test.sh`. It does not pull from GHCR.

```
av1-stack-test:amd64  (built by test.sh)
        │
        ├─► tdarr-test:amd64       (FROM ghcr.io/haveagitgat/tdarr,       COPY --from av1-stack-test:amd64)
        └─► tdarr_node-test:amd64  (FROM ghcr.io/haveagitgat/tdarr_node,  COPY --from av1-stack-test:amd64)
```

The `COPY --from` source is overridden at build time via `--build-arg` so the real `Dockerfile.tdarr` and `Dockerfile.tdarr_node` can be reused without modification.

---

## Flags

`test-tdarr.sh` accepts the same flags as `test.sh`:

- *(no flags)* — build both platforms, run binary checks only
- `--release` — native arch only, binary checks + startup + encode tests
- `--clean` — remove cached tdarr test images and wipe `test/output/tdarr/` and `test/output/tdarr_node/`
- `--release --clean` — clean then full release run

---

## Phase 1: Binary Checks

Runs on both `linux/amd64` and `linux/arm64` (or native arch only under `--release`).

For each image (`tdarr-test`, `tdarr_node-test`), runs:
- `av1an --version`
- `ab-av1 --version`
- `ffmpeg -version`

Same pass/fail reporting as `test.sh`: label left-padded, `OK` or `FAILED`, failures accumulated and reported together at exit.

---

## Phase 2: Startup + Encode Tests (`--release` only)

Runs on native arch only. Executed for both `tdarr-test` and `tdarr_node-test`.

### Startup check

1. `docker run -d` with minimal Tdarr env vars (e.g. `serverIP`, `serverPort`, `internalNode` for tdarr; `serverIP`, `serverPort`, `nodeName` for tdarr_node — use localhost/defaults sufficient to get the HTTP server listening)
2. Poll `http://localhost:8265` with `curl --retry` up to 30 seconds
3. If the endpoint responds: `OK`, stop and remove the container
4. If timeout: `FAILED` — skip encode test for that image, continue to next

### Encode test

Same encode commands as `test.sh` phase 2, run inside the tdarr/tdarr_node image:

```
ffmpeg clip (60s from 1:00)
av1an aom   (--target-quality 90)
av1an svt-av1 (--target-quality 90)
ab-av1 auto-encode (--min-vmaf 90)
```

Outputs land in:
- `test/output/tdarr/<stem>_*.mkv`
- `test/output/tdarr_node/<stem>_*.mkv`

---

## Output Directory Layout

```
test/output/
  stack/          ← av1-stack encode outputs (test.sh phase 2)
  tdarr/          ← tdarr encode outputs
  tdarr_node/     ← tdarr_node encode outputs
```

`test.sh --clean` wipes `test/output/stack/`.
`test-tdarr.sh --clean` wipes `test/output/tdarr/` and `test/output/tdarr_node/`.

---

## Error Handling

- Failures accumulate; all checks run before exit
- Startup timeout counts as a failed check and skips encode for that image
- Non-zero exit if any check fails

---

## Workflow Integration

`docs/build-and-publish.md` is updated:

**Pre-merge:**
```bash
./test.sh && ./test-tdarr.sh
```

**Pre-release:**
```bash
./test.sh --release && ./test-tdarr.sh --release
```
