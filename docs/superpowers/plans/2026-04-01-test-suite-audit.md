# Test Suite Audit — Post-Implementation Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three post-implementation issues found in the test suite redesign: commit pending Dockerfile changes, correct the spec doc naming, and remove stale test outputs.

**Architecture:** All changes are file edits and git operations. No logic changes to `test-stack.sh` or `test-tdarr.sh` — the scripts are correct. The executable bit on `test-stack.sh` has already been restored (`chmod +x` done, permission committed in `1457c04`).

**Tech Stack:** bash, git, Docker (for verification only)

---

### Task 1: Commit pending Dockerfile changes

**Files:**
- Modify: `Dockerfile`

- [ ] **Step 1: Review what is pending**

Run:
```bash
git diff Dockerfile
```
Expected: two hunks — removal of `# syntax=docker/dockerfile:1` near line 1, and addition of `libpython3.12` in the `av1-stack` runtime install block.

- [ ] **Step 2: Stage and commit**

```bash
git add Dockerfile
git commit -m "fix: add libpython3.12 runtime dep; drop unused syntax directive"
```

Expected: commit succeeds on branch `dev`.

---

### Task 2: Fix av1-stack image naming in the redesign spec

The approved spec (`docs/superpowers/specs/2026-04-01-test-suite-redesign.md`) incorrectly describes the default image tag as `av1-stack:local`. The implementation correctly uses `av1-stack:<arch>` throughout. Update the spec to match.

**Files:**
- Modify: `docs/superpowers/specs/2026-04-01-test-suite-redesign.md`

- [ ] **Step 1: Fix the --clean flag description (line 63)**

Find:
```
- `--clean` — remove cached `av1-stack:local` image(s) and wipe `test/output/stack/`
```

Replace with:
```
- `--clean` — remove cached `av1-stack:amd64` / `av1-stack:arm64` image(s) and wipe `test/output/stack/`
```

- [ ] **Step 2: Fix the default build step (line 66)**

Find:
```
1. `docker buildx build --target av1-stack --output type=docker,name=av1-stack:local`
```

Replace with:
```
1. `docker buildx build --target av1-stack --output type=docker,name=av1-stack:<arch>`
   (e.g. `av1-stack:arm64` on an M-series Mac, `av1-stack:amd64` on x86)
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-04-01-test-suite-redesign.md
git commit -m "docs: correct av1-stack image naming in test suite redesign spec"
```

---

### Task 3: Delete stale outputs from test/output/

These files were produced by the old test script (which wrote directly to `test/output/` rather than `test/output/stack/`). They are untracked by git and will never be cleaned by `--clean`.

**Files:**
- Delete (untracked): `test/output/*.mkv`, `test/output/*.lwi`

- [ ] **Step 1: Confirm files are untracked**

```bash
git status test/output/
```

Expected: all `.mkv` and `.lwi` files listed under "Untracked files" (not staged, not modified).

- [ ] **Step 2: Delete the stale files**

```bash
rm "test/output/Saturday Night Live (1975) - S48E05 - Amy Schumer Steve Lacy [HULU][WEBDL-1080p][EAC3 5.1][h264]-None_ab-av1.mkv"
rm "test/output/Saturday Night Live (1975) - S48E05 - Amy Schumer Steve Lacy [HULU][WEBDL-1080p][EAC3 5.1][h264]-None_av1an_aom.mkv"
rm "test/output/Saturday Night Live (1975) - S48E05 - Amy Schumer Steve Lacy [HULU][WEBDL-1080p][EAC3 5.1][h264]-None_av1an_svtav1.mkv"
rm "test/output/Saturday Night Live (1975) - S48E05 - Amy Schumer Steve Lacy [HULU][WEBDL-1080p][EAC3 5.1][h264]-None_clip.mkv"
rm "test/output/Saturday Night Live (1975) - S48E05 - Amy Schumer Steve Lacy [HULU][WEBDL-1080p][EAC3 5.1][h264]-None_clip.mkv.lwi"
```

- [ ] **Step 3: Confirm git status is clean**

```bash
git status
```

Expected: working tree clean (or only the Dockerfile if Task 1 hasn't been done yet).

---

### Task 4: Verify test-stack.sh works end-to-end

No code changes — this is a smoke test to confirm all fixes hold together.

- [ ] **Step 1: Confirm exec bit is set**

```bash
ls -la test-stack.sh
```

Expected: `-rwxr-xr-x`

- [ ] **Step 2: Run --clean**

```bash
./test-stack.sh --clean
```

Expected output:
```
==> Cleaning...
Done.
```
(Docker rmi lines may print "No such image" if images don't exist yet — that is fine, `|| true` handles it.)

- [ ] **Step 3: Run the default binary check**

```bash
./test-stack.sh
```

Expected: builds `av1-stack:<arch>`, then prints `OK` for `av1an`, `ab-av1`, and `ffmpeg`, ending with `All checks passed`.

- [ ] **Step 4: Run --clean again to confirm it removes the built image**

```bash
./test-stack.sh --clean
docker images | grep av1-stack
```

Expected: `--clean` prints `Done.` and `docker images` shows no `av1-stack` entries.
