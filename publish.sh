#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/empaa"
BUILDER_NAME="multiplatform"
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

ensure_builder
check_ghcr_auth

echo "==> Publishing to ${REGISTRY} (${PLATFORM_LABEL})..."

for target in tdarr tdarr_node; do
  echo "==> Building and pushing ${target}..."
  docker buildx build \
    --builder "${BUILDER_NAME}" \
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
