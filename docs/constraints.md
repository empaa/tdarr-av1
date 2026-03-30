# Constraints

Read this before editing the Dockerfile or changing any component version.

This file is populated as decisions are made during development. Each entry records what the constraint is and why it exists — so the reason is never lost.

---

## Tdarr Base OS

**Constraint:** `Dockerfile.stack` base stage must use exactly this Ubuntu version.

**Why:** Compiled `.so` files reference glibc symbols from the OS they are built on.
If the build OS is newer than Tdarr's runtime OS, `dlopen` fails with symbol-not-found
errors at runtime.

**Tdarr image base:** Ubuntu 22.04 (Jammy)
**tdarr_node image base:** Ubuntu 22.04 (Jammy)

---

## VapourSynth R72

**Constraint:** Must use exactly R72. Do not upgrade to R73+.

**Why:** VapourSynth R73 removed VSScript API v3. av1an 0.5.2 uses VSScript API v3
to invoke VapourSynth. Upgrading breaks av1an.

---

## SVT-AV1 3.1.2 + FFmpeg 8.0.1

**Constraint:** SVT-AV1 v3.0+ changed its API. FFmpeg 8.0.1 is required for
compatibility with SVT-AV1 3.1.2.

**Why:** Earlier FFmpeg versions use the old SVT-AV1 API and fail to build with
the new library.
