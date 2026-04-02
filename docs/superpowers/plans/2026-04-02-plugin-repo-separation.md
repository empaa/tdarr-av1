# Plugin Repository Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new `tdarr-plugins` repository with esbuild bundling that produces self-contained single-file Tdarr FlowPlugins, and clean up the plugin code from the Docker image repo.

**Architecture:** Separate repo with `src/` containing plugin sources and shared modules. esbuild bundles each plugin into a single `index.js` that inlines shared code. `build.sh` handles bundling and optional deploy to a local Tdarr test instance. GitHub Actions builds and publishes release zips on merge to main.

**Tech Stack:** Node.js, esbuild, GitHub Actions

---

## File Structure

```
tdarr-plugins/                          # New repository
  src/
    shared/
      logger.js                         # createLogger, humanSize
      processManager.js                 # createProcessManager
      encoderFlags.js                   # detectHdrMeta, build*Flags, calculateThreadBudget
      downscale.js                      # RESOLUTION_PRESETS, buildVsDownscaleLines, etc.
      audioMerge.js                     # probeAudioSize, mergeAudioVideo
      progressTracker.js                # createAv1anTracker, createAbAv1Tracker
    av1anEncode/
      index.js                          # av1an plugin (imports from ../shared/)
    abAv1Encode/
      index.js                          # ab-av1 plugin (imports from ../shared/)
  dist/                                 # gitignored build output
    LocalFlowPlugins/
      av1anEncode/1.0.0/index.js        # bundled single-file plugin
      abAv1Encode/1.0.0/index.js        # bundled single-file plugin
  build.sh                              # esbuild bundler + --deploy flag
  package.json                          # esbuild devDependency
  .gitignore
  .github/
    workflows/
      release.yml                       # CI: build + GitHub Release on push to main
```

Changes to existing `tdarr-av1` repo:
- Delete: `plugins/` directory (entire tree)
- Modify: `Dockerfile` (remove COPY lines for FlowPlugins)

---

### Task 1: Create the new repository and project scaffold

**Files:**
- Create: `tdarr-plugins/package.json`
- Create: `tdarr-plugins/.gitignore`

This task is done in a new directory outside the current `tdarr-av1` repo. The user will need to create the GitHub repo manually (or via `gh repo create`).

- [ ] **Step 1: Create the repository directory and initialize git**

```bash
mkdir -p ~/ClaudeProjects/tdarr-plugins
cd ~/ClaudeProjects/tdarr-plugins
git init
git checkout -b main
git checkout -b dev
```

- [ ] **Step 2: Create package.json**

Create `package.json`:

```json
{
  "name": "tdarr-plugins",
  "version": "1.0.0",
  "private": true,
  "description": "AV1 encoding FlowPlugins for Tdarr (av1an + ab-av1)",
  "scripts": {
    "build": "./build.sh",
    "deploy": "./build.sh --deploy"
  },
  "devDependencies": {
    "esbuild": "^0.25"
  }
}
```

- [ ] **Step 3: Create .gitignore**

Create `.gitignore`:

```
node_modules/
dist/
```

- [ ] **Step 4: Install dependencies**

```bash
cd ~/ClaudeProjects/tdarr-plugins
npm install
```

Expected: `node_modules/` created with esbuild installed.

- [ ] **Step 5: Commit scaffold**

```bash
git add package.json package-lock.json .gitignore
git commit -m "feat: initialize plugin repo with esbuild"
```

---

### Task 2: Migrate shared modules to src/shared/

**Files:**
- Create: `tdarr-plugins/src/shared/logger.js`
- Create: `tdarr-plugins/src/shared/processManager.js`
- Create: `tdarr-plugins/src/shared/encoderFlags.js`
- Create: `tdarr-plugins/src/shared/downscale.js`
- Create: `tdarr-plugins/src/shared/audioMerge.js`
- Create: `tdarr-plugins/src/shared/progressTracker.js`

Copy the six shared modules from `tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/` into `tdarr-plugins/src/shared/`. The files are copied verbatim — no changes needed since esbuild will resolve the `require('./logger')` in progressTracker.js correctly.

- [ ] **Step 1: Create src/shared/ and copy all six modules**

```bash
mkdir -p ~/ClaudeProjects/tdarr-plugins/src/shared
cp ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/logger.js \
   ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/processManager.js \
   ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/encoderFlags.js \
   ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/downscale.js \
   ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/audioMerge.js \
   ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/progressTracker.js \
   ~/ClaudeProjects/tdarr-plugins/src/shared/
```

- [ ] **Step 2: Update file header comments**

Update the first line comment in each file from `// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/<name>.js` to `// src/shared/<name>.js`.

- [ ] **Step 3: Commit shared modules**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git add src/shared/
git commit -m "feat: add shared modules (logger, processManager, encoderFlags, downscale, audioMerge, progressTracker)"
```

---

### Task 3: Migrate plugin sources and update imports

**Files:**
- Create: `tdarr-plugins/src/av1anEncode/index.js`
- Create: `tdarr-plugins/src/abAv1Encode/index.js`

Copy the two plugin index.js files from `tdarr-av1` and update their `require()` calls to use relative paths to `../shared/` instead of the old `__dirname`-based `sharedBase` resolution.

- [ ] **Step 1: Create plugin directories and copy source files**

```bash
mkdir -p ~/ClaudeProjects/tdarr-plugins/src/av1anEncode
mkdir -p ~/ClaudeProjects/tdarr-plugins/src/abAv1Encode
cp ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/index.js \
   ~/ClaudeProjects/tdarr-plugins/src/av1anEncode/index.js
cp ~/ClaudeProjects/tdarr-av1/plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/index.js \
   ~/ClaudeProjects/tdarr-plugins/src/abAv1Encode/index.js
```

- [ ] **Step 2: Update av1anEncode imports**

In `src/av1anEncode/index.js`, replace the `sharedBase` + dynamic `require()` block (lines 87-93) with direct relative imports. The `require()` calls must stay inside `plugin()` (not at top level) because Tdarr evaluates `details()` at scan time before `plugin()` runs, and Node builtins should only be loaded when the plugin actually executes.

Replace:

```javascript
  const sharedBase = path.join(__dirname, '..', '..', 'av1Shared', '1.0.0');
  const { createProcessManager } = require(path.join(sharedBase, 'processManager'));
  const { createLogger, humanSize } = require(path.join(sharedBase, 'logger'));
  const { detectHdrMeta, buildAomFlags, buildSvtFlags, calculateThreadBudget } = require(path.join(sharedBase, 'encoderFlags'));
  const { buildVsDownscaleLines, buildAv1anVmafResArgs } = require(path.join(sharedBase, 'downscale'));
  const { probeAudioSize, mergeAudioVideo } = require(path.join(sharedBase, 'audioMerge'));
  const { createAv1anTracker } = require(path.join(sharedBase, 'progressTracker'));
```

With:

```javascript
  const { createProcessManager } = require('../shared/processManager');
  const { createLogger, humanSize } = require('../shared/logger');
  const { detectHdrMeta, buildAomFlags, buildSvtFlags, calculateThreadBudget } = require('../shared/encoderFlags');
  const { buildVsDownscaleLines, buildAv1anVmafResArgs } = require('../shared/downscale');
  const { probeAudioSize, mergeAudioVideo } = require('../shared/audioMerge');
  const { createAv1anTracker } = require('../shared/progressTracker');
```

Also update the file header comment from `// plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/index.js` to `// src/av1anEncode/index.js`.

- [ ] **Step 3: Update abAv1Encode imports**

In `src/abAv1Encode/index.js`, apply the same transformation. Replace:

```javascript
  const sharedBase = path.join(__dirname, '..', '..', 'av1Shared', '1.0.0');
  const { createProcessManager } = require(path.join(sharedBase, 'processManager'));
  const { createLogger, humanSize } = require(path.join(sharedBase, 'logger'));
  const { detectHdrMeta, buildAbAv1SvtFlags } = require(path.join(sharedBase, 'encoderFlags'));
  const { buildAbAv1DownscaleArgs } = require(path.join(sharedBase, 'downscale'));
  const { createAbAv1Tracker } = require(path.join(sharedBase, 'progressTracker'));
```

With:

```javascript
  const { createProcessManager } = require('../shared/processManager');
  const { createLogger, humanSize } = require('../shared/logger');
  const { detectHdrMeta, buildAbAv1SvtFlags } = require('../shared/encoderFlags');
  const { buildAbAv1DownscaleArgs } = require('../shared/downscale');
  const { createAbAv1Tracker } = require('../shared/progressTracker');
```

Also update the file header comment to `// src/abAv1Encode/index.js`.

- [ ] **Step 4: Commit migrated plugins**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git add src/av1anEncode/ src/abAv1Encode/
git commit -m "feat: add av1anEncode and abAv1Encode plugins with shared imports"
```

---

### Task 4: Create build.sh

**Files:**
- Create: `tdarr-plugins/build.sh`

The build script uses esbuild to bundle each plugin under `src/` (excluding `shared/`) into a single file at `dist/LocalFlowPlugins/<name>/1.0.0/index.js`. It reads the version from the source directory structure if present, defaulting to `1.0.0`. The `--deploy` flag copies `dist/` into the Tdarr interactive test instance's plugin directory.

- [ ] **Step 1: Create build.sh**

Create `build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
DIST_DIR="${SCRIPT_DIR}/dist/LocalFlowPlugins"
DEPLOY=false

# Path to tdarr-av1 interactive test instance plugin dir
TDARR_AV1_DIR="${SCRIPT_DIR}/../tdarr-av1"
DEPLOY_TARGET="${TDARR_AV1_DIR}/test/tdarr_config/server/Tdarr/Plugins/FlowPlugins/LocalFlowPlugins"

for arg in "$@"; do
  case "$arg" in
    --deploy) DEPLOY=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# Find esbuild
ESBUILD="${SCRIPT_DIR}/node_modules/.bin/esbuild"
if [[ ! -x "$ESBUILD" ]]; then
  echo "esbuild not found. Run 'npm install' first." >&2
  exit 1
fi

# Node builtins that must not be bundled
EXTERNALS=(fs path child_process os)
EXTERNAL_FLAGS=""
for ext in "${EXTERNALS[@]}"; do
  EXTERNAL_FLAGS="${EXTERNAL_FLAGS} --external:${ext}"
done

# Clean dist
rm -rf "$DIST_DIR"

# Bundle each plugin (every directory under src/ except shared/)
plugin_count=0
for plugin_dir in "${SRC_DIR}"/*/; do
  plugin_name="$(basename "$plugin_dir")"
  [[ "$plugin_name" == "shared" ]] && continue

  entry="${plugin_dir}index.js"
  if [[ ! -f "$entry" ]]; then
    echo "WARNING: ${plugin_name}/index.js not found, skipping" >&2
    continue
  fi

  version="1.0.0"
  out_dir="${DIST_DIR}/${plugin_name}/${version}"
  mkdir -p "$out_dir"

  echo "  bundle: ${plugin_name} -> dist/LocalFlowPlugins/${plugin_name}/${version}/index.js"

  # shellcheck disable=SC2086
  "$ESBUILD" "$entry" \
    --bundle \
    --platform=node \
    --format=cjs \
    --target=node18 \
    ${EXTERNAL_FLAGS} \
    --outfile="${out_dir}/index.js"

  plugin_count=$((plugin_count + 1))
done

echo ""
echo "Built ${plugin_count} plugin(s) -> dist/LocalFlowPlugins/"

# Deploy to test instance
if [[ "$DEPLOY" == true ]]; then
  if [[ ! -d "${TDARR_AV1_DIR}/test/tdarr_config" ]]; then
    echo ""
    echo "WARNING: tdarr-av1 test config not found at ${TDARR_AV1_DIR}/test/tdarr_config" >&2
    echo "Run './build.sh --interactive' in tdarr-av1 first to create it." >&2
    exit 1
  fi

  mkdir -p "$DEPLOY_TARGET"
  cp -r "${DIST_DIR}/"* "$DEPLOY_TARGET/"

  echo ""
  echo "Deployed to: ${DEPLOY_TARGET}"
  echo "Restart Tdarr server to pick up changes."
fi
```

- [ ] **Step 2: Make build.sh executable**

```bash
chmod +x ~/ClaudeProjects/tdarr-plugins/build.sh
```

- [ ] **Step 3: Test the build**

```bash
cd ~/ClaudeProjects/tdarr-plugins
npm run build
```

Expected output:
```
  bundle: abAv1Encode -> dist/LocalFlowPlugins/abAv1Encode/1.0.0/index.js
  bundle: av1anEncode -> dist/LocalFlowPlugins/av1anEncode/1.0.0/index.js

Built 2 plugin(s) -> dist/LocalFlowPlugins/
```

- [ ] **Step 4: Verify bundled output is self-contained**

```bash
# Should show NO require() calls except Node builtins (fs, path, child_process, os)
grep -n 'require(' ~/ClaudeProjects/tdarr-plugins/dist/LocalFlowPlugins/av1anEncode/1.0.0/index.js | grep -v 'require("fs")' | grep -v 'require("path")' | grep -v 'require("child_process")' | grep -v 'require("os")'
```

Expected: No output (all shared imports have been inlined).

- [ ] **Step 5: Verify bundled plugin exports details and plugin**

```bash
node -e "const m = require('./dist/LocalFlowPlugins/av1anEncode/1.0.0/index.js'); console.log('details:', typeof m.details); console.log('plugin:', typeof m.plugin); console.log('name:', m.details().name);"
```

Expected:
```
details: function
plugin: function
name: AV1 Encode (av1an)
```

Run the same check for abAv1Encode:

```bash
node -e "const m = require('./dist/LocalFlowPlugins/abAv1Encode/1.0.0/index.js'); console.log('details:', typeof m.details); console.log('plugin:', typeof m.plugin); console.log('name:', m.details().name);"
```

Expected:
```
details: function
plugin: function
name: AV1 Encode (ab-av1)
```

- [ ] **Step 6: Commit build.sh**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git add build.sh
git commit -m "feat: add build.sh with esbuild bundling and --deploy flag"
```

---

### Task 5: Add GitHub Actions release workflow

**Files:**
- Create: `tdarr-plugins/.github/workflows/release.yml`

The workflow triggers on push to `main`, builds the plugins, zips the output, and creates a GitHub Release.

- [ ] **Step 1: Create the workflow file**

```bash
mkdir -p ~/ClaudeProjects/tdarr-plugins/.github/workflows
```

Create `.github/workflows/release.yml`:

```yaml
name: Build and Release

on:
  push:
    branches: [main]

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'

      - run: npm ci

      - run: npm run build

      - name: Get version
        id: version
        run: echo "version=$(node -p 'require("./package.json").version')" >> "$GITHUB_OUTPUT"

      - name: Zip plugins
        run: cd dist && zip -r "../tdarr-plugins-v${{ steps.version.outputs.version }}.zip" LocalFlowPlugins/

      - name: Create release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: v${{ steps.version.outputs.version }}
          name: v${{ steps.version.outputs.version }}
          files: tdarr-plugins-v${{ steps.version.outputs.version }}.zip
          generate_release_notes: true
```

- [ ] **Step 2: Commit workflow**

```bash
cd ~/ClaudeProjects/tdarr-plugins
git add .github/
git commit -m "ci: add GitHub Actions release workflow"
```

---

### Task 6: Clean up the Docker image repo

**Files:**
- Delete: `tdarr-av1/plugins/` (entire directory)
- Modify: `tdarr-av1/Dockerfile` (lines 226-227, 239-240)

This task is done in the `tdarr-av1` repository.

- [ ] **Step 1: Remove plugin COPY lines from Dockerfile**

In `~/ClaudeProjects/tdarr-av1/Dockerfile`, remove these blocks:

At line 226-227 (in the `tdarr` target):
```dockerfile
# FlowPlugins for av1an and ab-av1
COPY plugins/FlowPlugins/LocalFlowPlugins/ /app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/
```

At line 239-240 (in the `tdarr_node` target):
```dockerfile
# FlowPlugins for av1an and ab-av1
COPY plugins/FlowPlugins/LocalFlowPlugins/ /app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/
```

- [ ] **Step 2: Delete the plugins directory**

```bash
cd ~/ClaudeProjects/tdarr-av1
rm -rf plugins/
```

- [ ] **Step 3: Commit the cleanup**

```bash
cd ~/ClaudeProjects/tdarr-av1
git add -A plugins/
git add Dockerfile
git commit -m "refactor: remove FlowPlugins from Docker images

Plugins now live in a separate tdarr-plugins repository and are
installed by users into their Tdarr config directory."
```

---

### Task 7: Create the GitHub repo and push

This task sets up the remote repository. The user may prefer to do this manually.

- [ ] **Step 1: Create the GitHub repository**

```bash
cd ~/ClaudeProjects/tdarr-plugins
gh repo create empaa/tdarr-plugins --public --source=. --push
```

If the user prefers private: use `--private` instead.

- [ ] **Step 2: Push the dev branch**

```bash
git push -u origin dev
```

- [ ] **Step 3: Verify the repo is set up correctly**

```bash
gh repo view empaa/tdarr-plugins
```
