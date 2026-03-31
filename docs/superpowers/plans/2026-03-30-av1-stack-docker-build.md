# AV1 Stack Docker Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish two GHCR Docker images (`ghcr.io/empaa/tdarr` and `ghcr.io/empaa/tdarr_node`) that extend the official Tdarr images with a compiled AV1 encoding stack (av1an + ab-av1 + all dependencies).

**Architecture:** A multi-stage `Dockerfile.stack` compiles the full AV1 stack from source in parallel BuildKit stages and collects everything into `/usr/local` of a final `av1-stack` image. Two thin Tdarr Dockerfiles layer the stack on top of the official Tdarr images via `COPY --from`. Two CI workflows handle publishing: `build-stack.yml` (heavy, ~40 min, only when stack source changes) and `build-tdarr.yml` (fast, ~5 min, on Tdarr Dockerfile changes or manual trigger).

**Tech Stack:** Docker BuildKit multi-stage builds, Ubuntu (matched to Tdarr's base OS), CMake, Meson/Ninja, Cargo/Rust, autotools, GitHub Actions, GHCR.

---

## File Map

| File | Purpose |
|---|---|
| `Dockerfile.stack` | Multi-stage build: all AV1 components compiled to `/usr/local` |
| `Dockerfile.tdarr` | FROM tdarr:latest + COPY stack + ldconfig + apt mkvtoolnix |
| `Dockerfile.tdarr_node` | FROM tdarr_node:latest + COPY stack + ldconfig + apt mkvtoolnix |
| `patches/av1an-vmaf.py` | Fixes inverted VMAF model path logic in av1an's vmaf.rs |
| `build.sh` | Local build script: fast path (pull stack) and full path (rebuild stack) |
| `.github/workflows/build-stack.yml` | CI: builds and pushes `ghcr.io/empaa/av1-stack:latest` |
| `.github/workflows/build-tdarr.yml` | CI: builds and pushes `tdarr:latest` and `tdarr_node:latest` |

---

## Task 1: Determine Tdarr base OS and initialize docs

**Files:**
- Modify: `docs/constraints.md`
- Modify: `docs/architecture.md`

This is the critical first step. The av1-stack build base must exactly match Tdarr's Ubuntu version or compiled `.so` files will fail at runtime with glibc symbol errors.

- [ ] **Step 1: Check Tdarr base OS**

```bash
docker run --rm ghcr.io/haveagitgat/tdarr:latest cat /etc/os-release
docker run --rm ghcr.io/haveagitgat/tdarr_node:latest cat /etc/os-release
```

Expected output (example — actual values may differ):
```
NAME="Ubuntu"
VERSION_ID="22.04"
...
```

Note both `VERSION_ID` values. They should match. If they don't, open an issue — the plan assumes they match.

- [ ] **Step 2: Initialize constraints.md**

Replace the placeholder comment in `docs/constraints.md` with the actual findings (substitute real VERSION_ID):

```markdown
## Tdarr Base OS

**Constraint:** `Dockerfile.stack` base stage must use exactly this Ubuntu version.

**Why:** Compiled `.so` files reference glibc symbols from the OS they are built on.
If the build OS is newer than Tdarr's runtime OS, `dlopen` fails with symbol-not-found
errors at runtime.

**Tdarr image base:** Ubuntu XX.XX (fill in VERSION_ID from Step 1)
**tdarr_node image base:** Ubuntu XX.XX (fill in VERSION_ID from Step 1)

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
```

- [ ] **Step 3: Initialize architecture.md**

Replace the placeholder comment in `docs/architecture.md` with:

```markdown
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
```

- [ ] **Step 4: Commit**

```bash
git add docs/constraints.md docs/architecture.md
git commit -m "docs: record Tdarr base OS, architecture decisions, and version constraints"
```

---

## Task 2: Create Dockerfile.stack — base stage

**Files:**
- Create: `Dockerfile.stack`

- [ ] **Step 1: Verify the file doesn't exist yet**

```bash
docker build --target base -f Dockerfile.stack . 2>&1 | head -3
```

Expected: `unable to open Dockerfile.stack` (or similar "file not found" error)

- [ ] **Step 2: Create Dockerfile.stack with base stage**

Replace `22.04` with the actual `VERSION_ID` found in Task 1:

```dockerfile
# syntax=docker/dockerfile:1

FROM ubuntu:22.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    meson \
    nasm \
    yasm \
    autoconf \
    automake \
    libtool \
    pkg-config \
    python3-dev \
    cython3 \
    git \
    wget \
    curl \
    libssl-dev \
    && ln -sf /usr/bin/cython3 /usr/bin/cython \
    && rm -rf /var/lib/apt/lists/*

# Install Rust stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
```

Note: `ln -sf /usr/bin/cython3 /usr/bin/cython` creates the `cython` symlink that VapourSynth's autotools build looks for. If `cython3` is not found on the discovered Ubuntu version, try `python3-cython` as the package name instead.

- [ ] **Step 3: Build base stage and verify**

```bash
docker build --target base -f Dockerfile.stack -t test-base .
```

Expected: build completes, no errors.

- [ ] **Step 4: Verify tools are installed**

```bash
docker run --rm test-base bash -c \
  "rustc --version && cargo --version && cmake --version | head -1 && cython --version"
```

Expected (versions will vary):
```
rustc 1.XX.0 (...)
cargo 1.XX.0 (...)
cmake version 3.XX.X
Cython version 0.XX.X
```

- [ ] **Step 5: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add Dockerfile.stack with base stage (build deps + Rust)"
```

---

## Task 3: Add build-svtav1 stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-svtav1 stage to Dockerfile.stack**

```dockerfile
FROM base AS build-svtav1

RUN git clone --depth 1 --branch v3.1.2 \
        https://gitlab.com/AOMediaCodec/SVT-AV1.git /src/svtav1 && \
    cmake -S /src/svtav1 -B /src/svtav1/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/svtav1/build -j$(nproc) && \
    cmake --install /src/svtav1/build && \
    ldconfig && \
    rm -rf /src
```

- [ ] **Step 2: Build to build-svtav1 target**

```bash
docker build --target build-svtav1 -f Dockerfile.stack -t test-svtav1 .
```

Expected: completes without error. Build time ~5–10 min.

- [ ] **Step 3: Verify binary and library**

```bash
docker run --rm test-svtav1 bash -c \
  "SvtAv1EncApp --version && ls /usr/local/lib/libSvtAv1Enc.so*"
```

Expected:
```
SVT-AV1 Encoder Lib v3.1.2
/usr/local/lib/libSvtAv1Enc.so  /usr/local/lib/libSvtAv1Enc.so.3  ...
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add SVT-AV1 3.1.2 build stage"
```

---

## Task 4: Add build-libaom stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-libaom stage to Dockerfile.stack**

```dockerfile
FROM base AS build-libaom

RUN git clone --depth 1 --branch v3.12.1 \
        https://aomedia.googlesource.com/aom /src/aom && \
    cmake -S /src/aom -B /src/aom_build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/aom_build -j$(nproc) && \
    cmake --install /src/aom_build && \
    ldconfig && \
    rm -rf /src /src/aom_build
```

- [ ] **Step 2: Build to build-libaom target**

```bash
docker build --target build-libaom -f Dockerfile.stack -t test-libaom .
```

Expected: completes without error. Build time ~5 min.

- [ ] **Step 3: Verify library and pkg-config file**

```bash
docker run --rm test-libaom bash -c \
  "ls /usr/local/lib/libaom.so* && ls /usr/local/lib/pkgconfig/aom.pc"
```

Expected:
```
/usr/local/lib/libaom.so  /usr/local/lib/libaom.so.3  ...
/usr/local/lib/pkgconfig/aom.pc
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add libaom 3.12.1 build stage"
```

---

## Task 5: Add build-libvmaf stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-libvmaf stage to Dockerfile.stack**

```dockerfile
FROM base AS build-libvmaf

RUN git clone --depth 1 --branch v3.0.0 \
        https://github.com/Netflix/vmaf.git /src/vmaf && \
    meson setup /src/vmaf/libvmaf/build /src/vmaf/libvmaf \
        --buildtype=release \
        -Dbuilt_in_models=true \
        -Dprefix=/usr/local && \
    ninja -C /src/vmaf/libvmaf/build && \
    ninja -C /src/vmaf/libvmaf/build install && \
    mkdir -p /usr/local/share/vmaf && \
    cp -r /src/vmaf/model/. /usr/local/share/vmaf/ && \
    ldconfig && \
    rm -rf /src
```

Note: `-Dbuilt_in_models=true` compiles the VMAF models into the library. The `cp -r` also installs model files to `/usr/local/share/vmaf/` so av1an can reference them by path when using the `--vmaf-path` flag.

- [ ] **Step 2: Build to build-libvmaf target**

```bash
docker build --target build-libvmaf -f Dockerfile.stack -t test-libvmaf .
```

Expected: completes without error. Build time ~3–5 min.

- [ ] **Step 3: Verify library and model files**

```bash
docker run --rm test-libvmaf bash -c \
  "ls /usr/local/lib/libvmaf.so* && ls /usr/local/share/vmaf/*.json | head -4"
```

Expected:
```
/usr/local/lib/libvmaf.so  /usr/local/lib/libvmaf.so.3  ...
/usr/local/share/vmaf/vmaf_4k_v0.6.1.json
/usr/local/share/vmaf/vmaf_v0.6.1.json
...
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add libvmaf 3.0.0 build stage with built-in models"
```

---

## Task 6: Add build-vapoursynth stage (includes zimg)

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-vapoursynth stage to Dockerfile.stack**

```dockerfile
FROM base AS build-vapoursynth

# Build zimg 3.0.5 first — VapourSynth depends on it
RUN git clone --depth 1 --branch release-3.0.5 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
    cd /src/zimg && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Build VapourSynth R72
# MUST be exactly R72 — R73 removed VSScript API v3 which av1an requires
RUN git clone --depth 1 --branch R72 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
    cd /src/vapoursynth && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src
```

The `PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` env (set in base) allows VapourSynth's configure to find the zimg pkg-config file.

- [ ] **Step 2: Build to build-vapoursynth target**

```bash
docker build --target build-vapoursynth -f Dockerfile.stack -t test-vapoursynth .
```

Expected: completes without error. Build time ~5–8 min.

If configure fails with "zimg not found": confirm `PKG_CONFIG_PATH` is set by checking `docker run --rm test-base env | grep PKG_CONFIG_PATH`.

- [ ] **Step 3: Verify vspipe and VapourSynth library**

```bash
docker run --rm test-vapoursynth bash -c \
  "vspipe --version && ls /usr/local/lib/libvapoursynth.so*"
```

Expected:
```
VapourSynth Video Processing Library
...
/usr/local/lib/libvapoursynth.so  /usr/local/lib/libvapoursynth.so.72  ...
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add zimg 3.0.5 + VapourSynth R72 build stage"
```

---

## Task 7: Add build-ffmpeg stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-ffmpeg stage to Dockerfile.stack**

```dockerfile
FROM base AS build-ffmpeg

COPY --from=build-svtav1  /usr/local /usr/local
COPY --from=build-libaom  /usr/local /usr/local
COPY --from=build-libvmaf /usr/local /usr/local
RUN ldconfig

RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.0.1 && \
    ./configure \
        --prefix=/usr/local \
        --enable-gpl \
        --enable-shared \
        --disable-static \
        --disable-doc \
        --enable-libsvtav1 \
        --enable-libaom \
        --enable-libvmaf && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/ffmpeg*
```

Note: `--enable-gpl` is required by FFmpeg when using `--enable-libsvtav1`. `--disable-static` and `--disable-doc` reduce build time and image size.

- [ ] **Step 2: Build to build-ffmpeg target**

```bash
docker build --target build-ffmpeg -f Dockerfile.stack -t test-ffmpeg .
```

Expected: completes without error. Build time ~10–15 min.

- [ ] **Step 3: Verify FFmpeg has the required encoders**

```bash
docker run --rm test-ffmpeg bash -c \
  "/usr/local/bin/ffmpeg -version 2>&1 | head -2 && \
   /usr/local/bin/ffmpeg -version 2>&1 | grep -E 'libsvtav1|libaom|libvmaf'"
```

Expected:
```
ffmpeg version 8.0.1 ...
...--enable-libsvtav1 --enable-libaom --enable-libvmaf...
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add FFmpeg 8.0.1 build stage with SVT-AV1, libaom, libvmaf"
```

---

## Task 8: Create patches/av1an-vmaf.py

**Files:**
- Create: `patches/av1an-vmaf.py`

**Background:** In av1an v0.5.2 (`av1an-core/src/metrics/vmaf.rs`), the VMAF model path logic is inverted in two functions (`run_vmaf` and `run_vmaf_weighted`). When a `.json` file path is provided as the model, the code uses the builtin `version=` string and ignores the path. The `.json` and non-`.json` branches are swapped. This patch fixes both functions.

- [ ] **Step 1: Create patches/ directory**

```bash
mkdir -p patches
```

- [ ] **Step 2: Write patches/av1an-vmaf.py**

```python
#!/usr/bin/env python3
"""Fix inverted VMAF model path logic in av1an-core/src/metrics/vmaf.rs.

Bug: when a model path ending in .json is provided, av1an uses the builtin
version= string instead of path=. The .json / non-.json branches are swapped
in both run_vmaf and run_vmaf_weighted.
"""
import sys
from pathlib import Path

target = Path("av1an-core/src/metrics/vmaf.rs")
src = target.read_text()

# ── Fix 1: run_vmaf ────────────────────────────────────────────────────────────
old_run_vmaf = r'''        let model_path = if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!("path={}", ffmpeg::escape_path_in_filter(&model)?)
        };'''

new_run_vmaf = r'''        let model_path = if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!("path={}", ffmpeg::escape_path_in_filter(&model)?)
        } else {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        };'''

if old_run_vmaf not in src:
    print("PATCH FAILED: run_vmaf model_path block not found in vmaf.rs", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_run_vmaf, new_run_vmaf, 1)
print("Patched: run_vmaf model_path logic")

# ── Fix 2: run_vmaf_weighted ───────────────────────────────────────────────────
old_weighted = r'''    let model_str = if let Some(model) = model {
        if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!(
                "path={}{}",
                ffmpeg::escape_path_in_filter(&model)?,
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        }'''

new_weighted = r'''    let model_str = if let Some(model) = model {
        if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "path={}{}",
                ffmpeg::escape_path_in_filter(&model)?,
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        }'''

if old_weighted not in src:
    print("PATCH FAILED: run_vmaf_weighted model_str block not found in vmaf.rs", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_weighted, new_weighted, 1)
print("Patched: run_vmaf_weighted model_str logic")

target.write_text(src)
print("Done: vmaf.rs patched successfully.")
```

- [ ] **Step 3: Commit**

```bash
git add patches/av1an-vmaf.py
git commit -m "feat: add av1an VMAF model path inversion fix patch"
```

---

## Task 9: Add build-lsmash stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-lsmash stage to Dockerfile.stack**

```dockerfile
FROM base AS build-lsmash

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

RUN git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/AkarinVS/L-SMASH-Works.git /src/lsmash && \
    meson setup /src/lsmash/VapourSynth/build /src/lsmash/VapourSynth \
        --buildtype=release \
        --prefix=/usr/local && \
    ninja -C /src/lsmash/VapourSynth/build && \
    ninja -C /src/lsmash/VapourSynth/build install && \
    ldconfig && \
    rm -rf /src
```

Note: `--recurse-submodules --shallow-submodules` clones the L-SMASH dependency bundled as a submodule without fetching full history. The plugin `.so` installs to `/usr/local/lib/vapoursynth/`.

- [ ] **Step 2: Build to build-lsmash target**

```bash
docker build --target build-lsmash -f Dockerfile.stack -t test-lsmash .
```

Expected: completes without error. Build time ~3–5 min.

- [ ] **Step 3: Verify the VapourSynth plugin is installed**

```bash
docker run --rm test-lsmash bash -c "ls /usr/local/lib/vapoursynth/"
```

Expected (filename may vary slightly):
```
libvslsmashsource.so
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add L-SMASH-Works VapourSynth plugin build stage"
```

---

## Task 10: Add build-av1an stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-av1an stage to Dockerfile.stack**

```dockerfile
FROM base AS build-av1an

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

COPY patches/av1an-vmaf.py /patches/av1an-vmaf.py

RUN git clone --depth 1 --branch v0.5.2 \
        https://github.com/master-of-zen/Av1an.git /src/av1an && \
    cd /src/av1an && \
    python3 /patches/av1an-vmaf.py && \
    cargo build --release && \
    cp target/release/av1an /usr/local/bin/ && \
    rm -rf /src
```

The default cargo features for av1an v0.5.2 include VapourSynth support. The `vapoursynth` crate finds the library via `PKG_CONFIG_PATH=/usr/local/lib/pkgconfig` (set in base ENV).

If the build fails with "vapoursynth not found via pkg-config", check:
```bash
docker run --rm test-vapoursynth ls /usr/local/lib/pkgconfig/vapoursynth*.pc
```
If missing, the VapourSynth build didn't install pkg-config files — re-check the configure prefix.

- [ ] **Step 2: Build to build-av1an target**

```bash
docker build --target build-av1an -f Dockerfile.stack -t test-av1an .
```

Expected: completes without error. Build time ~15–20 min (Rust compile).

- [ ] **Step 3: Verify av1an binary**

```bash
docker run --rm test-av1an bash -c "av1an --version"
```

Expected:
```
0.5.2
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add av1an 0.5.2 build stage with VMAF patch applied"
```

---

## Task 11: Add build-ab-av1 stage

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append build-ab-av1 stage to Dockerfile.stack**

```dockerfile
FROM base AS build-ab-av1

RUN cargo install ab-av1 --version 0.10.3 --root /usr/local
```

`--root /usr/local` installs the binary to `/usr/local/bin/ab-av1`. ab-av1 is pure Rust with no native library dependencies beyond what cargo fetches.

- [ ] **Step 2: Build to build-ab-av1 target**

```bash
docker build --target build-ab-av1 -f Dockerfile.stack -t test-ab-av1 .
```

Expected: completes without error. Build time ~5–10 min.

- [ ] **Step 3: Verify ab-av1 binary**

```bash
docker run --rm test-ab-av1 bash -c "/usr/local/bin/ab-av1 --version"
```

Expected:
```
ab-av1 0.10.3
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add ab-av1 0.10.3 build stage"
```

---

## Task 12: Add final stage to Dockerfile.stack

**Files:**
- Modify: `Dockerfile.stack`

- [ ] **Step 1: Append final stage to Dockerfile.stack**

```dockerfile
FROM base AS final

COPY --from=build-svtav1      /usr/local /usr/local
COPY --from=build-libaom      /usr/local /usr/local
COPY --from=build-libvmaf     /usr/local /usr/local
COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
COPY --from=build-lsmash      /usr/local /usr/local
COPY --from=build-av1an       /usr/local /usr/local
COPY --from=build-ab-av1      /usr/local /usr/local

RUN ldconfig && \
    mkdir -p /etc/vapoursynth && \
    echo "SystemPluginDir=/usr/local/lib/vapoursynth" > /etc/vapoursynth/vapoursynth.conf
```

- [ ] **Step 2: Build the complete Dockerfile.stack**

```bash
docker build --target final -f Dockerfile.stack -t ghcr.io/empaa/av1-stack:latest .
```

Expected: completes without error. BuildKit runs independent stages in parallel.
Full cold build: ~40 min. Subsequent cached builds: ~5 min.

- [ ] **Step 3: Verify all binaries and components**

```bash
docker run --rm ghcr.io/empaa/av1-stack:latest bash -c "
  echo '=== av1an ===' && av1an --version &&
  echo '=== ab-av1 ===' && ab-av1 --version &&
  echo '=== ffmpeg ===' && ffmpeg -version 2>&1 | head -1 &&
  echo '=== ffmpeg encoders ===' && ffmpeg -encoders 2>/dev/null | grep -E 'libsvtav1|libaom' &&
  echo '=== vspipe ===' && vspipe --version 2>&1 | head -1 &&
  echo '=== lsmash plugin ===' && ls /usr/local/lib/vapoursynth/ &&
  echo '=== vmaf models ===' && ls /usr/local/share/vmaf/*.json | wc -l &&
  echo '=== vapoursynth.conf ===' && cat /etc/vapoursynth/vapoursynth.conf
"
```

Expected:
```
=== av1an ===
0.5.2
=== ab-av1 ===
ab-av1 0.10.3
=== ffmpeg ===
ffmpeg version 8.0.1 ...
=== ffmpeg encoders ===
 V..... libsvtav1 ...
 V..... libaom-av1 ...
=== vspipe ===
VapourSynth ...
=== lsmash plugin ===
libvslsmashsource.so
=== vmaf models ===
4
=== vapoursynth.conf ===
SystemPluginDir=/usr/local/lib/vapoursynth
```

- [ ] **Step 4: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: add final stage — av1-stack image complete"
```

---

## Task 13: Create Dockerfile.tdarr and Dockerfile.tdarr_node

**Files:**
- Create: `Dockerfile.tdarr`
- Create: `Dockerfile.tdarr_node`

- [ ] **Step 1: Create Dockerfile.tdarr**

```dockerfile
FROM ghcr.io/haveagitgat/tdarr:latest

COPY --from=ghcr.io/empaa/av1-stack:latest /usr/local /usr/local
COPY --from=ghcr.io/empaa/av1-stack:latest /etc/vapoursynth /etc/vapoursynth

RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Create Dockerfile.tdarr_node**

```dockerfile
FROM ghcr.io/haveagitgat/tdarr_node:latest

COPY --from=ghcr.io/empaa/av1-stack:latest /usr/local /usr/local
COPY --from=ghcr.io/empaa/av1-stack:latest /etc/vapoursynth /etc/vapoursynth

RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
```

Note: `COPY --from=ghcr.io/empaa/av1-stack:latest` will use the locally-built image from Task 12 if it exists under that tag. No registry push needed for local builds.

- [ ] **Step 3: Build both images**

```bash
docker build -f Dockerfile.tdarr      -t ghcr.io/empaa/tdarr:latest      .
docker build -f Dockerfile.tdarr_node -t ghcr.io/empaa/tdarr_node:latest .
```

Expected: each completes in ~1–2 min (just COPY + apt).

- [ ] **Step 4: Verify the full stack inside tdarr_node**

```bash
docker run --rm ghcr.io/empaa/tdarr_node:latest bash -c "
  echo '=== av1an ===' && av1an --version &&
  echo '=== ab-av1 ===' && ab-av1 --version &&
  echo '=== ffmpeg path ===' && which ffmpeg &&
  echo '=== ffmpeg version ===' && ffmpeg -version 2>&1 | head -1 &&
  echo '=== mkvmerge ===' && mkvmerge --version | head -1
"
```

Expected:
```
=== av1an ===
0.5.2
=== ab-av1 ===
ab-av1 0.10.3
=== ffmpeg path ===
/usr/local/bin/ffmpeg
=== ffmpeg version ===
ffmpeg version 8.0.1 ...
=== mkvmerge ===
mkvmerge v... ('...')
```

Confirm `which ffmpeg` returns `/usr/local/bin/ffmpeg` (our build, not Tdarr's `/usr/bin/ffmpeg`).

- [ ] **Step 5: Commit**

```bash
git add Dockerfile.tdarr Dockerfile.tdarr_node
git commit -m "feat: add Dockerfile.tdarr and Dockerfile.tdarr_node"
```

---

## Task 14: Create build.sh

**Files:**
- Create: `build.sh`

- [ ] **Step 1: Write build.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"
BUILD_STACK=false

for arg in "$@"; do
    case "$arg" in
        --build-stack) BUILD_STACK=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ "$BUILD_STACK" = true ]; then
    echo "==> Building av1-stack from scratch (~45 min)..."
    docker build \
        --target final \
        -f Dockerfile.stack \
        -t "${REGISTRY}/av1-stack:latest" \
        .
else
    echo "==> Pulling av1-stack from GHCR..."
    docker pull "${REGISTRY}/av1-stack:latest"
fi

echo "==> Building tdarr images (~5 min)..."
docker build -f Dockerfile.tdarr      -t "${REGISTRY}/tdarr:latest"       .
docker build -f Dockerfile.tdarr_node -t "${REGISTRY}/tdarr_node:latest"  .

echo ""
echo "Done. Images built:"
echo "  ${REGISTRY}/tdarr:latest"
echo "  ${REGISTRY}/tdarr_node:latest"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x build.sh
```

- [ ] **Step 3: Test fast path (assumes av1-stack exists locally from Task 12)**

```bash
./build.sh
```

Expected:
```
==> Pulling av1-stack from GHCR...
...
==> Building tdarr images (~5 min)...
...
Done. Images built:
  ghcr.io/empaa/tdarr:latest
  ghcr.io/empaa/tdarr_node:latest
```

Note: The fast path (`./build.sh`) pulls from GHCR. On the first run before av1-stack is published, use `./build.sh --build-stack` instead.

- [ ] **Step 4: Commit**

```bash
git add build.sh
git commit -m "feat: add build.sh with fast path and --build-stack flag"
```

---

## Task 15: Create CI workflows and finalize build-and-publish.md

**Files:**
- Create: `.github/workflows/build-stack.yml`
- Create: `.github/workflows/build-tdarr.yml`
- Modify: `docs/build-and-publish.md`

- [ ] **Step 1: Create .github/workflows/ directory**

```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Create .github/workflows/build-stack.yml**

```yaml
name: Build AV1 Stack

on:
  workflow_dispatch:
  push:
    paths:
      - Dockerfile.stack
      - patches/**

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push av1-stack
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.stack
          target: final
          push: true
          tags: ghcr.io/empaa/av1-stack:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 3: Create .github/workflows/build-tdarr.yml**

```yaml
name: Build Tdarr Images

on:
  workflow_dispatch:
  push:
    paths:
      - Dockerfile.tdarr
      - Dockerfile.tdarr_node

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push tdarr
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.tdarr
          push: true
          tags: ghcr.io/empaa/tdarr:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Build and push tdarr_node
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.tdarr_node
          push: true
          tags: ghcr.io/empaa/tdarr_node:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 4: Fill in docs/build-and-publish.md**

Replace the placeholder comment in `docs/build-and-publish.md`:

```markdown
## GHCR Authentication (Local Builds)

To push images to GHCR from your machine:

1. Create a Personal Access Token at GitHub → Settings → Developer settings →
   Personal access tokens → Tokens (classic). Scopes needed: `write:packages`,
   `read:packages`, `delete:packages`.
2. Log in:
   ```bash
   echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

## Building and Publishing Locally

**Fast path** (reuses published av1-stack, only rebuilds Tdarr images, ~5 min):
```bash
./build.sh
docker push ghcr.io/empaa/tdarr:latest
docker push ghcr.io/empaa/tdarr_node:latest
```

**Full rebuild** (recompiles entire AV1 stack from source, ~45 min):
```bash
./build.sh --build-stack
docker push ghcr.io/empaa/av1-stack:latest
docker push ghcr.io/empaa/tdarr:latest
docker push ghcr.io/empaa/tdarr_node:latest
```

## CI Workflows

| Workflow | Trigger | What it builds | Duration |
|---|---|---|---|
| `build-stack.yml` | Push to `Dockerfile.stack` or `patches/**`, or manual dispatch | `ghcr.io/empaa/av1-stack:latest` | ~40 min cold, faster with GHA cache |
| `build-tdarr.yml` | Push to `Dockerfile.tdarr` or `Dockerfile.tdarr_node`, or manual dispatch | `tdarr:latest` and `tdarr_node:latest` | ~5 min |

Both workflows use `cache-from/cache-to: type=gha` so BuildKit stages are cached
between runs. The stack build in particular benefits significantly — individual
component stages are cached independently.
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-stack.yml .github/workflows/build-tdarr.yml docs/build-and-publish.md
git commit -m "feat: add CI workflows and build/publish documentation"
```
