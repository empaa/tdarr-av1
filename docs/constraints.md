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

## VapourSynth R74+

**Constraint:** Must use R74 or later. Do not downgrade to R72 or earlier.

**Why:** av1an 0.5.2 uses the `vapoursynth-rs` Rust crate v0.5.1, which requires
VSScript API v4. VapourSynth R72 only provides VSScript API v3 — av1an will fail
to load VSScript at runtime. R73 is the first release with API v4.

**Build notes (R74):** R74 switched from autotools to Meson and renamed
`libvapoursynth-script` to `libvsscript`. The build uses `build_wheel=true` to get
vspipe and the Python module, then relocates artifacts to standard paths. A compat
symlink (`libvapoursynth-script.so → libvsscript.so`) is needed for av1an linking.
A TOML config at `$HOME/.config/vapoursynth/vapoursynth.toml` is required at runtime
to map libvsscript to the Python interpreter.

---

## SVT-AV1 4.1.0 + FFmpeg 8.1

**Constraint:** SVT-AV1 4.x requires FFmpeg 8.1 or later.

**Why:** FFmpeg 8.1 added `SVT_AV1_CHECK_VERSION(4, 0, 0)` guards in
`libavcodec/libsvtav1.c`, handling both 3.x and 4.x APIs at compile time.
Earlier FFmpeg versions do not know about the 4.x API and will fail to build.

---

## Tdarr Base Image Version

**Constraint:** Pin `TDARR_VERSION` to a specific version tag (currently `2.68.01`).
Do not use `:latest`.

**Why:** Tdarr updates can change the base OS, bundled libraries, or init scripts in
ways that break our AV1 stack overlay. Pinning lets us verify each update manually
before adopting it. The same `ARG` controls both the `tdarr` and `tdarr_node` stages.

---

## Jellyfin FFmpeg init script removal (amd64)

**Constraint:** The `tdarr` and `tdarr_node` targets must `rm -f /etc/cont-init.d/03-setup-ffmpeg`.

**Why:** On amd64, the Tdarr base image ships an s6-overlay init script that
symlinks Jellyfin's ffmpeg (no libvmaf) to `/usr/local/bin/ffmpeg` on every
container start. This overwrites our custom ffmpeg at runtime regardless of what
the Dockerfile does at build time. Removing the init script is the only fix.

