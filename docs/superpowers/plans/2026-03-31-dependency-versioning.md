# Dependency Versioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update all `Dockerfile.stack` dependencies to current stable versions, fix the wrong L-SMASH-Works fork, switch libaom to the official tarball source, and correct stale entries in `docs/constraints.md`.

**Architecture:** All changes are in `Dockerfile.stack` (build instructions) and `docs/constraints.md` (documentation). No new files are created. Verification is done by running `./test.sh` which builds the stack for amd64 and arm64 and checks that `av1an`, `ab-av1`, and `ffmpeg` binaries respond to `--version`.

**Tech Stack:** Docker multi-stage build, Ubuntu 22.04, Rust (cargo), cmake/ninja, meson

---

## Files Modified

- `Dockerfile.stack` — all version bumps, fork switch, libaom tarball, l-smash pin, explanatory comments
- `docs/constraints.md` — VapourSynth and SVT-AV1+FFmpeg constraint entries updated

---

### Task 1: Fix VapourSynth from R72 to R73

**Files:**
- Modify: `Dockerfile.stack` (build-vapoursynth stage)

The R72 pin was wrong. av1an 0.5.2 uses vapoursynth-rs 0.5.1 which requires VSScript API v4. R72 only provides API v3 and will fail at runtime. R73 is the current stable release.

- [ ] **Step 1: Update the VapourSynth clone in `build-vapoursynth` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN git clone --depth 1 --branch R72 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
```

Replace with:
```dockerfile
# MUST be R73 or later — av1an 0.5.2 uses vapoursynth-rs v0.5.1 which requires
# VSScript API v4. R72 only provides API v3 and will fail to load at runtime.
# Do not upgrade to R74 until it leaves RC.
RUN git clone --depth 1 --branch R73 \
        https://github.com/vapoursynth/vapoursynth.git /src/vapoursynth && \
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "fix: upgrade VapourSynth R72 → R73 (av1an 0.5.2 requires VSScript API v4)"
```

---

### Task 2: Fix L-SMASH-Works fork and pin to a commit

**Files:**
- Modify: `Dockerfile.stack` (build-lsmash stage)

The current fork (`AkarinVS/L-SMASH-Works`) uses `AVStream.index_entries` which was made private in FFmpeg commit `cea7c19` (FFmpeg 5+). `HomeOfAviSynthPlusEvolution/L-SMASH-Works` maintains FFmpeg 6/7/8 compatibility and is the correct fork.

- [ ] **Step 1: Replace the L-SMASH-Works clone in `build-lsmash` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN git clone --recurse-submodules \
        https://github.com/AkarinVS/L-SMASH-Works.git /src/lsmash && \
```

Replace with:
```dockerfile
# Use HomeOfAviSynthPlusEvolution fork — AkarinVS is incompatible with FFmpeg 5+
# (references AVStream.index_entries which was made private in FFmpeg commit cea7c19).
# Pinned to a specific commit for reproducibility; update intentionally when needed.
RUN git clone \
        https://github.com/HomeOfAviSynthPlusEvolution/L-SMASH-Works.git /src/lsmash && \
    git -C /src/lsmash checkout 0079a06ee384061ecdadd0de03df4e0493dd56ab && \
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "fix: switch L-SMASH-Works to HomeOfAviSynthPlusEvolution fork, pin to 0079a06e"
```

---

### Task 3: Switch libaom to official tarball and bump to 3.13.2

**Files:**
- Modify: `Dockerfile.stack` (build-libaom stage)

Replace the `aomedia.googlesource.com` git clone (can be slow/unavailable) with a `wget` of the official tarball from `storage.googleapis.com/aom-releases/`. This is Google's stable release channel for libaom. Also bumps from 3.12.1 to 3.13.2.

- [ ] **Step 1: Replace the libaom clone and version in `build-libaom` stage**

In `Dockerfile.stack`, find:
```dockerfile
FROM base AS build-libaom

RUN git clone --depth 1 --branch v3.12.1 \
        https://aomedia.googlesource.com/aom /src/aom && \
    cmake -S /src/aom -B /src/aom_build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build /src/aom_build -j$(nproc) && \
    cmake --install /src/aom_build && \
    ldconfig && \
    rm -rf /src /src/aom_build
```

Replace with:
```dockerfile
FROM base AS build-libaom

# Use official tarball from storage.googleapis.com (stable release channel).
# aomedia.googlesource.com can be slow or unavailable during builds.
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
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "fix: switch libaom to official tarball source, bump 3.12.1 → 3.13.2"
```

---

### Task 4: Pin l-smash to v2.14.5

**Files:**
- Modify: `Dockerfile.stack` (build-lsmash stage)

The l-smash library clone currently has no branch specified (unpinned master). Pin to the latest stable tag.

- [ ] **Step 1: Add branch pin to l-smash clone in `build-lsmash` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN git clone --depth 1 https://github.com/l-smash/l-smash.git /src/l-smash && \
```

Replace with:
```dockerfile
RUN git clone --depth 1 --branch v2.14.5 https://github.com/l-smash/l-smash.git /src/l-smash && \
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "fix: pin l-smash to v2.14.5 (was unpinned master)"
```

---

### Task 5: Upgrade zimg 3.0.5 → 3.0.6

**Files:**
- Modify: `Dockerfile.stack` (build-vapoursynth stage)

Patch release with no breaking changes.

- [ ] **Step 1: Update zimg branch in `build-vapoursynth` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN git clone --depth 1 --branch release-3.0.5 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
```

Replace with:
```dockerfile
RUN git clone --depth 1 --branch release-3.0.6 \
        https://github.com/sekrit-twc/zimg.git /src/zimg && \
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "chore: bump zimg 3.0.5 → 3.0.6"
```

---

### Task 6: Upgrade SVT-AV1 3.1.2 → 4.1.0 and FFmpeg 8.0.1 → 8.1

**Files:**
- Modify: `Dockerfile.stack` (build-svtav1 stage, build-ffmpeg stage)

FFmpeg 8.1 explicitly supports SVT-AV1 4.x via `SVT_AV1_CHECK_VERSION(4, 0, 0)` guards in `libavcodec/libsvtav1.c`. These two upgrades must be done together since the FFmpeg/SVT-AV1 API is version-coupled.

- [ ] **Step 1: Update SVT-AV1 version in `build-svtav1` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN git clone --depth 1 --branch v3.1.2 \
        https://gitlab.com/AOMediaCodec/SVT-AV1.git /src/svtav1 && \
```

Replace with:
```dockerfile
RUN git clone --depth 1 --branch v4.1.0 \
        https://gitlab.com/AOMediaCodec/SVT-AV1.git /src/svtav1 && \
```

- [ ] **Step 2: Update FFmpeg version in `build-ffmpeg` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.0.1 && \
```

Replace with:
```dockerfile
RUN wget -q https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz -O /tmp/ffmpeg.tar.xz && \
    tar xf /tmp/ffmpeg.tar.xz -C /tmp && \
    cd /tmp/ffmpeg-8.1 && \
```

- [ ] **Step 3: Commit**

```bash
git add Dockerfile.stack
git commit -m "feat: upgrade SVT-AV1 3.1.2 → 4.1.0, FFmpeg 8.0.1 → 8.1"
```

---

### Task 7: Upgrade ab-av1 0.10.3 → 0.11.2

**Files:**
- Modify: `Dockerfile.stack` (build-ab-av1 stage)

Pure Rust binary; no API dependencies on the other components.

- [ ] **Step 1: Update ab-av1 version in `build-ab-av1` stage**

In `Dockerfile.stack`, find:
```dockerfile
RUN cargo install ab-av1 --version 0.10.3 --root /usr/local
```

Replace with:
```dockerfile
RUN cargo install ab-av1 --version 0.11.2 --root /usr/local
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.stack
git commit -m "chore: bump ab-av1 0.10.3 → 0.11.2"
```

---

### Task 8: Update docs/constraints.md

**Files:**
- Modify: `docs/constraints.md`

Two constraint entries are now stale and must be corrected.

- [ ] **Step 1: Replace the VapourSynth constraint entry**

In `docs/constraints.md`, find and replace the entire VapourSynth section:

Old content:
```markdown
## VapourSynth R72

**Constraint:** Must use exactly R72. Do not upgrade to R73+.

**Why:** VapourSynth R73 removed VSScript API v3. av1an 0.5.2 uses VSScript API v3
to invoke VapourSynth. Upgrading breaks av1an.
```

New content:
```markdown
## VapourSynth R73+

**Constraint:** Must use R73 or later. Do not downgrade to R72 or earlier. Do not
upgrade to R74 until it leaves RC.

**Why:** av1an 0.5.2 uses the `vapoursynth-rs` Rust crate v0.5.1, which requires
VSScript API v4. VapourSynth R72 only provides VSScript API v3 — av1an will fail
to load VSScript at runtime. R73 is the first release with API v4.
```

- [ ] **Step 2: Replace the SVT-AV1 + FFmpeg constraint entry**

In `docs/constraints.md`, find and replace the entire SVT-AV1 section:

Old content:
```markdown
## SVT-AV1 3.1.2 + FFmpeg 8.0.1

**Constraint:** SVT-AV1 v3.0+ changed its API. FFmpeg 8.0.1 is required for
compatibility with SVT-AV1 3.1.2.

**Why:** Earlier FFmpeg versions use the old SVT-AV1 API and fail to build with
the new library.
```

New content:
```markdown
## SVT-AV1 4.1.0 + FFmpeg 8.1

**Constraint:** SVT-AV1 4.x requires FFmpeg 8.1 or later.

**Why:** FFmpeg 8.1 added `SVT_AV1_CHECK_VERSION(4, 0, 0)` guards in
`libavcodec/libsvtav1.c`, handling both 3.x and 4.x APIs at compile time.
Earlier FFmpeg versions do not know about the 4.x API and will fail to build.
```

- [ ] **Step 3: Commit**

```bash
git add docs/constraints.md
git commit -m "docs: update constraints.md — VapourSynth R73+, SVT-AV1 4.1.0 + FFmpeg 8.1"
```

---

### Task 9: Build and verify

**Files:** None modified

Run the full test suite to confirm the build works on both platforms.

- [ ] **Step 1: Run `./test.sh`**

```bash
./test.sh
```

Expected output (trimmed):
```
==> Building Dockerfile.stack (linux/amd64)...
Running binary checks (linux/amd64)...
  av1an       OK
  ab-av1      OK
  ffmpeg      OK
All checks passed for linux/amd64

==> Building Dockerfile.stack (linux/arm64)...
Running binary checks (linux/arm64)...
  av1an       OK
  ab-av1      OK
  ffmpeg      OK
All checks passed for linux/arm64

All checks passed (linux/amd64, linux/arm64) — safe to merge
```

If a binary check fails, the `docker buildx build` output above it will show the failing stage and error message. Common failure modes:

- **VapourSynth configure fails** — Cython version issue; check the pip install step in `build-vapoursynth`
- **FFmpeg configure fails** — SVT-AV1 or libaom headers not found; check `PKG_CONFIG_PATH` in `build-ffmpeg`
- **L-SMASH-Works meson fails** — FFmpeg or VapourSynth headers not found; check the COPY steps in `build-lsmash`
- **av1an cargo build fails** — VapourSynth library not found at link time; check `LD_LIBRARY_PATH` in `build-av1an`

- [ ] **Step 2: Once passing, open PR**

```bash
git push origin dev
# Open PR from dev → main via GitHub UI or:
gh pr create --title "fix: update all Dockerfile.stack dependencies to current stable" \
  --body "See docs/superpowers/specs/2026-03-31-dependency-versioning-design.md"
```
