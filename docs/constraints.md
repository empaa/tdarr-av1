# Constraints

Read this before editing the Dockerfile or changing any component version.

This file is populated as decisions are made during development. Each entry records what the constraint is and why it exists — so the reason is never lost.

---

## Tdarr Base OS

**Constraint:** The `base` stage in `Dockerfile` must use exactly this Ubuntu version.

**Why:** Compiled `.so` files reference glibc symbols from the OS they are built on.
If the build OS is newer than Tdarr's runtime OS, `dlopen` fails with symbol-not-found
errors at runtime.

**Tdarr image base:** Ubuntu 24.04 (Noble)
**tdarr_node image base:** Ubuntu 24.04 (Noble)

---

## VapourSynth R73+

**Constraint:** Must use R73 or later. Do not downgrade to R72 or earlier. Do not
upgrade to R74 until it leaves RC.

**Why:** av1an 0.5.2 uses the `vapoursynth-rs` Rust crate v0.5.1, which requires
VSScript API v4. VapourSynth R72 only provides VSScript API v3 — av1an will fail
to load VSScript at runtime. R73 is the first release with API v4.

---

## SVT-AV1 4.1.0 + FFmpeg 8.1

**Constraint:** SVT-AV1 4.x requires FFmpeg 8.1 or later.

**Why:** FFmpeg 8.1 added `SVT_AV1_CHECK_VERSION(4, 0, 0)` guards in
`libavcodec/libsvtav1.c`, handling both 3.x and 4.x APIs at compile time.
Earlier FFmpeg versions do not know about the 4.x API and will fail to build.

---

## Jellyfin FFmpeg init script removal (amd64)

**Constraint:** The `tdarr` and `tdarr_node` targets must `rm -f /etc/cont-init.d/03-setup-ffmpeg`.

**Why:** On amd64, the Tdarr base image ships an s6-overlay init script that
symlinks Jellyfin's ffmpeg (no libvmaf) to `/usr/local/bin/ffmpeg` on every
container start. This overwrites our custom ffmpeg at runtime regardless of what
the Dockerfile does at build time. Removing the init script is the only fix.

---

## vs-nlm-ispc v2 + ISPC v1.30.0

**Constraint:** Pin vs-nlm-ispc to tag v2 and ISPC compiler to v1.30.0.

**Why:** vs-nlm-ispc v2 is the latest release. ISPC v1.30.0 is the latest
stable release with arm64 Linux support. The ISPC instruction set flags differ
per architecture: arm64 requires `-DCMAKE_ISPC_INSTRUCTION_SETS="neon-i32x4"`,
amd64 uses defaults (SSE2/AVX2 multi-target).

---

## vs-addgrain r10

**Constraint:** Pin VapourSynth-AddGrain to tag r10.

**Why:** r10 is the latest release. Pure C++ with optional x86 SIMD and C
fallback for arm64. Used for denoiser calibration (adding known Gaussian noise).

---

## vapoursynth-mvtools v24

**Constraint:** Pin vapoursynth-mvtools to tag v24.

**Why:** v24 is the latest release supporting VapourSynth V3/V4 API. Requires
FFTW3 (`libfftw3-single3`) at runtime. Has native arm64 NEON support via
sse2neon.
