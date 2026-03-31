# tdarr-av1

Drop-in replacements for the official Tdarr Docker images with [av1an](https://github.com/master-of-zen/Av1an) and [ab-av1](https://github.com/alexheretic/ab-av1) built in.

## Images

| Official | This project |
|---|---|
| `ghcr.io/haveagitgat/tdarr` | `ghcr.io/empaa/tdarr` |
| `ghcr.io/haveagitgat/tdarr_node` | `ghcr.io/empaa/tdarr_node` |

These extend the official images — swap the image name in your existing `docker run` or `docker-compose.yml` and everything works the same. No other changes needed.

Inside the container you get two additional tools available to Tdarr plugin scripts:

- **`av1an`** — scene-based chunked encoding for fast, efficient AV1 transcoding
- **`ab-av1`** — quality-targeted encoding using VMAF to automatically find the right CRF

## Why

The official Tdarr images do not include av1an or ab-av1. This project bridges that gap so plugin scripts can call these tools directly.

## Status

**Working:** av1an and ab-av1 are available inside the container.

**WIP:** Tdarr plugins that use these tools are not yet included.
