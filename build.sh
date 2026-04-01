#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034  # used by later tasks
REGISTRY="ghcr.io/empaa"
BUILDER_NAME="multiplatform"
# shellcheck disable=SC2034  # used by later tasks
BINARIES=(av1an ab-av1 ffmpeg)

STACK_ONLY=false
ENCODE=false
PUBLISH=false
CLEAN=false
CLEAN_CACHE=false
ALL_PLATFORMS=false
SPECIFIC_ARCH=""
ARCH_COUNT=0

# shellcheck disable=SC2034  # SPECIFIC_ARCH, ARCH_COUNT used by later tasks
for arg in "$@"; do
  case "$arg" in
    --stack-only)    STACK_ONLY=true ;;
    --encode)        ENCODE=true ;;
    --all-platforms) ALL_PLATFORMS=true ;;
    --arm64)         SPECIFIC_ARCH="arm64"; ARCH_COUNT=$((ARCH_COUNT + 1)) ;;
    --amd64)         SPECIFIC_ARCH="amd64"; ARCH_COUNT=$((ARCH_COUNT + 1)) ;;
    --publish)       PUBLISH=true ;;
    --clean)         CLEAN=true ;;
    --clean-cache)   CLEAN_CACHE=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC2034  # SCRIPT_DIR used by later tasks
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── validation ───────────────────────────────────────────────────────────────

platform_count=0
[[ "$ALL_PLATFORMS" == true ]] && platform_count=$((platform_count + 1))
platform_count=$((platform_count + ARCH_COUNT))
if [[ $platform_count -gt 1 ]]; then
  echo "Error: --all-platforms, --arm64, and --amd64 are mutually exclusive" >&2
  exit 1
fi

if [[ "$STACK_ONLY" == true && "$PUBLISH" == true ]]; then
  echo "Error: --stack-only --publish is invalid — av1-stack is never published" >&2
  exit 1
fi

if [[ "$CLEAN" == true || "$CLEAN_CACHE" == true ]]; then
  for flag in "$STACK_ONLY" "$ENCODE" "$PUBLISH"; do
    if [[ "$flag" == true ]]; then
      echo "Error: --clean/--clean-cache cannot be combined with build/test/publish flags" >&2
      exit 1
    fi
  done
fi

# ── helpers ──────────────────────────────────────────────────────────────────

native_arch() {
  case "$(uname -m)" in
    x86_64)        echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
}

ensure_builder() {
  if ! docker buildx inspect "${BUILDER_NAME}" > /dev/null 2>&1; then
    echo "==> Creating buildx builder '${BUILDER_NAME}'..."
    docker buildx create --name "${BUILDER_NAME}" --driver docker-container
  fi
}

check_ghcr_auth() {
  local auth
  auth=$(python3 -c "
import json, os
try:
    cfg = json.load(open(os.path.expanduser('~/.docker/config.json')))
    a = cfg.get('auths', {}).get('ghcr.io', {})
    print('ok' if a.get('auth') else 'missing')
except Exception:
    print('missing')
" 2>/dev/null)
  if [[ "$auth" != "ok" ]]; then
    echo "Not authenticated to ghcr.io. Run:" >&2
    echo "  gh auth token | docker login ghcr.io -u <github-username> --password-stdin" >&2
    exit 1
  fi
}

# ── result collection ────────────────────────────────────────────────────────

declare -a RESULTS=()

add_result() {
  local platform="$1" label="$2" status="$3"
  RESULTS+=("${platform}|${label}|${status}")
}

print_summary() {
  if [[ ${#RESULTS[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════"
  echo "  Test Summary"
  echo "════════════════════════════════════════"

  local current_platform=""
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r platform label status <<< "$entry"
    if [[ "$platform" != "$current_platform" ]]; then
      [[ -n "$current_platform" ]] && echo ""
      echo "  ${platform}"
      current_platform="$platform"
    fi
    printf "    %-28s %s\n" "$label" "$status"
  done

  local failed=0
  for entry in "${RESULTS[@]}"; do
    [[ "$entry" == *"|FAILED" ]] && failed=$((failed + 1))
  done

  echo "════════════════════════════════════════"
  if [[ $failed -gt 0 ]]; then
    echo "  FAILED: ${failed} check(s) failed"
  else
    echo "  All checks passed"
  fi
  echo "════════════════════════════════════════"

  return "$failed"
}
