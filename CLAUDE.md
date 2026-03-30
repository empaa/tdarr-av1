# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This project extends the official Tdarr Docker images with AV1 encoding tools:

- `ghcr.io/haveagitgat/tdarr` → extended with [av1an](https://github.com/master-of-zen/Av1an) and [ab-av1](https://github.com/alexheretic/ab-av1)
- `ghcr.io/haveagitgat/tdarr_node` → extended with the same tools

The goal is to allow Tdarr plugin scripts to use av1an (scene-based chunked AV1 encoding) and ab-av1 (VMAF-targeted CRF selection) for high-quality transcoding.
