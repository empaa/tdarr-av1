# Architecture

Read this before adding features or making structural changes.

This file is populated as the project is built.

---

## AV1 Stack Distribution via av1-stack Image

The AV1 stack (av1an, ab-av1, FFmpeg, VapourSynth, SVT-AV1, libaom, libvmaf,
L-SMASH-Works) is compiled once into `ghcr.io/empaa/av1-stack:latest` and layered
into the Tdarr images via `COPY --from=ghcr.io/empaa/av1-stack:latest /usr/local /usr/local`.

All components install to `/usr/local`. `/etc/vapoursynth/vapoursynth.conf` is also
copied to configure the VapourSynth plugin directory.

**FFmpeg shadowing:** Our FFmpeg at `/usr/local/bin/ffmpeg` takes precedence over
Tdarr's bundled `/usr/bin/ffmpeg` via standard `$PATH` ordering. No wrappers or
`LD_LIBRARY_PATH` manipulation needed.

**glibc compatibility:** The av1-stack base matches Tdarr's Ubuntu version exactly.
See `docs/constraints.md` for the pinned version.

## Build Stage Graph (Dockerfile.stack)

```
base (Ubuntu + build tools + Rust)
 ├── build-svtav1       (independent)
 ├── build-libaom       (independent)
 ├── build-libvmaf      (independent)
 ├── build-vapoursynth  (zimg built inside; independent)
 │
 ├── build-ffmpeg  ←── svtav1, libaom, libvmaf
 │
 ├── build-lsmash  ←── vapoursynth, ffmpeg
 ├── build-av1an   ←── vapoursynth, ffmpeg  (patches/av1an-vmaf.py applied)
 └── build-ab-av1       (Rust only; independent)
          │
          ▼
       final  ←── all build-* stages
  (COPY /usr/local, ldconfig, vapoursynth.conf)
```

BuildKit runs independent stages in parallel automatically.
