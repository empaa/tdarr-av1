# Plugin Repository Separation Design

**Date:** 2026-04-02
**Status:** Approved

## Problem

Tdarr FlowPlugins must be self-contained single-file plugins. The current approach
of shipping shared library modules (`av1Shared/`) alongside plugins fails because:

1. Tdarr scans every `.js` file in the plugins directory and tries to load it as a
   plugin. Files without a `details()` export cause errors.
2. Plugins cannot reliably `require()` across sibling directories since Tdarr loads
   each plugin in isolation.
3. Baking plugins into Docker images via `COPY` is ineffective because Tdarr's config
   directory is volume-mounted, overwriting image contents at runtime.

## Solution

Create a separate repository (`github.com/empaa/tdarr-plugins`) for plugin
development. Use esbuild to bundle shared code into each plugin at build time,
producing self-contained single-file plugins. Distribute via GitHub Releases.

## Repository Structure

```
tdarr-plugins/
  src/
    shared/                     # shared modules, not plugins themselves
      logger.js
      processManager.js
      encoderFlags.js
      downscale.js
      audioMerge.js
      progressTracker.js
    av1anEncode/
      index.js                  # imports from ../shared/
    abAv1Encode/
      index.js
  dist/                         # gitignored, build output
    LocalFlowPlugins/
      av1anEncode/1.0.0/index.js
      abAv1Encode/1.0.0/index.js
  build.sh
  package.json
  .github/workflows/release.yml
```

- `src/shared/` contains reusable modules imported normally during development,
  inlined by esbuild at build time.
- Each `dist/` plugin is a single self-contained `index.js` ready to drop into Tdarr.
- Adding a new plugin = create a new directory under `src/` with an `index.js`.

## Build System

**`build.sh`** performs two operations:

1. **Bundle:** For each `src/*/index.js` (excluding `shared/`), runs esbuild to
   produce `dist/LocalFlowPlugins/<name>/<version>/index.js`. esbuild inlines all
   `shared/` imports but leaves Node builtins (`fs`, `path`, `child_process`, `os`)
   as external requires.

2. **Deploy (optional):** `build.sh --deploy` copies `dist/LocalFlowPlugins/` into
   the interactive test instance's Tdarr config directory for rapid iteration.

**`package.json`** is minimal:

```json
{
  "private": true,
  "scripts": {
    "build": "./build.sh",
    "deploy": "./build.sh --deploy"
  },
  "devDependencies": {
    "esbuild": "^0.25"
  }
}
```

No runtime dependencies. esbuild is the only dev dependency.

**Plugin versioning:** Version lives in the directory name (e.g. `1.0.0/`). The build
script reads it from the source directory structure automatically.

## CI / GitHub Actions

**Workflow: `release.yml`** triggers on push to `main`.

1. **Build:** Checkout, install Node, `npm ci`, `npm run build`.
2. **Package:** Zip `dist/LocalFlowPlugins/` into `tdarr-plugins-v<version>.zip`.
3. **Release:** Create a GitHub Release with the zip attached. Version sourced from
   `package.json`.

**Branch strategy:** `dev` for work, PR to `main`, merge triggers the release build.

## User Install Flow

1. Go to the GitHub Releases page.
2. Download `tdarr-plugins-v<version>.zip`.
3. Extract into Tdarr server config `Plugins/FlowPlugins/` directory.
4. Restart Tdarr server (nodes auto-sync from server since v2.12.01).

## Developer Workflow

1. Edit plugin source in `src/`.
2. Run `npm run build` to bundle.
3. Run `npm run deploy` to copy built plugins into the interactive test instance.
4. Iterate. Plugins appear in the Tdarr dashboard immediately after server restart.

## Cleanup of Docker Repo (tdarr-av1)

Once the plugin repo exists:

- Remove `plugins/` directory entirely.
- Remove `COPY plugins/FlowPlugins/...` lines from Dockerfile.
- Docker images become purely the AV1 encoding stack with no plugin opinions.

## Tdarr Plugin Discovery Notes

Gathered during research — useful context for future plugin work:

- Tdarr supports a "Community plugins repo" URL in settings, but it **replaces** the
  entire community plugin set (not additive). Not viable for third-party distribution.
- `LocalFlowPlugins/` is the correct path for user-installed plugins.
- Nodes auto-sync plugins from the server at startup and hourly (since v2.12.01).
- The `pluginsDir` env var can override the plugins root. If it contains `.git`, Tdarr
  skips automatic plugin updates.
