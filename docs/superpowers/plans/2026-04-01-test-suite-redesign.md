# Test Suite Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace five Dockerfiles and two test scripts with a single `Dockerfile` (multi-target) and two clean test scripts (`test-stack.sh`, `test-tdarr.sh`), eliminating the test/production divergence and the stale GHCR stack dependency.

**Architecture:** One `Dockerfile` at the root with targets `av1-stack`, `tdarr`, `tdarr_node`. The stack builds on Ubuntu 24.04 (matching tdarr's base), so no Python compat hacks are needed. Both test scripts and `publish.sh` target the same Dockerfile.

**Tech Stack:** Docker BuildKit multi-stage builds, bash, `docker buildx`

**Spec:** `docs/superpowers/specs/2026-04-01-test-suite-redesign.md`

---

## File Map

| Action | File |
|--------|------|
| Create | `Dockerfile` |
| Create | `test-stack.sh` |
| Rewrite | `test-tdarr.sh` |
| Rewrite | `publish.sh` |
| Delete | `Dockerfile.stack` |
| Delete | `Dockerfile.tdarr` |
| Delete | `Dockerfile.tdarr_node` |
| Delete | `Dockerfile.tdarr.test` |
| Delete | `Dockerfile.tdarr_node.test` |
| Delete | `test.sh` |
| Delete | `build.sh` |
| Update | `docs/constraints.md` |
| Update | `docs/architecture.md` |
| Update | `docs/build-and-publish.md` |

---

## Task 1: Write the new Dockerfile

**Files:**
- Create: `Dockerfile`

This merges all five existing Dockerfiles into one. Key changes vs the current `Dockerfile.stack`:
- Base OS: `ubuntu:22.04` → `ubuntu:24.04`
- `pip3 install` gains `--break-system-packages` (required by Ubuntu 24.04 / PEP 668)
- VapourSynth comment updated (Ubuntu 24.04 ships Python 3.12, not 3.10)
- `final` stage renamed to `av1-stack`
- `PYTHONPATH` updated from `python3.10` → `python3.12`
- Two new targets appended: `tdarr` and `tdarr_node` (no Python compat hacks needed since base now matches)

- [ ] **Write `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS base

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
    xxd \
    && ln -sf /usr/bin/cython3 /usr/bin/cython \
    && rm -rf /var/lib/apt/lists/*

# Install Rust stable
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

FROM base AS build-svtav1

RUN git clone --depth 1 --branch v4.1.0 \
        https://gitlab.com/AOMediaCodec/SVT-AV1.git /src/svtav1 && \
    cmake -S /src/svtav1 -B /src/svtav1/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/svtav1/build -j$(nproc) && \
    cmake --install /src/svtav1/build && \
    ldconfig && \
    rm -rf /src

FROM base AS build-libaom

RUN wget -q "https://storage.googleapis.com/aom-releases/libaom-3.13.2.tar.gz" \
        -O /tmp/libaom.tar.gz && \
    mkdir -p /src/aom && \
    tar -xf /tmp/libaom.tar.gz -C /src/aom --strip-components=1 && \
    rm /tmp/libaom.tar.gz && \
    cmake -S /src/aom -B /src/aom_build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/aom_build -j$(nproc) && \
    cmake --install /src/aom_build && \
    ldconfig && \
    rm -rf /src/aom /src/aom_build

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

FROM base AS build-vapoursynth

# Ubuntu 24.04 ships Python 3.12. VapourSynth R73 requires Cython 3.
# --break-system-packages required on Ubuntu 24.04 (PEP 668).
RUN apt-get update && apt-get install -y python3-pip --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --upgrade "cython>=3" \
    && ln -sf /usr/local/bin/cython /usr/bin/cython3

# Build zimg 3.0.6 first — VapourSynth depends on it
RUN git clone --depth 1 --branch release-3.0.6 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
    cd /src/zimg && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# MUST be R73 or later — av1an 0.5.2 uses vapoursynth-rs v0.5.1 which requires
# VSScript API v4. R72 only provides API v3 and will fail to load at runtime.
# Do not upgrade to R74 until it leaves RC.
RUN git clone --depth 1 --branch R73 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
    cd /src/vapoursynth && \
    ./autogen.sh && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-ffmpeg

COPY --from=build-svtav1  /usr/local /usr/local
COPY --from=build-libaom  /usr/local /usr/local
COPY --from=build-libvmaf /usr/local /usr/local
RUN ldconfig

RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.1 && \
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

FROM base AS build-lsmash

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

RUN apt-get update && apt-get install -y --no-install-recommends libxxhash-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v2.14.5 https://github.com/l-smash/l-smash.git /src/l-smash && \
    cd /src/l-smash && \
    ./configure --prefix=/usr/local --enable-shared && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /src/l-smash

# Use HomeOfAviSynthPlusEvolution fork — AkarinVS is incompatible with FFmpeg 5+
# (references AVStream.index_entries which was made private in FFmpeg commit cea7c19).
# Pinned to a specific commit for reproducibility; update intentionally when needed.
RUN git clone \
        https://github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works.git /src/lsmash && \
    git -C /src/lsmash checkout 0079a06ee384061ecdadd0de03df4e0493dd56ab && \
    meson setup /src/lsmash/VapourSynth/build /src/lsmash/VapourSynth \
        --buildtype=release \
        --prefix=/usr/local && \
    ninja -C /src/lsmash/VapourSynth/build && \
    ninja -C /src/lsmash/VapourSynth/build install && \
    ldconfig && \
    rm -rf /src

FROM base AS build-av1an

COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
RUN ldconfig

ENV VAPOURSYNTH_LIB_DIR=/usr/local/lib

COPY patches/av1an-vmaf.py /patches/av1an-vmaf.py

RUN git clone --depth 1 --branch v0.5.2 \
        https://github.com/master-of-zen/Av1an.git /src/av1an && \
    cd /src/av1an && \
    python3 /patches/av1an-vmaf.py && \
    cargo build --release && \
    cp target/release/av1an /usr/local/bin/ && \
    rm -rf /src

FROM base AS build-ab-av1

RUN cargo install ab-av1 --version 0.11.2 --root /usr/local

FROM ubuntu:24.04 AS av1-stack

COPY --from=build-svtav1      /usr/local /usr/local
COPY --from=build-libaom      /usr/local /usr/local
COPY --from=build-libvmaf     /usr/local /usr/local
COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
COPY --from=build-lsmash      /usr/local /usr/local
COPY --from=build-av1an       /usr/local /usr/local
COPY --from=build-ab-av1      /usr/local /usr/local

# Ubuntu 24.04 Python uses dist-packages; VapourSynth installs to site-packages.
# Set PYTHONPATH so getVSScriptAPI can import the vapoursynth module at runtime.
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages

RUN apt-get update && apt-get install -y --no-install-recommends mkvtoolnix \
    && rm -rf /var/lib/apt/lists/*

RUN ldconfig && \
    mkdir -p /etc/vapoursynth && \
    echo "SystemPluginDir=/usr/local/lib/vapoursynth" > /etc/vapoursynth/vapoursynth.conf

# av1an defaults to looking for vmaf_v0.6.1.json relative to CWD (/). Symlink
# to the installed model so the default path resolves without --vmaf-path.
RUN ln -sf /usr/local/share/vmaf/vmaf_v0.6.1.json /vmaf_v0.6.1.json \
    && ln -sf /usr/local/share/vmaf/vmaf_4k_v0.6.1.json /vmaf_4k_v0.6.1.json

FROM ghcr.io/haveagitgat/tdarr:latest AS tdarr
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*

FROM ghcr.io/haveagitgat/tdarr_node:latest AS tdarr_node
COPY --from=av1-stack /usr/local /usr/local
COPY --from=av1-stack /etc/vapoursynth /etc/vapoursynth
ENV PYTHONPATH=/usr/local/lib/python3.12/site-packages
RUN ldconfig && \
    apt-get update && \
    apt-get install -y mkvtoolnix && \
    rm -rf /var/lib/apt/lists/*
```

- [ ] **Commit**

```bash
git add Dockerfile
git commit -m "feat: add unified Dockerfile with av1-stack/tdarr/tdarr_node targets"
```

---

## Task 2: Build av1-stack target and verify

**Files:** none (validation only)

This step takes ~45 minutes on first run (full stack compile). It validates that Ubuntu 24.04 compiles cleanly and confirms the PYTHONPATH.

- [ ] **Build av1-stack for native arch**

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker buildx build \
  --platform "linux/${ARCH}" \
  --target av1-stack \
  --output "type=docker,name=av1-stack:${ARCH}" \
  .
```

Expected: build succeeds, image tagged `av1-stack:amd64` (or `arm64`).

If `pip3 install` fails with "externally-managed-environment", verify the `--break-system-packages` flag is present in the `build-vapoursynth` stage. If VapourSynth's `./configure` fails to find Python, ensure `python3-dev` is installed in the `base` stage.

- [ ] **Run binary checks**

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker run --rm --entrypoint "" av1-stack:${ARCH} av1an --version
docker run --rm --entrypoint "" av1-stack:${ARCH} ab-av1 --version
docker run --rm --entrypoint "" av1-stack:${ARCH} ffmpeg -version | head -1
```

Expected: all three print version strings. `av1an --version` output includes `VapourSynth Plugins` section.

- [ ] **Confirm PYTHONPATH path**

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker run --rm --entrypoint "" av1-stack:${ARCH} \
  find /usr/local/lib/python3.12 -name "vapoursynth.so" 2>/dev/null
```

Expected: `/usr/local/lib/python3.12/site-packages/vapoursynth.so`

If the file is found at `/usr/local/lib/python3.12/dist-packages/vapoursynth.so` instead, update `ENV PYTHONPATH` in `Dockerfile` (all three occurrences: `av1-stack`, `tdarr`, `tdarr_node` targets) from `site-packages` to `dist-packages`, then rebuild.

---

## Task 3: Write test-stack.sh

**Files:**
- Create: `test-stack.sh`

- [ ] **Write `test-stack.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
ENCODE=false
ALL_PLATFORMS=false
CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --clean)         CLEAN=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

native_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

build_image() {
  local platform="$1" arch="$2"
  echo "==> Building av1-stack (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --target av1-stack \
    --output "type=docker,name=av1-stack:${arch}" \
    .
}

run_binary_checks() {
  local platform="$1" arch="$2"
  local image="av1-stack:${arch}"
  local failed=0

  echo ""
  echo "Binary checks (${platform})..."
  for bin in "${BINARIES[@]}"; do
    printf "  %-12s" "$bin"
    local version_flag="--version"
    [[ "$bin" == "ffmpeg" ]] && version_flag="-version"
    if docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
        "$bin" $version_flag > /dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
      failed=$((failed + 1))
    fi
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed binary check(s) for ${platform}"
    return 1
  fi
  echo "All binary checks passed (${platform})"
}

run_encode_test() {
  local platform="$1" arch="$2"
  local image="av1-stack:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/stack"

  local -a SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "WARNING: No sample files in test/samples/ — skipping encode tests"
    return 0
  fi

  echo ""
  echo "Encode tests (${platform}, ${#SAMPLE_FILES[@]} sample(s))..."
  local failed=0
  local -a failures=()

  for sample in "${SAMPLE_FILES[@]}"; do
    local filename stem
    filename="$(basename "$sample")"
    stem="${filename%.*}"
    echo "  Sample: ${filename}"

    local container_exit=0
    docker run --rm --entrypoint "" \
      --platform "${platform}" \
      -v "${samples_dir}:/samples:ro" \
      -v "${output_dir}:/output" \
      "${image}" bash -c '
        set -e
        ffmpeg -y -ss 00:01:00 -t 60 -i "/samples/$1" -c copy "/output/$2_clip.mkv" 2>/dev/null
        av1an -i "/output/$2_clip.mkv" --encoder aom --target-quality 90 --verbose \
          -o "/output/$2_av1an_aom.mkv"
        av1an -i "/output/$2_clip.mkv" --encoder svt-av1 --target-quality 90 --verbose \
          -o "/output/$2_av1an_svtav1.mkv"
        ab-av1 auto-encode -i "/output/$2_clip.mkv" --min-vmaf 90 \
          -o "/output/$2_ab-av1.mkv"
      ' -- "$filename" "$stem" \
      || container_exit=$?

    for suffix in _av1an_aom.mkv _av1an_svtav1.mkv _ab-av1.mkv; do
      local outfile="${output_dir}/${stem}${suffix}"
      local label="${stem}${suffix}"
      printf "    %-44s" "$label"
      if [[ $container_exit -ne 0 ]]; then
        echo "FAILED (container exited ${container_exit})"
        failures+=("${label}: container exited ${container_exit}")
        failed=$((failed + 1))
      elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
        echo "OK"
      else
        echo "FAILED (missing or empty)"
        failures+=("${label}: output missing or empty")
        failed=$((failed + 1))
      fi
    done
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: ${failed} encode check(s):"
    for f in "${failures[@]}"; do echo "  - $f"; done
    return 1
  fi
  echo "All encode tests passed (${platform})"
}

# ── clean ─────────────────────────────────────────────────────────────────────

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning..."
  docker rmi av1-stack:amd64 2>/dev/null || true
  docker rmi av1-stack:arm64 2>/dev/null || true
  find "${SCRIPT_DIR}/test/output/stack" -mindepth 1 ! -name '.gitkeep' -delete
  echo "Done."
  exit 0
fi

# ── run ───────────────────────────────────────────────────────────────────────

OVERALL_FAILED=0

if [[ "$ALL_PLATFORMS" == true ]]; then
  PLATFORMS=(linux/amd64 linux/arm64)
else
  ARCH=$(native_arch)
  PLATFORMS=("linux/${ARCH}")
fi

for platform in "${PLATFORMS[@]}"; do
  arch="${platform#linux/}"
  build_image "$platform" "$arch"
  run_binary_checks "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  if [[ "$ENCODE" == true ]]; then
    run_encode_test "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  fi
done

echo ""
if [[ $OVERALL_FAILED -gt 0 ]]; then
  echo "FAILED: ${OVERALL_FAILED} check(s) failed"
  exit 1
fi

if [[ "$ALL_PLATFORMS" == true ]]; then
  echo "All checks passed (linux/amd64, linux/arm64)"
else
  echo "All checks passed"
fi
```

- [ ] **Make executable and commit**

```bash
chmod +x test-stack.sh
git add test-stack.sh
git commit -m "feat: add test-stack.sh"
```

---

## Task 4: Run test-stack.sh

**Files:** none (validation only)

BuildKit reuses cached layers from Task 2 — this should be near-instant.

- [ ] **Run test-stack.sh**

```bash
./test-stack.sh
```

Expected output ends with: `All checks passed`

If `av1an` binary check fails, run with entrypoint bypass to see the error:
```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker run --rm --entrypoint "" av1-stack:${ARCH} av1an --version 2>&1
```

---

## Task 5: Write test-tdarr.sh

**Files:**
- Rewrite: `test-tdarr.sh`

- [ ] **Write `test-tdarr.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

BINARIES=(av1an ab-av1 ffmpeg)
IMAGES=(tdarr tdarr_node)
ENCODE=false
ALL_PLATFORMS=false
CLEAN=false

for arg in "$@"; do
  case "$arg" in
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --clean)         CLEAN=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────

native_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

build_image() {
  local name="$1" platform="$2" arch="$3"
  echo "==> Building ${name} (${platform})..."
  docker buildx build \
    --platform "${platform}" \
    --target "${name}" \
    --output "type=docker,name=${name}:${arch}" \
    .
}

run_binary_checks() {
  local name="$1" platform="$2" arch="$3"
  local image="${name}:${arch}"
  local failed=0

  echo ""
  echo "Binary checks for ${name} (${platform})..."
  for bin in "${BINARIES[@]}"; do
    printf "  %-12s" "$bin"
    local version_flag="--version"
    [[ "$bin" == "ffmpeg" ]] && version_flag="-version"
    if docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
        "$bin" $version_flag > /dev/null 2>&1; then
      echo "OK"
    else
      echo "FAILED"
      failed=$((failed + 1))
    fi
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: $failed binary check(s) for ${name} (${platform})"
    return 1
  fi
  echo "All binary checks passed for ${name} (${platform})"
}

run_startup_check() {
  local arch="$1"
  local server_image="tdarr:${arch}"
  local node_image="tdarr_node:${arch}"
  local net="tdarr-test-net-$$"
  local server_cid="" node_cid="" state="" ok=false

  echo ""
  echo "Startup check (tdarr + tdarr_node)..."

  docker network create "$net" > /dev/null 2>&1 || true

  if docker network inspect "$net" > /dev/null 2>&1; then
    server_cid=$(docker run -d \
      --network "$net" \
      --name "tdarr-server-$$" \
      -e serverIP=0.0.0.0 \
      -e serverPort=8266 \
      -e webUIPort=8265 \
      -e internalNode=false \
      "${server_image}") || true
  fi

  if [[ -n "$server_cid" ]]; then
    for i in $(seq 1 30); do
      if docker exec "$server_cid" curl -sf http://localhost:8265 > /dev/null 2>&1; then
        ok=true
        break
      fi
      sleep 1
    done
  fi

  if [[ "$ok" == true ]]; then
    node_cid=$(docker run -d \
      --network "$net" \
      -e serverIP="tdarr-server-$$" \
      -e serverPort=8266 \
      -e nodeName=test-node \
      "${node_image}") || true

    if [[ -n "$node_cid" ]]; then
      sleep 10
      state=$(docker inspect --format '{{.State.Status}}' "$node_cid" 2>/dev/null \
        || echo "missing")
    fi
  fi

  # Unconditional cleanup
  [[ -n "$node_cid"   ]] && { docker stop "$node_cid"   > /dev/null 2>&1 || true
                               docker rm   "$node_cid"   > /dev/null 2>&1 || true; }
  [[ -n "$server_cid" ]] && { docker stop "$server_cid" > /dev/null 2>&1 || true
                               docker rm   "$server_cid" > /dev/null 2>&1 || true; }
  docker rm -f "tdarr-server-$$" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true

  printf "  %-24s" "tdarr HTTP"
  if [[ "$ok" != true ]]; then
    echo "FAILED (did not respond within 30s)"
    return 1
  fi
  echo "OK"

  printf "  %-24s" "tdarr_node alive"
  if [[ "${state}" == "running" ]]; then
    echo "OK"
    return 0
  else
    echo "FAILED (state: ${state:-unknown})"
    return 1
  fi
}

run_encode_test() {
  local arch="$1"
  local image="tdarr:${arch}"
  local samples_dir="${SCRIPT_DIR}/test/samples"
  local output_dir="${SCRIPT_DIR}/test/output/tdarr"

  local -a SAMPLE_FILES=()
  while IFS= read -r -d '' f; do
    SAMPLE_FILES+=("$f")
  done < <(find "$samples_dir" -maxdepth 1 -type f ! -name '.gitkeep' ! -name '.*' -print0)

  if [[ ${#SAMPLE_FILES[@]} -eq 0 ]]; then
    echo "WARNING: No sample files in test/samples/ — skipping encode tests"
    return 0
  fi

  echo ""
  echo "Encode tests (tdarr, ${#SAMPLE_FILES[@]} sample(s))..."
  local failed=0
  local -a failures=()

  for sample in "${SAMPLE_FILES[@]}"; do
    local filename stem
    filename="$(basename "$sample")"
    stem="${filename%.*}"
    echo "  Sample: ${filename}"

    local container_exit=0
    docker run --rm --entrypoint "" \
      -v "${samples_dir}:/samples:ro" \
      -v "${output_dir}:/output" \
      "${image}" bash -c '
        set -e
        ffmpeg -y -ss 00:01:00 -t 60 -i "/samples/$1" -c copy "/output/$2_clip.mkv" 2>/dev/null
        av1an -i "/output/$2_clip.mkv" --encoder aom --target-quality 90 --verbose \
          -o "/output/$2_av1an_aom.mkv"
        av1an -i "/output/$2_clip.mkv" --encoder svt-av1 --target-quality 90 --verbose \
          -o "/output/$2_av1an_svtav1.mkv"
        ab-av1 auto-encode -i "/output/$2_clip.mkv" --min-vmaf 90 \
          -o "/output/$2_ab-av1.mkv"
      ' -- "$filename" "$stem" \
      || container_exit=$?

    for suffix in _av1an_aom.mkv _av1an_svtav1.mkv _ab-av1.mkv; do
      local outfile="${output_dir}/${stem}${suffix}"
      local label="${stem}${suffix}"
      printf "    %-44s" "$label"
      if [[ $container_exit -ne 0 ]]; then
        echo "FAILED (container exited ${container_exit})"
        failures+=("${label}: container exited ${container_exit}")
        failed=$((failed + 1))
      elif [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
        echo "OK"
      else
        echo "FAILED (missing or empty)"
        failures+=("${label}: output missing or empty")
        failed=$((failed + 1))
      fi
    done
  done

  if [[ $failed -gt 0 ]]; then
    echo "FAILED: ${failed} encode check(s):"
    for f in "${failures[@]}"; do echo "  - $f"; done
    return 1
  fi
  echo "All encode tests passed"
}

# ── clean ─────────────────────────────────────────────────────────────────────

if [[ "$CLEAN" == true ]]; then
  echo "==> Cleaning..."
  for name in tdarr tdarr_node; do
    docker rmi "${name}:amd64" 2>/dev/null || true
    docker rmi "${name}:arm64" 2>/dev/null || true
  done
  find "${SCRIPT_DIR}/test/output/tdarr"      -mindepth 1 ! -name '.gitkeep' -delete
  find "${SCRIPT_DIR}/test/output/tdarr_node" -mindepth 1 ! -name '.gitkeep' -delete
  echo "Done."
  exit 0
fi

# ── run ───────────────────────────────────────────────────────────────────────

OVERALL_FAILED=0

if [[ "$ALL_PLATFORMS" == true ]]; then
  PLATFORMS=(linux/amd64 linux/arm64)
else
  ARCH=$(native_arch)
  PLATFORMS=("linux/${ARCH}")
fi

for platform in "${PLATFORMS[@]}"; do
  arch="${platform#linux/}"
  for name in "${IMAGES[@]}"; do
    build_image "$name" "$platform" "$arch"
    run_binary_checks "$name" "$platform" "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
  done
  if run_startup_check "$arch"; then
    if [[ "$ENCODE" == true ]]; then
      run_encode_test "$arch" || OVERALL_FAILED=$((OVERALL_FAILED + 1))
    fi
  else
    OVERALL_FAILED=$((OVERALL_FAILED + 1))
    [[ "$ENCODE" == true ]] && echo "Skipping encode test (startup failed)"
  fi
done

echo ""
if [[ $OVERALL_FAILED -gt 0 ]]; then
  echo "FAILED: ${OVERALL_FAILED} check(s) failed"
  exit 1
fi

if [[ "$ALL_PLATFORMS" == true ]]; then
  echo "All checks passed (linux/amd64, linux/arm64)"
else
  echo "All checks passed"
fi
```

- [ ] **Make executable and commit**

```bash
chmod +x test-tdarr.sh
git add test-tdarr.sh
git commit -m "feat: rewrite test-tdarr.sh — unified Dockerfile, native-arch default"
```

---

## Task 6: Run test-tdarr.sh

**Files:** none (validation only)

The `av1-stack` layers are cached from Task 2. Only the `tdarr` and `tdarr_node` layers rebuild (~5 min, just pulls base images and installs mkvtoolnix).

- [ ] **Run test-tdarr.sh**

```bash
./test-tdarr.sh
```

Expected output ends with: `All checks passed`

If a binary check fails, debug with:
```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker run --rm --entrypoint "" tdarr:${ARCH} av1an --version 2>&1
```

---

## Task 7: Write publish.sh

**Files:**
- Rewrite: `publish.sh`

- [ ] **Write `publish.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"
ALL_PLATFORMS=false

for arg in "$@"; do
  case "$arg" in
    --all-platforms) ALL_PLATFORMS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ "$ALL_PLATFORMS" == true ]]; then
  PLATFORM_ARGS=(--platform linux/amd64,linux/arm64)
  PLATFORM_LABEL="linux/amd64 + linux/arm64"
else
  case "$(uname -m)" in
    x86_64)        NATIVE="linux/amd64" ;;
    aarch64|arm64) NATIVE="linux/arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  PLATFORM_ARGS=(--platform "${NATIVE}")
  PLATFORM_LABEL="${NATIVE}"
fi

echo "==> Publishing to ${REGISTRY} (${PLATFORM_LABEL})..."

for target in tdarr tdarr_node; do
  echo "==> Building and pushing ${target}..."
  docker buildx build \
    "${PLATFORM_ARGS[@]}" \
    --target "${target}" \
    --push \
    -t "${REGISTRY}/${target}:latest" \
    .
done

echo ""
echo "Done. Images published:"
echo "  ${REGISTRY}/tdarr:latest"
echo "  ${REGISTRY}/tdarr_node:latest"
```

- [ ] **Make executable and commit**

```bash
chmod +x publish.sh
git add publish.sh
git commit -m "feat: rewrite publish.sh — native-arch default, --all-platforms flag"
```

---

## Task 8: Delete old files

**Files:**
- Delete: `Dockerfile.stack`, `Dockerfile.tdarr`, `Dockerfile.tdarr_node`, `Dockerfile.tdarr.test`, `Dockerfile.tdarr_node.test`, `test.sh`, `build.sh`

- [ ] **Delete the old files and commit**

```bash
git rm Dockerfile.stack Dockerfile.tdarr Dockerfile.tdarr_node \
       Dockerfile.tdarr.test Dockerfile.tdarr_node.test \
       test.sh build.sh
git commit -m "chore: remove superseded Dockerfiles and scripts"
```

---

## Task 9: Update docs

**Files:**
- Modify: `docs/constraints.md`
- Modify: `docs/architecture.md`
- Modify: `docs/build-and-publish.md`

- [ ] **Update `docs/constraints.md`** — change the Tdarr base OS entry:

Replace:
```
**Tdarr image base:** Ubuntu 22.04 (Jammy)
**tdarr_node image base:** Ubuntu 22.04 (Jammy)
```
With:
```
**Tdarr image base:** Ubuntu 24.04 (Noble)
**tdarr_node image base:** Ubuntu 24.04 (Noble)
```

Also update the constraint description to reflect that the stack now builds on Ubuntu 24.04 to match, so no glibc mismatch can occur.

- [ ] **Update `docs/architecture.md`** — replace the "AV1 Stack Distribution via av1-stack Image" section:

Replace the entire section starting with `## AV1 Stack Distribution via av1-stack Image` with:

```markdown
## Single Dockerfile, Multiple Targets

The AV1 stack and both Tdarr images are built from a single `Dockerfile` with three
named targets: `av1-stack`, `tdarr`, and `tdarr_node`.

The `tdarr` and `tdarr_node` targets copy `/usr/local` and `/etc/vapoursynth` from
`av1-stack` and set `PYTHONPATH=/usr/local/lib/python3.12/site-packages`. No
compatibility shims are needed: the stack base OS (Ubuntu 24.04) matches the Tdarr
base OS exactly.

**FFmpeg shadowing:** Our FFmpeg at `/usr/local/bin/ffmpeg` takes precedence over
Tdarr's bundled `/usr/bin/ffmpeg` via standard `$PATH` ordering.
```

Replace the build stage graph with the updated one:

```markdown
## Build Stage Graph

```
base (Ubuntu 24.04 + build tools + Rust)
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
      av1-stack  ←── all build-* stages  (test-stack.sh targets this)
          │
          ├── tdarr       ←── av1-stack + ghcr.io/haveagitgat/tdarr
          └── tdarr_node  ←── av1-stack + ghcr.io/haveagitgat/tdarr_node
```

BuildKit runs independent stages in parallel automatically.
```

- [ ] **Replace `docs/build-and-publish.md`** entirely:

```markdown
# Build and Publish

Read this before any build, test, or GHCR publish work.

---

## Local test

**Pre-merge** — builds native arch, runs binary version checks + startup test:
```bash
./test-stack.sh && ./test-tdarr.sh
```

**Pre-release** — same plus real encode tests against `test/samples/`:
```bash
./test-stack.sh --encode && ./test-tdarr.sh --encode
```

Place sample video files (≥2 min long) in `test/samples/` before running `--encode`.
Outputs land in `test/output/stack/` and `test/output/tdarr/` for inspection.

**Both platforms:**
```bash
./test-stack.sh --all-platforms && ./test-tdarr.sh --all-platforms
```

**Cache management:**
```bash
./test-stack.sh --clean
./test-tdarr.sh --clean
```

## Publish to GHCR

Builds and pushes `tdarr` and `tdarr_node` to GHCR. Always builds the full AV1 stack
from source — no pre-built stack image is used or published.

**One-time setup per machine:**

1. Create a PAT at GitHub → Settings → Developer settings → Personal access tokens
   (classic) with `write:packages` scope, then:
```bash
echo <TOKEN> | docker login ghcr.io -u <your-github-username> --password-stdin
```

2. Create the multi-platform buildx builder (persists across sessions):
```bash
docker buildx create --name multiplatform --driver docker-container --use
```

**Publish (native arch only):**
```bash
./publish.sh
```

**Publish (both platforms — use from M1 Mac):**
```bash
./publish.sh --all-platforms
```

## Merge workflow

1. Run `./test-stack.sh && ./test-tdarr.sh` locally — must pass
2. Open PR from `dev` to `main`
3. Merge

## Release workflow

1. Run `./test-stack.sh --encode && ./test-tdarr.sh --encode` — must pass
2. Merge `dev` → `main`
3. Run `./publish.sh --all-platforms` (~45 min from Mac)

## Binary list

`test-stack.sh` and `test-tdarr.sh` both check: `av1an`, `ab-av1`, `ffmpeg`.
Update when new binaries are added to the Dockerfile.
```

- [ ] **Commit docs**

```bash
git add docs/constraints.md docs/architecture.md docs/build-and-publish.md
git commit -m "docs: update for unified Dockerfile and new test/publish scripts"
```

---

## Task 10: Push to dev

- [ ] **Push**

```bash
git push origin dev
```

Expected: push succeeds, branch `dev` is up to date.
