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
