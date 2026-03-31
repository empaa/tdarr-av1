# Release Test Design

**Date:** 2026-03-31
**Status:** Approved

## Problem

The existing `test.sh` only verifies that binaries are present and respond to `--version`. It gives no signal that the actual encode stack works end-to-end with real video input. Before publishing a release, we want to confirm that av1an (aom and svt-av1) and ab-av1 can complete real encode jobs inside the container.

## Goal

Extend `test.sh` with a `--release` mode that runs actual encode tests against local sample files, while keeping the existing binary-check phase fast and suitable for pre-merge use.

## Directory Structure

```
test/
  samples/    # input video files — contents gitignored, directory tracked via .gitkeep
  output/     # encode outputs   — contents gitignored, directory tracked via .gitkeep
```

`.gitignore` additions:
```
test/samples/*
!test/samples/.gitkeep
test/output/*
!test/output/.gitkeep
```

The test dynamically globs `test/samples/` (excluding `.gitkeep`). Any video file dropped there is picked up automatically — no script changes needed.

## Flag Behaviour

| Command | Build | Binary checks | Encode tests |
|---|---|---|---|
| `./test.sh` | both platforms (cached) | both platforms | — |
| `./test.sh --release` | native only (cached) | native only | yes |
| `./test.sh --clean` | — | — | — (removes cached images + wipes test/output/) |
| `./test.sh --release --clean` | native (fresh build) | native | yes (fresh) |

**Caching:** after a successful `./test.sh` run, the images `av1-stack-test:amd64` and `av1-stack-test:arm64` remain in the local Docker image store. `--release` detects the native platform, checks for the image via `docker image inspect`, and skips the build if it exists.

**`--clean`:** removes `av1-stack-test:amd64` and `av1-stack-test:arm64` from the local image store (if present) and deletes all files in `test/output/`. Does not remove `test/output/.gitkeep` or `test/samples/.gitkeep`.

## Phase 1 — Binary Checks (always)

Unchanged from current `test.sh` behaviour, except:
- `./test.sh` continues to build and check both platforms.
- `./test.sh --release` builds and checks native platform only (no QEMU for encode runs).

Binaries checked: `av1an`, `ab-av1`, `ffmpeg`.

## Phase 2 — Encode Tests (`--release` only)

**Platform:** native only. Running real encodes under QEMU emulation would be prohibitively slow. To test the other architecture, pull the image on a machine of that architecture and run `./test.sh --release` there.

**Empty samples handling:** if `test/samples/` contains no files (other than `.gitkeep`), Phase 2 prints a warning and skips without failing. The script exits cleanly.

**Short file handling:** the clip is extracted starting at 1 minute in (`-ss 00:01:00`). Sample files shorter than ~70 seconds may produce a very short or empty clip. This is a known limitation — use sample files that are at least 2 minutes long.

**Per-sample flow:** for each file found in `test/samples/`:

1. Run one container:
   ```
   docker run --rm \
     -v ./test/samples:/samples:ro \
     -v ./test/output:/output \
     av1-stack-test:<arch> bash -c "
       ffmpeg -ss 00:01:00 -t 60 -i /samples/<file> -c copy /output/<stem>_clip.mkv &&
       av1an -i /output/<stem>_clip.mkv --encoder aom --target-quality 90 \
             -o /output/<stem>_av1an_aom.mkv &&
       av1an -i /output/<stem>_clip.mkv --encoder svt-av1 --target-quality 90 \
             -o /output/<stem>_av1an_svtav1.mkv &&
       ab-av1 encode -i /output/<stem>_clip.mkv --min-vmaf 90 \
              -o /output/<stem>_ab-av1.mkv
     "
   ```
2. After the container exits, check each expected output file (`_av1an_aom.mkv`, `_av1an_svtav1.mkv`, `_ab-av1.mkv`): exists and non-zero size.
3. Collect pass/fail per encoder. Do not abort mid-sample — finish all three checks before moving to the next file.

**Output files persist** in `test/output/` for inspection after the run. The intermediate clip (`<stem>_clip.mkv`) is also retained.

**Pass criteria:** container exits 0 AND each output file exists AND each output file is non-zero size.

**Failure reporting:** all failures across all samples are collected and printed as a summary at the end. The script exits non-zero if any check failed.

## Out of Scope

- No changes to `publish.yml` or `build.sh`
- No changes to any Dockerfile
- CI does not run the encode tests (samples are not committed)
