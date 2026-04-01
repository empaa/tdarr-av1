# Test Suite Audit — Post-Implementation Fix

**Date:** 2026-04-01
**Status:** Approved

## Problem

The test suite redesign (see `2026-04-01-test-suite-redesign.md`) was implemented but the session was interrupted before verification. Three issues were found on audit:

1. `test-stack.sh` was committed without the executable bit (`100644` in git HEAD). Running `./test-stack.sh` fails immediately with a permission denied error.
2. The previous spec incorrectly specified `av1-stack:local` as the image tag for single-platform builds. The implementation correctly uses `av1-stack:<arch>` (e.g. `av1-stack:arm64`) throughout, which is more descriptive and consistent with `--all-platforms` mode.
3. Stale `.mkv` encode output files from a previous test run remain in `test/output/` root. The old script wrote outputs there directly; the new scripts write to `test/output/stack/` and `test/output/tdarr/`. These files are untracked by git and will never be cleaned by `--clean`.

## Design

### Change 1 — Restore executable bit on test-stack.sh

`chmod +x test-stack.sh` on disk. Commit this together with the already-staged permission change (`100644→100755` in the git index) and the pending Dockerfile content changes:

- `libpython3.12` added to the `av1-stack` runtime install
- `# syntax=docker/dockerfile:1` header removed (not needed without BuildKit-specific syntax features)

Single commit covering all three pending changes.

### Change 2 — Correct the spec doc

Update `docs/superpowers/specs/2026-04-01-test-suite-redesign.md` to replace the `av1-stack:local` naming with `av1-stack:<arch>`. The correct convention is:

- Default (single native-arch build): `av1-stack:<arch>` (e.g. `av1-stack:arm64`)
- `--all-platforms`: `av1-stack:amd64` and `av1-stack:arm64`

No code changes to either script — they are already correct.

### Change 3 — Delete stale outputs

Remove the `.mkv` files sitting in `test/output/` root. These are untracked and were produced by the old test script. The new scripts never write there, and `--clean` never needs to handle that path.

## Verification

After applying changes, confirm:

```bash
# Exec bit is set
ls -la test-stack.sh   # should show -rwxr-xr-x

# --clean works
./test-stack.sh --clean

# Default run builds and checks binaries
./test-stack.sh
```

## Scripts not changed

`test-stack.sh` and `test-tdarr.sh` are correct as-is once the exec bit is restored. No logic changes needed.
