# vs-nlm-ispc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the vs-nlm-ispc VapourSynth NLMeans denoiser plugin to the Docker images for both amd64 and arm64.

**Architecture:** A new `build-nlm-ispc` Dockerfile stage downloads the ISPC compiler (arch-specific binary), clones vs-nlm-ispc v2, and builds `libvsnlm_ispc.so`. The plugin is installed to `/usr/local/lib/vapoursynth/` where VapourSynth auto-loads it. The stage depends only on `build-vapoursynth` for headers and runs in parallel with `build-ffmpeg`, `build-av1an`, etc.

**Tech Stack:** CMake, ISPC v1.30.0, C++17, VapourSynth R73

**Spec:** `docs/superpowers/specs/2026-04-08-vs-nlm-ispc-design.md`

---

### Task 1: Add build-nlm-ispc stage to Dockerfile

**Files:**
- Modify: `Dockerfile:185-188` (insert new stage before `build-ab-av1`)

- [ ] **Step 1: Add the build-nlm-ispc stage**

Insert the following new stage in `Dockerfile` between `build-av1an` (ends at line 183) and `build-ab-av1` (starts at line 185). Place it after `build-av1an` and before `build-ab-av1`:

```dockerfile
FROM base AS build-nlm-ispc

COPY --from=build-vapoursynth /usr/local /usr/local
RUN ldconfig

ARG TARGETARCH

# Install ISPC compiler (build-time only, not carried to final images)
RUN case "${TARGETARCH}" in \
      amd64) ISPC_SUFFIX="linux" ;; \
      arm64) ISPC_SUFFIX="linux.aarch64" ;; \
    esac && \
    wget -q "https://github.com/ispc/ispc/releases/download/v1.30.0/ispc-v1.30.0-${ISPC_SUFFIX}.tar.gz" \
        -O /tmp/ispc.tar.gz && \
    tar xf /tmp/ispc.tar.gz -C /opt && \
    mv /opt/ispc-v1.30.0-* /opt/ispc && \
    rm /tmp/ispc.tar.gz

ENV PATH="/opt/ispc/bin:${PATH}"

# vs-nlm-ispc v2: ISPC-based NLMeans denoiser (amd64 SSE2/AVX2, arm64 NEON)
RUN git clone --depth 1 --branch v2 \
        https://github.com/AmusementClub/vs-nlm-ispc.git /src/nlm-ispc && \
    cd /src/nlm-ispc && \
    if [ "${TARGETARCH}" = "arm64" ]; then \
      ISPC_FLAGS='-DCMAKE_ISPC_INSTRUCTION_SETS=neon-i32x4 -DCMAKE_ISPC_FLAGS=--opt=fast-math'; \
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

- [ ] **Step 2: Add COPY line in av1-stack stage**

In the `av1-stack` stage (starts at line 189), add the following COPY line after `COPY --from=build-ab-av1` (line 198) and before the `ENV PYTHONPATH` line (line 200):

```dockerfile
COPY --from=build-nlm-ispc    /usr/local /usr/local
```

The resulting COPY block in `av1-stack` should be:

```dockerfile
COPY --from=build-svtav1      /usr/local /usr/local
COPY --from=build-libaom      /usr/local /usr/local
COPY --from=build-libvmaf     /usr/local /usr/local
COPY --from=build-vapoursynth /usr/local /usr/local
COPY --from=build-ffmpeg      /usr/local /usr/local
COPY --from=build-lsmash      /usr/local /usr/local
COPY --from=build-av1an       /usr/local /usr/local
COPY --from=build-ab-av1      /usr/local /usr/local
COPY --from=build-nlm-ispc    /usr/local /usr/local
```

- [ ] **Step 3: Build native arch to verify the stage compiles**

Run:
```bash
./build.sh --stack-only
```

Expected: Build succeeds. The `build-nlm-ispc` stage runs in parallel with `build-ffmpeg` and others. Binary checks for av1an, ab-av1, ffmpeg all pass.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile
git commit -m "feat: add vs-nlm-ispc VapourSynth NLMeans denoiser to build"
```

---

### Task 2: Add nlm_ispc verification to build.sh

**Files:**
- Modify: `build.sh:170-239` (add new check function after `run_binary_checks`)

- [ ] **Step 1: Add run_plugin_checks function**

Insert the following function in `build.sh` after the `run_binary_checks` function (after line 239, before `run_startup_check` at line 242):

```bash
run_plugin_checks() {
  local image="$1" label="$2" platform="$3"

  echo -n "Plugin checks ${label} (${platform})... "

  if docker run --rm --entrypoint "" --platform "${platform}" "${image}" \
      python3 -c "import vapoursynth as vs; core = vs.core; assert hasattr(core, 'nlm_ispc')" > /dev/null 2>&1; then
    add_result "$platform" "nlm_ispc (${label})" "OK"
  else
    add_result "$platform" "nlm_ispc (${label})" "FAILED"
  fi

  echo "done"
}
```

- [ ] **Step 2: Call run_plugin_checks alongside run_binary_checks**

In the main build loop (around line 596-613), add `run_plugin_checks` calls after each `run_binary_checks` call. There are four places:

After line 601 (`run_binary_checks "av1-stack:${arch}" "av1-stack" "$platform"`), add:
```bash
      run_plugin_checks "av1-stack:${arch}" "av1-stack" "$platform"
```

After line 607 (`run_binary_checks "tdarr:${arch}" "tdarr" "$platform"`), add:
```bash
      run_plugin_checks "tdarr:${arch}" "tdarr" "$platform"
```

After line 608 (`run_binary_checks "tdarr_node:${arch}" "tdarr_node" "$platform"`), add:
```bash
      run_plugin_checks "tdarr_node:${arch}" "tdarr_node" "$platform"
```

The resulting block (stack-only path) should look like:

```bash
    if [[ "$STACK_ONLY" == true ]]; then
      build_stack "$platform" "$arch"
      run_binary_checks "av1-stack:${arch}" "av1-stack" "$platform"
      run_plugin_checks "av1-stack:${arch}" "av1-stack" "$platform"
      if [[ "$ENCODE" == true ]]; then
        run_encode_test "av1-stack:${arch}" "${SCRIPT_DIR}/test/output/stack" "$platform"
      fi
    else
      build_tdarr "$platform" "$arch"
      run_binary_checks "tdarr:${arch}" "tdarr" "$platform"
      run_plugin_checks "tdarr:${arch}" "tdarr" "$platform"
      run_binary_checks "tdarr_node:${arch}" "tdarr_node" "$platform"
      run_plugin_checks "tdarr_node:${arch}" "tdarr_node" "$platform"
      run_startup_check "$platform" "$arch"
      if [[ "$ENCODE" == true ]]; then
        run_encode_test "tdarr:${arch}" "${SCRIPT_DIR}/test/output/tdarr" "$platform"
      fi
    fi
```

- [ ] **Step 3: Rebuild and verify checks pass**

Run:
```bash
./build.sh --stack-only
```

Expected: Build succeeds. Test summary includes `nlm_ispc (av1-stack)  OK` alongside the existing binary checks.

- [ ] **Step 4: Commit**

```bash
git add build.sh
git commit -m "test: add nlm_ispc plugin verification to build.sh"
```

---

### Task 3: Update documentation

**Files:**
- Modify: `docs/constraints.md` (append new entry)
- Modify: `docs/architecture.md:36-53` (update build stage graph)

- [ ] **Step 1: Add constraint entry**

Append to the end of `docs/constraints.md`:

```markdown

---

## vs-nlm-ispc v2 + ISPC v1.30.0

**Constraint:** Pin vs-nlm-ispc to tag v2 and ISPC compiler to v1.30.0.

**Why:** vs-nlm-ispc v2 is the latest release. ISPC v1.30.0 is the latest
stable release with arm64 Linux support. The ISPC instruction set flags differ
per architecture: arm64 requires `-DCMAKE_ISPC_INSTRUCTION_SETS="neon-i32x4"`,
amd64 uses defaults (SSE2/AVX2 multi-target).
```

- [ ] **Step 2: Update architecture build stage graph**

In `docs/architecture.md`, replace the build stage graph (lines 36-53) with:

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
 └── build-nlm-ispc ←── vapoursynth
          │
          ▼
      av1-stack  ←── all build-* stages (named target; test + layer source)
          │
          ├── tdarr       ←── ghcr.io/haveagitgat/tdarr + av1-stack
          └── tdarr_node  ←── ghcr.io/haveagitgat/tdarr_node + av1-stack
```

- [ ] **Step 3: Commit**

```bash
git add docs/constraints.md docs/architecture.md
git commit -m "docs: add vs-nlm-ispc constraint and update build stage graph"
```

---

### Task 4: Full build verification

- [ ] **Step 1: Run full native-arch build with all tests**

Run:
```bash
./build.sh
```

Expected: All checks pass, including:
- `nlm_ispc (av1-stack)  OK`
- `nlm_ispc (tdarr)  OK`
- `nlm_ispc (tdarr_node)  OK`

- [ ] **Step 2: Notify sibling repo**

Write a message to the sibling inbox confirming vs-nlm-ispc is available:

Create file `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-plugins/inbox/2026-04-08-from-tdarr-av1-nlm-ispc-ready.md`:

```markdown
---
from: tdarr-av1
date: 2026-04-08
---

## vs-nlm-ispc available in Docker images

The `nlm_ispc` VapourSynth plugin is now built and verified on both amd64 and arm64.

- **VapourSynth namespace:** `nlm_ispc`
- **Plugin location:** `/usr/local/lib/vapoursynth/libvsnlm_ispc.so` (auto-loaded)
- **Both architectures:** amd64 (SSE2/AVX2) and arm64 (NEON)
- **Verification:** `python3 -c "import vapoursynth as vs; core = vs.core; print(hasattr(core, 'nlm_ispc'))"`

No new binary paths. No changes to existing paths or APIs. The previous BM3D request inbox message can be cleared.
```

- [ ] **Step 3: Clean up own inbox**

Delete `~/.claude/projects/-Users-emilgrunden-ClaudeProjects-tdarr-av1/inbox/2026-04-08-from-tdarr-plugins-bm3d-request.md` (processed).
