# Design: Add vs-nlm-ispc VapourSynth Plugin

## Context

The sibling tdarr-plugins repo is replacing built-in encoder grain synthesis
(`--denoise-noise-level` / `--film-grain`) with a higher-quality pipeline:
NLMeans VapourSynth prefilter + av1an `--photon-noise`. This requires a
VapourSynth denoiser plugin installed in the Docker images.

BM3D was initially considered but dropped due to AVX2-only constraint (no arm64
support). vs-nlm-ispc uses ISPC which compiles to native NEON on arm64 and
SSE2/AVX2 on amd64, supporting both architectures.

## Package

- **Repository:** [AmusementClub/vs-nlm-ispc](https://github.com/AmusementClub/vs-nlm-ispc)
- **Version:** v2 (tag `v2`)
- **License:** MIT
- **Output:** `libvsnlm_ispc.so` (VapourSynth plugin, auto-loaded from SystemPluginDir)
- **VapourSynth namespace:** `nlm_ispc`

## Build-time dependencies

- **ISPC compiler v1.30.0** — prebuilt binaries for both architectures:
  - amd64: `ispc-v1.30.0-linux.tar.gz`
  - arm64: `ispc-v1.30.0-linux.aarch64.tar.gz`
  - Source: https://github.com/ispc/ispc/releases/tag/v1.30.0
- **CMake >= 3.20** (already in base stage)
- **C++17 compiler** (already in base stage)
- **VapourSynth headers** (from build-vapoursynth, discovered via pkg-config)

ISPC is used only at build time and is not carried into the final images.

## Dockerfile changes

### New stage: build-nlm-ispc

Depends on `build-vapoursynth` (for VapourSynth headers and pkg-config file).

```dockerfile
FROM base AS build-nlm-ispc

COPY --from=build-vapoursynth /usr/local /usr/local
RUN ldconfig

ARG TARGETARCH

# Install ISPC compiler (build-time only)
RUN case "${TARGETARCH}" in \
      amd64) ISPC_SUFFIX="linux" ;; \
      arm64) ISPC_SUFFIX="linux.aarch64" ;; \
    esac && \
    wget -q "https://github.com/ispc/ispc/releases/download/v1.30.0/ispc-v1.30.0-${ISPC_SUFFIX}.tar.gz" \
        -O /tmp/ispc.tar.gz && \
    tar xf /tmp/ispc.tar.gz -C /opt && \
    mv /opt/ispc-v1.30.0-* /opt/ispc && \
    rm /tmp/ispc.tar.gz

# Extracted directory name varies by arch (ispc-v1.30.0-linux vs
# ispc-v1.30.0-linux.aarch64). Glob to find it.
ENV PATH="/opt/ispc/bin:${PATH}"

# Build vs-nlm-ispc
RUN git clone --depth 1 --branch v2 \
        https://github.com/AmusementClub/vs-nlm-ispc.git /src/nlm-ispc && \
    cd /src/nlm-ispc && \
    if [ "${TARGETARCH}" = "arm64" ]; then \
      ISPC_FLAGS='-DCMAKE_ISPC_INSTRUCTION_SETS="neon-i32x4" -DCMAKE_ISPC_FLAGS="--opt=fast-math"'; \
    else \
      ISPC_FLAGS=""; \
    fi && \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        ${ISPC_FLAGS} && \
    cmake --build build -j$(nproc) && \
    mkdir -p /usr/local/lib/vapoursynth && \
    cp build/libvsnlm_ispc.so /usr/local/lib/vapoursynth/ && \
    rm -rf /src
```

The ISPC tarball extracts to an arch-specific directory name (`ispc-v1.30.0-linux`
vs `ispc-v1.30.0-linux.aarch64`). The `mv /opt/ispc-v1.30.0-* /opt/ispc` glob
normalizes this to a single known path.

### av1-stack stage

Add one COPY line alongside the existing build stage copies:

```dockerfile
COPY --from=build-nlm-ispc /usr/local /usr/local
```

No changes to the `tdarr` or `tdarr_node` targets — they already copy
everything from `av1-stack` via `COPY --from=av1-stack /usr/local /usr/local`.

## Updated build stage graph

```
base (Ubuntu 24.04 + build tools + Rust)
 ├── build-svtav1        (independent)
 ├── build-libaom        (independent)
 ├── build-libvmaf       (independent)
 ├── build-vapoursynth   (zimg built inside; independent)
 │
 ├── build-ffmpeg   ←── svtav1, libaom, libvmaf
 │
 ├── build-lsmash    ←── vapoursynth, ffmpeg
 ├── build-av1an     ←── vapoursynth, ffmpeg
 ├── build-ab-av1         (Rust only; independent)
 └── build-nlm-ispc ←── vapoursynth
          │
          ▼
      av1-stack  ←── all build-* stages
```

BuildKit runs build-nlm-ispc in parallel with build-ffmpeg, build-ab-av1, etc.

## Other file changes

### docs/constraints.md

New entry:

```markdown
## vs-nlm-ispc v2 + ISPC v1.30.0

**Constraint:** Pin vs-nlm-ispc to tag v2 and ISPC compiler to v1.30.0.

**Why:** vs-nlm-ispc v2 is the latest release. ISPC v1.30.0 is the latest
stable release with arm64 Linux support. The ISPC instruction set flags differ
per architecture: arm64 requires `-DCMAKE_ISPC_INSTRUCTION_SETS="neon-i32x4"`,
amd64 uses defaults.
```

### docs/architecture.md

Update the build stage graph to include `build-nlm-ispc ←── vapoursynth`.

### build.sh

Add nlm_ispc to the verification checks. The existing binary check pattern
doesn't apply (this is a VS plugin, not a binary). Add a new check that runs:

```bash
docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
    python3 -c "import vapoursynth as vs; core = vs.core; assert hasattr(core, 'nlm_ispc'), 'nlm_ispc not found'"
```

This runs on both amd64 and arm64.

## Verification

Both platforms:
```python
python3 -c "import vapoursynth as vs; core = vs.core; print(hasattr(core, 'nlm_ispc'))"
# Should print: True
```

## What does NOT change

- No new binary paths (plugin is auto-loaded from SystemPluginDir)
- No changes to CLAUDE.md binary path list
- No changes to vapoursynth.conf
- No changes to tdarr/tdarr_node Dockerfile targets
- No new runtime dependencies in the final images
