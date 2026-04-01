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
