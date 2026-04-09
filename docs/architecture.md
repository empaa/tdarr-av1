# Architecture

Read this before adding features or making structural changes.

This file is populated as the project is built.

---

## AV1 Stack as a Build Stage

The AV1 stack (av1an, ab-av1, FFmpeg, VapourSynth, SVT-AV1, libaom, libvmaf,
L-SMASH-Works) is compiled from source in the `av1-stack` named stage of the
single `Dockerfile`. The `tdarr` and `tdarr_node` targets layer the stack on top
of the official Tdarr base images via `COPY --from=av1-stack`.

All components install to `/usr/local`. `/etc/vapoursynth/vapoursynth.conf` is also
copied to configure the VapourSynth plugin directory. `ENV PYTHONPATH` is set in each
target to point at the compiled VapourSynth Python bindings.

**FFmpeg shadowing:** Our FFmpeg at `/usr/local/bin/ffmpeg` takes precedence over
Tdarr's bundled `/usr/bin/ffmpeg` via standard `$PATH` ordering. No wrappers or
`LD_LIBRARY_PATH` manipulation needed. On amd64, the Tdarr base image ships an
s6 init script (`/etc/cont-init.d/03-setup-ffmpeg`) that symlinks Jellyfin's
ffmpeg (no libvmaf) to `/usr/local/bin/ffmpeg` on every container start. The
Dockerfile removes this script — do not remove the `rm -f` step.

**glibc compatibility:** The `base` stage matches Tdarr's Ubuntu version exactly.
See `docs/constraints.md` for the pinned version.

**av1-stack is not published.** It exists solely as a build stage and test target.
Only `tdarr` and `tdarr_node` are pushed to GHCR.

## Build Stage Graph (Dockerfile)

```
base (Ubuntu 24.04 + build tools + Rust)
 ├── build-svtav1       (independent)
 ├── build-libaom       (independent)
 ├── build-libvmaf      (independent)
 ├── build-vapoursynth  (zimg built inside; independent)
 │
 ├── build-ffmpeg  ←── svtav1, libaom, libvmaf
 │
 ├── build-lsmash    ←── vapoursynth, ffmpeg
 ├── build-av1an     ←── vapoursynth, ffmpeg
 ├── build-ab-av1         (Rust only; independent)
 ├── build-nlm-ispc ←── vapoursynth
 ├── build-addgrain ←── vapoursynth
 └── build-mvtools  ←── vapoursynth
          │
          ▼
      av1-stack  ←── all build-* stages (named target; test + layer source)
          │
          ├── tdarr       ←── ghcr.io/haveagitgat/tdarr + av1-stack
          └── tdarr_node  ←── ghcr.io/haveagitgat/tdarr_node + av1-stack
```

BuildKit runs independent stages in parallel automatically.
