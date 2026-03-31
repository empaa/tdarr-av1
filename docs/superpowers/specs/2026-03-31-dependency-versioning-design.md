# Dependency Versioning — Design Spec

**Date:** 2026-03-31

## Summary

Update all dependencies in `Dockerfile.stack` to current stable versions, fix two build bugs
(wrong L-SMASH-Works fork, wrong VapourSynth version pin), switch libaom to the official
tarball distribution, and correct stale entries in `docs/constraints.md`.

---

## Version Changes

| Component | Old | New | Change type |
|---|---|---|---|
| VapourSynth | R72 | R73 | Bug fix — R72 was wrong for av1an 0.5.2 |
| SVT-AV1 | 3.1.2 | 4.1.0 | Major upgrade |
| FFmpeg | 8.0.1 | 8.1 | Minor upgrade |
| libaom | 3.12.1 | 3.13.2 | Minor bump |
| zimg | 3.0.5 | 3.0.6 | Patch |
| ab-av1 | 0.10.3 | 0.11.2 | Minor bump |
| libvmaf | 3.0.0 | 3.0.0 | No change |
| av1an | 0.5.2 | 0.5.2 | No change |

---

## Build Reliability Fixes

### 1. VapourSynth: R72 → R73

The R72 pin was based on outdated information. Confirmed chain:

- av1an v0.5.2 depends on `vapoursynth` Rust crate v0.5.1
- vapoursynth-rs v0.5.1 uses `VSScript4.h` with `VSSCRIPT_API_MAJOR 4`
- VapourSynth R73 release notes: *"vsscript r3 api support has been completely removed"*

**av1an 0.5.2 requires VapourSynth R73+.** Using R72 means av1an cannot load VSScript at
runtime. R73 is the current stable release; R74 is in RC and should not be used yet.

### 2. L-SMASH-Works fork: AkarinVS → HomeOfAviSynthPlusEvolution

The current `Dockerfile.stack` clones `AkarinVS/L-SMASH-Works`. This fork is incompatible
with FFmpeg 5+: it references `AVStream.index_entries` which was made private in FFmpeg
commit `cea7c19`. `HomeOfAviSynthPlusEvolution/L-SMASH-Works` maintains FFmpeg 6/7/8
compatibility and is the correct fork.

**Pin:** commit `0079a06ee384061ecdadd0de03df4e0493dd56ab` (2026-03-26, "Update version to 1282").

A comment must be added to the Dockerfile explaining the fork choice and why AkarinVS is wrong,
so it is not silently reverted in future edits.

### 3. libaom source: googlesource git clone → official tarball

Currently cloned from `aomedia.googlesource.com/aom` with `--branch v3.12.1`. That host
can be slow or unavailable. Google's stable distribution channel is
`https://storage.googleapis.com/aom-releases/libaom-<version>.tar.gz` — this is where
official releases are published as versioned tarballs.

Switch to `wget storage.googleapis.com/aom-releases/libaom-3.13.2.tar.gz`. Same cmake
build process; more reliable download source.

### 4. l-smash library: pin to v2.14.5

Currently cloned from `l-smash/l-smash` with no branch specified (unpinned master).
Pin to `--branch v2.14.5` (latest stable tag as of 2026-03-31).

---

## SVT-AV1 4.1.0 + FFmpeg 8.1 Compatibility

FFmpeg 8.1 explicitly supports SVT-AV1 4.x. The encoder source (`libavcodec/libsvtav1.c`)
contains `#if SVT_AV1_CHECK_VERSION(4, 0, 0)` guards, meaning it handles both 3.x and 4.x
APIs at compile time. No patching or workarounds needed.

The existing constraint in `docs/constraints.md` noted that FFmpeg 8.0.1 was required for
SVT-AV1 3.x compatibility. This is updated: FFmpeg 8.1 is required for SVT-AV1 4.x.

---

## Documentation Changes: docs/constraints.md

Two entries must be updated:

**VapourSynth (replace existing entry):**
- Old: Must use exactly R72. R73+ removed VSScript API v3. av1an 0.5.2 uses API v3.
- New: Must use R73 or later. av1an 0.5.2 uses `vapoursynth-rs` v0.5.1 which requires
  VSScript API v4. R72 uses API v3 and will fail at runtime. Do not upgrade to R74 until
  it leaves RC.

**SVT-AV1 + FFmpeg (replace existing entry):**
- Old: SVT-AV1 3.1.2 requires FFmpeg 8.0.1 for 3.x API compatibility.
- New: SVT-AV1 4.1.0 requires FFmpeg 8.1+. FFmpeg 8.1 contains `SVT_AV1_CHECK_VERSION(4, 0, 0)`
  guards and handles both 3.x and 4.x APIs at compile time.

---

## Risk: SVT-AV1 4.x Encoder Flags (Out of Scope)

SVT-AV1 4.x may have deprecated or renamed encoder parameters relative to 3.x. Any Tdarr
plugin that passes raw SVT-AV1 flags (e.g. via `--svtav1-params`) should be reviewed after
the build succeeds. This is not part of the Dockerfile work.

---

## Files Changed

- `Dockerfile.stack` — version bumps, fork switch, libaom tarball, l-smash pin, Dockerfile comments
- `docs/constraints.md` — VapourSynth and SVT-AV1+FFmpeg entries updated
