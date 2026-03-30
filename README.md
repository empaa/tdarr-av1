# tdarr-av1

Extended Docker images for [Tdarr](https://github.com/HaveAGitGat/Tdarr) that add [av1an](https://github.com/master-of-zen/Av1an) and [ab-av1](https://github.com/alexheretic/ab-av1) support.

## Overview

This project extends the official Tdarr Docker images with AV1 encoding tools:

- **Base image:** `ghcr.io/haveagitgat/tdarr` — extended with av1an and ab-av1
- **Node image:** `ghcr.io/haveagitgat/tdarr_node` — extended with av1an and ab-av1

[av1an](https://github.com/master-of-zen/Av1an) provides scene-based chunked encoding for faster AV1 encoding, while [ab-av1](https://github.com/alexheretic/ab-av1) automates quality-targeted AV1 encoding using VMAF to find the right CRF value.

## Why

The official Tdarr images do not include av1an or ab-av1. This project bridges that gap, allowing Tdarr plugin scripts to leverage these tools for high-quality, efficient AV1 transcoding.
