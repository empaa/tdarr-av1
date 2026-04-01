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
