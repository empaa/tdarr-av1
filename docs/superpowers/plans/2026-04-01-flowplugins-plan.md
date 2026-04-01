# FlowPlugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement two Tdarr FlowPlugins (av1anEncode and abAv1Encode) with a shared utility library, baked into the Docker image.

**Architecture:** Thin plugin files handle UI and orchestration; shared library modules handle process management, progress tracking, logging, audio merging, encoder flags, and downscaling. Plugins are copied into both tdarr and tdarr_node Docker images at their respective plugin paths.

**Tech Stack:** Node.js (CommonJS), child_process, fs — running inside Tdarr's Node.js runtime. Docker multi-stage build.

**Reference:** The old plugin at `old_resources/Plugins/FlowPlugins/LocalFlowPlugins/tools/av1Encode/1.2.0/index.js` is the source of truth for encoder flags, HDR metadata tables, progress algorithms, and process management patterns. Refer to it for any implementation details not fully spelled out in this plan.

**Binary paths:** In the new Docker image, all binaries are at `/usr/local/bin/` (av1an, ab-av1, ffmpeg, mkvmerge, vspipe). VMAF models at `/usr/local/share/vmaf/`. VapourSynth config at `/etc/vapoursynth/vapoursynth.conf`. No wrapper scripts or stack_path needed.

**Plugin container paths:**
- Server: `/app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/`
- Node: `/app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/`

---

## File Structure

```
plugins/FlowPlugins/LocalFlowPlugins/
  av1Shared/1.0.0/
    processManager.js    — spawn encoder, PPID watchdog, killAll, signal handlers
    progressTracker.js   — av1an file-polling tracker + ab-av1 stdout tracker
    logger.js            — filtered dashboard log + debug log to workDir
    audioMerge.js        — mkvmerge audio probe + merge
    encoderFlags.js      — aom/svt-av1 flag builders, HDR metadata detection
    downscale.js         — resolution presets, VapourSynth filter, ab-av1 downscale args
  av1anEncode/1.0.0/
    index.js             — av1an FlowPlugin (details + plugin)
  abAv1Encode/1.0.0/
    index.js             — ab-av1 FlowPlugin (details + plugin)
```

---

### Task 1: processManager.js — Process lifecycle management

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/processManager.js`

This module manages spawning encoder processes, PPID watchdog, and cleanup.

- [ ] **Step 1: Create processManager.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/processManager.js
'use strict';

const cp = require('child_process');
const path = require('path');

/**
 * Creates a process manager for encoder child processes.
 * Handles spawning with detached process groups, PPID watchdog,
 * and cleanup on cancellation or completion.
 *
 * @param {Function} jobLog - Tdarr dashboard log function
 * @param {Function} dbg - Debug log function
 * @returns {Object} Process manager API
 */
const createProcessManager = (jobLog, dbg) => {
  const activeChildren = new Set();
  const ppidWatchers = [];

  const killAll = () => {
    dbg(`[KILL] killAll called  activeChildren=${activeChildren.size}`);
    for (const child of activeChildren) {
      try {
        if (!child.killed) {
          dbg(`[KILL] SIGTERM -> pgid=${child.pid}`);
          try { process.kill(-child.pid, 'SIGTERM'); } catch (_) {}
          child.kill('SIGTERM');
        }
      } catch (_) {}
    }
    // Follow up with SIGKILL after 3s
    setTimeout(() => {
      for (const child of activeChildren) {
        try {
          if (!child.killed) {
            dbg(`[KILL] SIGKILL -> pgid=${child.pid}`);
            try { process.kill(-child.pid, 'SIGKILL'); } catch (_) {}
            child.kill('SIGKILL');
          }
        } catch (_) {}
      }
    }, 3000);
  };

  const startPpidWatcher = (encoderPid) => {
    const workerPid = process.pid;
    const script = [
      `while kill -0 ${workerPid} 2>/dev/null; do sleep 2; done;`,
      `kill -TERM -${encoderPid} 2>/dev/null;`,
      `sleep 3;`,
      `kill -KILL -${encoderPid} 2>/dev/null`,
    ].join(' ');
    const watcher = cp.spawn('bash', ['-c', script], {
      detached: true,
      stdio: 'ignore',
    });
    watcher.unref();
    ppidWatchers.push(watcher);
    dbg(`[WATCHDOG] ppid-watcher pid=${watcher.pid}  worker=${workerPid}  encoder-pgid=${encoderPid}`);
  };

  const stopPpidWatchers = () => {
    for (const w of ppidWatchers) {
      try { w.kill('SIGTERM'); } catch (_) {}
    }
    ppidWatchers.length = 0;
    dbg('[WATCHDOG] ppid-watchers cancelled');
  };

  /**
   * Spawn an encoder process with detached process group.
   *
   * @param {string} bin - Path to binary
   * @param {string[]} spawnArgs - Arguments
   * @param {Object} opts - Options:
   *   env: child environment
   *   cwd: working directory
   *   onLine(line): called for every output line (dashboard + debug routing)
   *   filter(line): if provided, only lines passing filter go to dashboard
   *   silent: buffer output, dump on failure only
   *   onSpawn(pid): called with child PID immediately after spawn
   * @returns {Promise<number>} Exit code
   */
  const spawnAsync = (bin, spawnArgs, opts) => {
    opts = opts || {};
    return new Promise((resolve) => {
      dbg(`> ${path.basename(bin)} ${spawnArgs.slice(0, 6).join(' ')}${spawnArgs.length > 6 ? ' ...' : ''}`);

      const child = cp.spawn(bin, spawnArgs, {
        env: opts.env || process.env,
        cwd: opts.cwd || undefined,
        stdio: ['ignore', 'pipe', 'pipe'],
        detached: true,
      });
      child.unref();

      activeChildren.add(child);
      if (opts.onSpawn) opts.onSpawn(child.pid);

      const silentBuf = [];
      let lastLine = '';
      const handleData = (data) => {
        const text = data.toString();
        const lines = (lastLine + text).split(/[\r\n]/);
        lastLine = lines.pop();
        for (const line of lines) {
          const l = line.trim();
          if (!l) continue;
          if (opts.onLine) opts.onLine(l);
          if (opts.filter && !opts.filter(l)) continue;
          if (opts.silent) { silentBuf.push(l); } else { jobLog(l); }
        }
      };

      child.stdout.on('data', handleData);
      child.stderr.on('data', handleData);

      child.on('close', (code, signal) => {
        activeChildren.delete(child);
        if (lastLine.trim()) {
          const l = lastLine.trim();
          if (opts.onLine) opts.onLine(l);
          if (!opts.filter || opts.filter(l)) {
            if (opts.silent) { silentBuf.push(l); } else { jobLog(l); }
          }
        }
        const exitCode = code !== null ? code : signal ? 1 : 0;
        if (opts.silent && exitCode !== 0) {
          silentBuf.forEach((l) => jobLog(l));
        }
        dbg(`< ${path.basename(bin)} exited ${exitCode}${signal ? ` (signal ${signal})` : ''}`);
        resolve(exitCode);
      });

      child.on('error', (err) => {
        activeChildren.delete(child);
        jobLog(`ERROR spawning ${path.basename(bin)}: ${err.message}`);
        resolve(1);
      });
    });
  };

  // Lightweight signal handlers as backup
  let cancelHandler = null;

  const installCancelHandler = (onCancel) => {
    cancelHandler = () => {
      jobLog('[AV1] job cancelled -- killing encoder children');
      stopPpidWatchers();
      killAll();
      if (onCancel) onCancel();
      process.exit(1);
    };
    process.once('SIGTERM', cancelHandler);
    process.once('SIGINT', cancelHandler);
    process.once('disconnect', cancelHandler);
  };

  const removeCancelHandler = () => {
    if (cancelHandler) {
      process.off('SIGTERM', cancelHandler);
      process.off('SIGINT', cancelHandler);
      process.off('disconnect', cancelHandler);
      cancelHandler = null;
    }
  };

  const cleanup = () => {
    stopPpidWatchers();
    killAll();
    removeCancelHandler();
  };

  return {
    spawnAsync,
    startPpidWatcher,
    stopPpidWatchers,
    killAll,
    installCancelHandler,
    removeCancelHandler,
    cleanup,
  };
};

module.exports = { createProcessManager };
```

- [ ] **Step 2: Verify file was created**

Run: `cat plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/processManager.js | head -5`
Expected: Shows the header lines of the file.

- [ ] **Step 3: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/processManager.js
git commit -m "feat: add processManager shared module for encoder lifecycle"
```

---

### Task 2: logger.js — Dashboard and debug logging

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/logger.js`

- [ ] **Step 1: Create logger.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/logger.js
'use strict';

const fs = require('fs');
const path = require('path');

/**
 * Creates a logger with filtered dashboard output and full debug file.
 *
 * @param {Function} tdarrJobLog - Tdarr's args.jobLog function
 * @param {string} workDir - args.workDir for debug log file
 * @returns {Object} Logger API
 */
const createLogger = (tdarrJobLog, workDir) => {
  const debugLogPath = path.join(workDir, 'av1-debug.log');

  const jobLog = (msg) => {
    if (typeof tdarrJobLog === 'function') tdarrJobLog(msg);
    else console.log(`[AV1] ${msg}`);
  };

  const dbg = (msg) => {
    const line = `[DBG ${new Date().toISOString()}] ${msg}\n`;
    try { fs.appendFileSync(debugLogPath, line); } catch (_) {}
  };

  const flush = () => {
    // No-op for now — debug log is append-only via appendFileSync
  };

  return { jobLog, dbg, debugLogPath, flush };
};

/**
 * Human-readable file size.
 * @param {number} bytes
 * @returns {string}
 */
const humanSize = (bytes) => {
  if (bytes <= 0) return '0 B';
  const gib = bytes / (1024 ** 3);
  if (gib >= 1) return `${gib.toFixed(2)} GiB`;
  return `${(bytes / (1024 ** 2)).toFixed(1)} MiB`;
};

module.exports = { createLogger, humanSize };
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/logger.js
git commit -m "feat: add logger shared module for dashboard and debug logging"
```

---

### Task 3: encoderFlags.js — Encoder flag builders and HDR metadata

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/encoderFlags.js`

Port the HDR metadata tables and flag builders from the old plugin (lines 448-576 of old index.js). The flags are tested and researched — carry them over exactly.

- [ ] **Step 1: Create encoderFlags.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/encoderFlags.js
'use strict';

// HDR / CICP metadata lookup tables
// Maps ffprobe field values to encoder-specific flag values
const primTable = {
  bt709:     { aom: 'bt709',    svt: 1 },
  bt470m:    { aom: 'bt470m',   svt: 4 },
  bt470bg:   { aom: 'bt470bg',  svt: 5 },
  smpte170m: { aom: 'smpte170m', svt: 6 },
  smpte240m: { aom: 'smpte240m', svt: 7 },
  film:      { aom: 'film',     svt: 8 },
  bt2020:    { aom: 'bt2020',   svt: 9 },
  smpte428:  { aom: 'smpte428', svt: 10 },
  smpte431:  { aom: 'smpte431', svt: 11 },
  smpte432:  { aom: 'smpte432', svt: 12 },
};

const transTable = {
  bt709:         { aom: 'bt709',        svt: 1 },
  bt470m:        { aom: 'bt470m',       svt: 4 },
  bt470bg:       { aom: 'bt470bg',      svt: 5 },
  smpte170m:     { aom: 'smpte170m',    svt: 6 },
  smpte240m:     { aom: 'smpte240m',    svt: 7 },
  linear:        { aom: 'linear',       svt: 8 },
  log100:        { aom: 'log100',       svt: 9 },
  log316:        { aom: 'log316',       svt: 10 },
  iec61966:      { aom: 'iec61966',     svt: 12 },
  'bt2020-10':   { aom: 'bt2020-10bit', svt: 14 },
  'bt2020-12':   { aom: 'bt2020-12bit', svt: 15 },
  smpte2084:     { aom: 'smpte2084',    svt: 16 },
  smpte428:      { aom: 'smpte428',     svt: 17 },
  'arib-std-b67': { aom: 'arib-std-b67', svt: 18 },
};

const matTable = {
  bt709:                { aom: 'bt709',              svt: 1 },
  fcc:                  { aom: 'fcc73',              svt: 4 },
  bt470bg:              { aom: 'bt470bg',            svt: 5 },
  smpte170m:            { aom: 'smpte170m',          svt: 6 },
  smpte240m:            { aom: 'smpte240m',          svt: 7 },
  bt2020nc:             { aom: 'bt2020ncl',          svt: 9 },
  bt2020ncl:            { aom: 'bt2020ncl',          svt: 9 },
  bt2020c:              { aom: 'bt2020cl',           svt: 10 },
  bt2020cl:             { aom: 'bt2020cl',           svt: 10 },
  smpte2085:            { aom: 'smpte2085',          svt: 11 },
  'chroma-derived-ncl': { aom: 'chroma-derived-ncl', svt: 12 },
  'chroma-derived-cl':  { aom: 'chroma-derived-cl',  svt: 13 },
  ictcp:                { aom: 'ictcp',              svt: 14 },
};

const chromaTable = {
  left:    { svt: 1 },
  topleft: { svt: 2 },
};

/**
 * Detect HDR/CICP metadata from ffprobe stream data.
 * @param {Object} stream - First video stream from ffProbeData.streams
 * @returns {Object} { prim, trans, matrix, chroma, hdrAom, hdrSvt }
 */
const detectHdrMeta = (stream) => {
  const prim   = primTable[stream.color_primaries];
  const trans  = transTable[stream.color_transfer];
  const matrix = matTable[stream.color_space];
  const chroma = chromaTable[stream.chroma_location];

  let hdrAom = '';
  let hdrSvt = '';

  if (prim && trans && matrix) {
    hdrAom = `--color-primaries=${prim.aom} --transfer-characteristics=${trans.aom} --matrix-coefficients=${matrix.aom}`;
    hdrSvt = [
      `--color-primaries ${prim.svt}`,
      `--transfer-characteristics ${trans.svt}`,
      `--matrix-coefficients ${matrix.svt}`,
      chroma ? `--chroma-sample-position ${chroma.svt}` : '',
    ].filter(Boolean).join(' ');
  }

  return { prim, trans, matrix, chroma, hdrAom, hdrSvt };
};

/**
 * Build aomenc encoder flags for av1an.
 * @param {number} preset - cpu-used (0-8)
 * @param {number} threadsPerWorker - threads per av1an worker
 * @param {string} hdrAom - HDR flag string from detectHdrMeta
 * @returns {string} Space-separated aomenc flags
 */
const buildAomFlags = (preset, threadsPerWorker, hdrAom) => {
  return [
    '--end-usage=q', `--cpu-used=${preset}`, `--threads=${threadsPerWorker}`,
    '--tune=ssim', '--enable-fwd-kf=0', '--disable-kf', '--kf-max-dist=9999',
    '--enable-qm=1', '--bit-depth=10', '--lag-in-frames=48',
    '--tile-columns=0', '--tile-rows=0', '--sb-size=dynamic',
    '--deltaq-mode=0', '--aq-mode=0', '--arnr-strength=1', '--arnr-maxframes=4',
    '--enable-chroma-deltaq=1', '--enable-dnl-denoising=0',
    '--disable-trellis-quant=0', '--quant-b-adapt=1',
    '--enable-keyframe-filtering=1', hdrAom,
  ].filter(Boolean).join(' ');
};

/**
 * Build SVT-AV1 encoder flags for av1an.
 * @param {number} preset - SVT preset (0-13)
 * @param {number} svtLp - thread pool limit for --lp
 * @param {string} hdrSvt - HDR flag string from detectHdrMeta
 * @returns {string} Space-separated SVT-AV1 flags
 */
const buildSvtFlags = (preset, svtLp, hdrSvt) => {
  return [
    '--rc 0', `--preset ${preset}`, '--tune 1', '--input-depth 10',
    '--lookahead 48', '--keyint -1', '--irefresh-type 2',
    '--enable-overlays 1', '--enable-variance-boost 1',
    '--variance-boost-strength 2', '--variance-octile 6',
    '--enable-qm 1', '--qm-min 0', '--qm-max 15',
    '--chroma-qm-min 8', '--chroma-qm-max 15',
    '--tf-strength 1', '--sharpness 1', '--tile-columns 1',
    '--scm 0', '--pin 0', `--lp ${svtLp}`, hdrSvt,
  ].filter(Boolean).join(' ');
};

/**
 * Build SVT-AV1 flags for ab-av1 (hq tier settings).
 * ab-av1 uses --svt key=value format.
 * @param {number} cpu - total available CPU threads
 * @param {number} lookahead - ab-av1 lookahead value
 * @returns {string} Space-separated ab-av1 SVT flags
 */
const buildAbAv1SvtFlags = (cpu, lookahead) => {
  return [
    '--svt tune=1', '--svt enable-variance-boost=1',
    '--svt variance-boost-strength=2', '--svt variance-octile=6',
    '--svt enable-qm=1', '--svt qm-min=0', '--svt qm-max=15',
    '--svt chroma-qm-min=8', '--svt chroma-qm-max=15',
    '--svt irefresh-type=2', '--svt scm=0', '--svt sharpness=1',
    '--svt tf-strength=1', '--svt tile-columns=1', '--svt enable-overlays=1',
    `--svt lookahead=${lookahead}`, '--keyint 10s', '--scd true',
    '--svt pin=0', `--svt lp=${Math.min(6, cpu)}`,
  ].join(' ');
};

/**
 * Calculate thread budget for av1an.
 * @param {number} availableThreads - os.cpus().length
 * @param {string} encoder - 'aom' or 'svt-av1'
 * @param {boolean} is4kHdr - true for 4K HDR content
 * @returns {Object} { maxWorkers, threadsPerWorker, svtLp }
 */
const calculateThreadBudget = (availableThreads, encoder, is4kHdr) => {
  let threadsPerWorker, maxWorkers;

  if (encoder === 'aom') {
    threadsPerWorker = Math.max(4, Math.floor(availableThreads / 4));
    maxWorkers = Math.max(1, Math.floor(availableThreads / threadsPerWorker));
  } else {
    // svt-av1: more workers, fewer threads (SVT internal pool capped at --lp 6)
    threadsPerWorker = Math.min(6, Math.max(4, Math.floor(availableThreads / 6)));
    maxWorkers = Math.max(1, Math.floor(availableThreads / threadsPerWorker));
  }

  if (is4kHdr) {
    maxWorkers = Math.max(1, Math.floor(maxWorkers / 2));
  }

  const svtLp = Math.min(6, threadsPerWorker);

  return { maxWorkers, threadsPerWorker, svtLp };
};

module.exports = {
  detectHdrMeta,
  buildAomFlags,
  buildSvtFlags,
  buildAbAv1SvtFlags,
  calculateThreadBudget,
};
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/encoderFlags.js
git commit -m "feat: add encoderFlags shared module with HDR metadata and flag builders"
```

---

### Task 4: downscale.js — Resolution presets and VapourSynth configuration

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/downscale.js`

- [ ] **Step 1: Create downscale.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/downscale.js
'use strict';

const RESOLUTION_PRESETS = {
  '720p':  { width: 1280, height: 720 },
  '1080p': { width: 1920, height: 1080 },
  '1440p': { width: 2560, height: 1440 },
};

/**
 * Build VapourSynth .vpy script lines for input downscale.
 * Appended after the source loading line in the .vpy script.
 * Uses Lanczos3 resize to target width, maintaining aspect ratio.
 *
 * @param {string} resolution - '720p', '1080p', or '1440p'
 * @returns {string[]} Array of Python lines to append to .vpy script
 */
const buildVsDownscaleLines = (resolution) => {
  const preset = RESOLUTION_PRESETS[resolution];
  if (!preset) return [];
  return [
    'src_w, src_h = src.width, src.height',
    `tgt_w = ${preset.width}`,
    'tgt_h = int(round(src_h * tgt_w / src_w / 2) * 2)',
    'src = core.resize.Lanczos(src, width=tgt_w, height=tgt_h, filter_param_a=3)',
  ];
};

/**
 * Build av1an VMAF resolution args for downscaled content.
 * When downscaling, VMAF comparison must use a matching resolution.
 *
 * @param {string} resolution - '720p', '1080p', or '1440p'
 * @returns {string[]} av1an CLI args for VMAF resolution
 */
const buildAv1anVmafResArgs = (resolution) => {
  const preset = RESOLUTION_PRESETS[resolution];
  if (!preset) return [];
  // For downscaled content, use half the target width for VMAF probes
  const vmafW = Math.floor(preset.width / 2);
  const vmafH = Math.floor(preset.height / 2);
  // Round height to even
  const vmafHEven = vmafH % 2 === 0 ? vmafH : vmafH + 1;
  return ['--vmaf-res', `${vmafW}x${vmafHEven}`];
};

/**
 * Build ab-av1 native downscale args.
 * Uses ffmpeg's scale filter via --vfilter.
 *
 * @param {string} resolution - '720p', '1080p', or '1440p'
 * @returns {string[]} ab-av1 CLI args for downscaling
 */
const buildAbAv1DownscaleArgs = (resolution) => {
  const preset = RESOLUTION_PRESETS[resolution];
  if (!preset) return [];
  return ['--vfilter', `scale=${preset.width}:-2:flags=lanczos`];
};

module.exports = {
  RESOLUTION_PRESETS,
  buildVsDownscaleLines,
  buildAv1anVmafResArgs,
  buildAbAv1DownscaleArgs,
};
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/downscale.js
git commit -m "feat: add downscale shared module with resolution presets"
```

---

### Task 5: audioMerge.js — Audio probe and mkvmerge muxing

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/audioMerge.js`

- [ ] **Step 1: Create audioMerge.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/audioMerge.js
'use strict';

const fs = require('fs');
const path = require('path');
const cp = require('child_process');

const MKVMERGE_BIN = '/usr/local/bin/mkvmerge';

/**
 * Probe audio+subtitle size by extracting non-video tracks.
 * Uses mkvmerge -D (drop video) to create a temp file and measure its size.
 *
 * @param {string} inputPath - Path to input file
 * @param {string} workDir - Working directory for temp file
 * @param {Function} jobLog - Dashboard log function
 * @param {Function} dbg - Debug log function
 * @returns {Promise<number>} Size of non-video tracks in GB
 */
const probeAudioSize = async (inputPath, workDir, jobLog, dbg) => {
  const tmpAudio = path.join(workDir, 'audio-size-probe.mkv');
  try {
    await new Promise((resolve) => {
      const proc = cp.spawn(MKVMERGE_BIN, ['-q', '-o', tmpAudio, '-D', inputPath]);
      proc.on('close', resolve);
      proc.on('error', resolve);
    });
    if (!fs.existsSync(tmpAudio)) return 0;
    const bytes = fs.statSync(tmpAudio).size;
    try { fs.unlinkSync(tmpAudio); } catch (_) {}
    const gb = bytes / (1024 ** 3);
    const mb = bytes / (1024 ** 2);
    jobLog(`[init] audio+subs size: ${mb.toFixed(1)} MiB -- will be added to output estimate`);
    dbg(`probeAudioSize: ${gb.toFixed(3)} GiB`);
    return gb;
  } catch (_) {
    try { fs.unlinkSync(tmpAudio); } catch (__) {}
    return 0;
  }
};

/**
 * Merge av1an video-only output with original audio and subtitle tracks.
 * av1an outputs video-only MKV; this adds audio+subs from the original file.
 *
 * @param {string} videoPath - Path to av1an video-only output
 * @param {string} inputPath - Path to original input file (audio/subs source)
 * @param {string} outputPath - Path for final merged output
 * @param {Object} processManager - Process manager instance for spawnAsync
 * @param {Function} jobLog - Dashboard log function
 * @param {Function} dbg - Debug log function
 * @returns {Promise<boolean>} true if merge succeeded
 */
const mergeAudioVideo = async (videoPath, inputPath, outputPath, processManager, jobLog, dbg) => {
  jobLog('[mux] muxing audio + subtitles from original via mkvmerge...');

  const muxExit = await processManager.spawnAsync(MKVMERGE_BIN, [
    '-o', outputPath,
    videoPath,
    '--no-video', inputPath,
  ], { silent: true });

  if (muxExit >= 2) {
    jobLog(`ERROR: mkvmerge failed (exit ${muxExit})`);
    return false;
  }
  if (muxExit === 1) {
    jobLog('[mux] mkvmerge warnings (exit 1) -- treating as success');
  }
  if (!fs.existsSync(outputPath)) {
    jobLog('ERROR: mux output not found after mkvmerge');
    return false;
  }
  dbg(`[mux] merge complete: ${outputPath}`);
  return true;
};

module.exports = { probeAudioSize, mergeAudioVideo };
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/audioMerge.js
git commit -m "feat: add audioMerge shared module for mkvmerge probe and muxing"
```

---

### Task 6: progressTracker.js — Dashboard progress for both encoders

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/progressTracker.js`

This is the most complex module. Port the av1an file-polling logic and ab-av1 stdout parsing from the old plugin.

- [ ] **Step 1: Create progressTracker.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/progressTracker.js
'use strict';

const fs = require('fs');
const path = require('path');
const { humanSize } = require('./logger');

const POLL_INTERVAL_MS = 5000;
const LOG_INTERVAL_MS = 10 * 60 * 1000; // throttle dashboard log to every 10 min

// ─── Shared helpers ──────────────────────────────────────────────────────────

const formatEta = (seconds) => {
  if (seconds <= 0) return '';
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
};

// ─── av1an progress tracker ──────────────────────────────────────────────────

/**
 * Creates a file-polling progress tracker for av1an.
 * Reads scenes.json, done.json, and log files from av1an's work directory.
 *
 * @param {Object} opts
 * @param {string} opts.workBase - av1an work base directory (contains work/ and log dir)
 * @param {number} opts.maxWorkers - number of av1an workers
 * @param {number} opts.audioSizeGb - probed audio size for estimation offset
 * @param {number} opts.sourceSizeGb - source file size for max% check
 * @param {number} opts.maxEncodedPercent - abort threshold
 * @param {Function} opts.updateWorker - Tdarr updateWorker function
 * @param {Function} opts.jobLog - dashboard log
 * @param {Function} opts.dbg - debug log
 * @param {Function} opts.onSizeExceeded - called when estimated output exceeds limit
 * @returns {Object} { start(), stop() }
 */
const createAv1anTracker = (opts) => {
  const {
    workBase, maxWorkers, audioSizeGb, sourceSizeGb,
    maxEncodedPercent, updateWorker, jobLog, dbg, onSizeExceeded,
  } = opts;

  let interval = null;
  let smoothedFps = 0;
  let encodeStartMs = 0;
  let lastProgressLogMs = 0;

  const av1anTemp = path.join(workBase, 'work');
  const logDir = path.join(workBase, 'vs', 'logs');
  const scenesFile = path.join(av1anTemp, 'scenes.json');
  const doneFile = path.join(av1anTemp, 'done.json');

  const pushStats = (fields) => {
    updateWorker(fields);
  };

  const poll = () => {
    // Check for IPC disconnect (Tdarr cancel)
    if (process.connected === false) {
      dbg('[WATCHDOG] IPC disconnected in av1an interval');
      return 'cancelled';
    }

    if (!fs.existsSync(scenesFile) || !fs.existsSync(doneFile)) {
      dbg(`progress: waiting for files | scenes=${fs.existsSync(scenesFile)} done=${fs.existsSync(doneFile)}`);
      return 'waiting';
    }

    // Parse scenes.json
    let scenes, done;
    try { scenes = JSON.parse(fs.readFileSync(scenesFile, 'utf8')); }
    catch (e) { dbg(`progress: failed to parse scenes.json: ${e.message}`); return 'error'; }
    try { done = JSON.parse(fs.readFileSync(doneFile, 'utf8')); }
    catch (e) { dbg(`progress: failed to parse done.json: ${e.message}`); return 'error'; }

    const totalFrames = scenes.frames || 0;
    const totalChunks = Array.isArray(scenes.scenes) ? scenes.scenes.length : 0;
    if (totalFrames === 0) return 'waiting';

    const doneEntries = done.done || {};
    const doneChunks = Object.keys(doneEntries).length;
    const encodedFrames = Object.values(doneEntries).reduce((s, e) => s + (e.frames || 0), 0);
    const encodedBytes = Object.values(doneEntries).reduce((s, e) => s + (e.size_bytes || 0), 0);

    // Detect phase from log directory
    if (doneChunks >= 1 && encodeStartMs === 0) {
      encodeStartMs = Date.now();
      pushStats({ status: 'Encoding' });
    }

    // Read FPS from av1an log files
    let workerFps = 0;
    if (fs.existsSync(logDir)) {
      let logFiles;
      try { logFiles = fs.readdirSync(logDir).filter((f) => f.startsWith('av1an.log')); }
      catch (_) { logFiles = []; }

      const allFpsSamples = [];
      for (const lf of logFiles) {
        let lines;
        try { lines = fs.readFileSync(path.join(logDir, lf), 'utf8').split('\n'); }
        catch (_) { continue; }

        const recent = lines.slice(-300);
        for (const line of recent) {
          const m1 = line.match(/(\d+(?:\.\d+)?)\s+fps,/i);
          if (m1) { allFpsSamples.push(parseFloat(m1[1])); continue; }
          if (/finished/i.test(line)) {
            const m2 = line.match(/(\d+(?:\.\d+)?)\s*fps/i);
            if (m2) allFpsSamples.push(parseFloat(m2[1]));
          }
        }
      }

      const samples = Math.max(2, maxWorkers * 2);
      const recentSamples = allFpsSamples.slice(-samples);
      if (recentSamples.length >= 2) {
        const sorted = [...recentSamples].sort((a, b) => a - b);
        const trimmed = sorted.length > 2 ? sorted.slice(1, -1) : sorted;
        workerFps = trimmed.reduce((s, v) => s + v, 0) / trimmed.length;
      } else if (recentSamples.length === 1) {
        workerFps = recentSamples[0];
      }
    }

    // Smooth and blend
    if (workerFps > 0) {
      smoothedFps = smoothedFps === 0 ? workerFps : smoothedFps * 0.7 + workerFps * 0.3;
    }
    const chunkTotalFps = smoothedFps * maxWorkers;

    let throughputFps = chunkTotalFps;
    if (encodeStartMs > 0 && encodedFrames > 0) {
      const elapsedS = (Date.now() - encodeStartMs) / 1000;
      if (elapsedS > 0) throughputFps = encodedFrames / elapsedS;
    }
    const totalFps = chunkTotalFps > 0 ? (chunkTotalFps + throughputFps) / 2 : throughputFps;

    // Percentage and ETA
    const pct = Math.min(99, Math.round((encodedFrames / totalFrames) * 100));
    const remainingFrames = totalFrames - encodedFrames;
    const etaS = totalFps > 0 ? Math.round(remainingFrames / totalFps) : 0;
    const etaStr = formatEta(etaS);

    // Size estimation: encoded chunks + audio
    const estVideoBytes = encodedFrames > 0
      ? Math.round((encodedBytes / encodedFrames) * totalFrames) : 0;
    const actualSizeGb = encodedBytes / (1024 ** 3);
    const estFinalSizeGb = (estVideoBytes / (1024 ** 3)) + audioSizeGb;

    // Early exit check (after ~10% progress)
    if (maxEncodedPercent < 100 && pct >= 10 && sourceSizeGb > 0 && estFinalSizeGb > 0) {
      const estPercent = (estFinalSizeGb / sourceSizeGb) * 100;
      dbg(`size-check: est=${humanSize(estVideoBytes + audioSizeGb * 1024 ** 3)}  src=${humanSize(sourceSizeGb * 1024 ** 3)}  est%=${estPercent.toFixed(1)}  limit=${maxEncodedPercent}%`);
      if (estPercent > maxEncodedPercent) {
        jobLog(`[av1an] ABORT: estimated output ${estPercent.toFixed(1)}% of source exceeds limit of ${maxEncodedPercent}% -- killing encode`);
        onSizeExceeded();
        return 'exceeded';
      }
    }

    // Push stats to dashboard
    pushStats({
      percentage: pct,
      fps: Math.round(totalFps * 10) / 10,
      ETA: etaStr,
      outputFileSizeInGbytes: actualSizeGb,
      estimatedFinalFileSizeInGbytes: estFinalSizeGb,
      estimatedFinalSize: estFinalSizeGb,
      estSize: estFinalSizeGb,
    });

    // Throttled dashboard log
    const now = Date.now();
    if (now - lastProgressLogMs >= LOG_INTERVAL_MS) {
      lastProgressLogMs = now;
      jobLog(
        `[av1an] ${pct}%  ${doneChunks}/${totalChunks} chunks` +
        `  ${totalFps > 0 ? totalFps.toFixed(1) + ' fps' : ''}` +
        (etaStr ? `  ETA ${etaStr}` : '') +
        (estFinalSizeGb > 0 ? `  est ${humanSize(estFinalSizeGb * 1024 ** 3)}` : ''),
      );
    }

    // Debug log every tick
    dbg(
      `PROGRESS ${pct}%  chunk ${doneChunks}/${totalChunks}` +
      `  frames ${encodedFrames}/${totalFrames}` +
      `  workerFps=${workerFps.toFixed(1)}  smoothed=${smoothedFps.toFixed(1)}` +
      `  totalFps=${totalFps.toFixed(1)}  actual=${humanSize(encodedBytes)}  est=${humanSize(estFinalSizeGb * 1024 ** 3)}` +
      (etaStr ? `  ETA ${etaStr}` : ''),
    );

    return 'ok';
  };

  return {
    start: () => { interval = setInterval(poll, POLL_INTERVAL_MS); },
    stop: () => {
      if (interval) { clearInterval(interval); interval = null; }
      poll(); // final read
    },
  };
};

// ─── ab-av1 progress tracker ─────────────────────────────────────────────────

/**
 * Creates a stdout-parsing progress tracker for ab-av1.
 *
 * @param {Object} opts
 * @param {string} opts.outputPath - path where ab-av1 writes its output file
 * @param {number} opts.sourceSizeGb - source file size for dashboard stats
 * @param {Function} opts.updateWorker - Tdarr updateWorker function
 * @param {Function} opts.jobLog - dashboard log
 * @param {Function} opts.dbg - debug log
 * @param {Function} opts.onSizeExceeded - called when ab-av1 reports compression limit
 * @returns {Object} { onLine(line), startInterval(), stop() }
 */
const createAbAv1Tracker = (opts) => {
  const {
    outputPath, sourceSizeGb, updateWorker, jobLog, dbg, onSizeExceeded,
  } = opts;

  let interval = null;
  let currentPct = 0;
  let currentFps = 0;
  let encodeStarted = false;
  let encodeReached100 = false;
  let reached100AtMs = 0;
  let lastHeartbeatLogMs = 0;
  let lastProgressLogMs = 0;
  let lastEtaSec = 0;
  let lastEtaReceivedMs = 0;
  let encodeStartMs = 0;

  const pushStats = (fields) => {
    updateWorker(fields);
  };

  /**
   * Called for every line of ab-av1 stdout/stderr.
   * Parses progress, phase transitions, and error conditions.
   */
  const onLine = (line) => {
    dbg(`[ab-av1] ${line}`);

    // Detect encode start
    if (!encodeStarted && /command::encode\]\s*encoding/i.test(line)) {
      encodeStarted = true;
      encodeStartMs = Date.now();
      pushStats({ status: 'Encoding' });
      jobLog(line);
      return;
    }

    // CRF search summary lines — always surface
    if (/command::crf_search\]/i.test(line)) {
      jobLog(line);
    }

    // Predicted video stream size from CRF search
    const predM = line.match(/predicted video stream size\s+([\d.]+)\s*(GiB|MiB)/i);
    if (predM) {
      const val = parseFloat(predM[1]);
      const videoGb = /MiB/i.test(predM[2]) ? val / 1024 : val;
      pushStats({ estimatedFinalFileSizeInGbytes: videoGb, estimatedFinalSize: videoGb, estSize: videoGb });
      dbg(`[ab-av1] estFinalSize updated: ${videoGb.toFixed(3)} GiB`);
    }

    // Error/warning lines — always surface
    if (/\b(error|warn|panic|failed|abort)\b/i.test(line)) {
      jobLog(line);
    }

    // CRF search failure / size limit exceeded
    if (/failed to find a suitable crf/i.test(line)) {
      jobLog('[ab-av1] could not find a suitable CRF -- passing through');
      onSizeExceeded();
    }
    if (/encoded size .* too large|max.encoded.percent|will not be smaller/i.test(line)) {
      jobLog('[ab-av1] estimated output exceeds max-encoded-percent limit');
      onSizeExceeded();
    }

    // Collect progress state during encoding
    if (encodeStarted) {
      const pctM = line.match(/\b(\d{1,3})%(?!\d)/);
      if (pctM) {
        const p = parseInt(pctM[1], 10);
        if (p === 100 && !encodeReached100) {
          encodeReached100 = true;
          reached100AtMs = Date.now();
          lastHeartbeatLogMs = Date.now();
          jobLog('[ab-av1] video encode 100% -- post-encode (audio / mux)...');
          pushStats({ status: 'Finalizing' });
          currentPct = 99;
        } else if (p > 0 && p < 100) {
          currentPct = p;
        }
      }

      if (!encodeReached100) {
        const fpsM = line.match(/(\d+\.?\d*)\s*fps/i);
        if (fpsM) {
          currentFps = parseFloat(fpsM[1]);
        }

        const etaM = line.match(/\beta\s+(\d+)\s*(minute|second|min|sec)/i);
        if (etaM) {
          const etaVal = parseInt(etaM[1], 10);
          const etaUnit = etaM[2].toLowerCase();
          lastEtaSec = /^s/.test(etaUnit) ? etaVal : etaVal * 60;
          lastEtaReceivedMs = Date.now();
        }
      }
    }
  };

  const intervalTick = () => {
    // Poll output file size
    let actualSizeGb = 0;
    try {
      if (fs.existsSync(outputPath)) {
        actualSizeGb = fs.statSync(outputPath).size / (1024 ** 3);
      }
    } catch (_) {}

    // Estimated final size: trajectory from current file size and progress
    let estFinalSizeGb = 0;
    if (currentPct > 0 && actualSizeGb > 0 && !encodeReached100) {
      estFinalSizeGb = actualSizeGb / (currentPct / 100);
    }

    if (encodeReached100) {
      pushStats({
        percentage: 99,
        fps: 0,
        ETA: '',
        outputFileSizeInGbytes: actualSizeGb,
      });
      const now = Date.now();
      if (now - lastHeartbeatLogMs >= 5 * 60 * 1000) {
        const elapsedMin = Math.round((now - reached100AtMs) / 60000);
        jobLog(`[ab-av1] post-encode still running (${elapsedMin}m since video done)...`);
        lastHeartbeatLogMs = now;
      }
      return;
    }

    if (currentPct === 0) return;

    // Compute ETA
    let remain;
    if (lastEtaSec > 0) {
      const sinceLastEta = (Date.now() - lastEtaReceivedMs) / 1000;
      remain = Math.max(0, lastEtaSec - sinceLastEta);
    } else if (encodeStartMs > 0) {
      const elapsed = (Date.now() - encodeStartMs) / 1000;
      remain = (elapsed / currentPct) * (100 - currentPct);
    } else {
      remain = 0;
    }
    const eta = formatEta(remain);

    pushStats({
      percentage: currentPct,
      fps: currentFps,
      ETA: eta,
      outputFileSizeInGbytes: actualSizeGb,
      estimatedFinalFileSizeInGbytes: estFinalSizeGb,
      estimatedFinalSize: estFinalSizeGb,
      estSize: estFinalSizeGb,
    });

    // Throttled dashboard log
    const now = Date.now();
    if (now - lastProgressLogMs >= LOG_INTERVAL_MS) {
      lastProgressLogMs = now;
      const etaMin = Math.round(remain / 60);
      jobLog(`[ab-av1] ${currentPct}%  ${currentFps.toFixed(0)} fps  ETA ~${etaMin}m`);
    }
  };

  return {
    onLine,
    startInterval: () => { interval = setInterval(intervalTick, POLL_INTERVAL_MS); },
    stop: () => { if (interval) { clearInterval(interval); interval = null; } },
  };
};

module.exports = { createAv1anTracker, createAbAv1Tracker };
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/progressTracker.js
git commit -m "feat: add progressTracker shared module for av1an and ab-av1"
```

---

### Task 7: av1anEncode plugin — index.js

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/index.js`

This is the av1an FlowPlugin. It uses the shared modules for all heavy lifting.

- [ ] **Step 1: Create av1anEncode/1.0.0/index.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/index.js
'use strict';

const details = () => ({
  name: 'AV1 Encode (av1an)',
  description: [
    'Encodes video to AV1 using av1an scene-based chunked encoding.',
    'Supports aomenc (quality) and SVT-AV1 (speed) encoders.',
    'Live progress, FPS, and ETA on dashboard. Cancel kills encoder immediately.',
  ].join(' '),
  style: { borderColor: 'purple' },
  tags: 'av1,av1an,svt-av1,aomenc,vmaf',
  isStartPlugin: false,
  pType: '',
  requiresVersion: '2.00.01',
  sidebarPosition: -1,
  icon: 'faVideo',
  inputs: [
    {
      label: 'Encoder',
      name: 'encoder',
      type: 'string',
      defaultValue: 'svt-av1',
      inputUI: { type: 'dropdown', options: ['aom', 'svt-av1'] },
      tooltip: 'aom = aomenc (quality, slower). svt-av1 = SVT-AV1 (speed, faster).',
    },
    {
      label: 'Target VMAF',
      name: 'target_vmaf',
      type: 'number',
      defaultValue: '93',
      inputUI: { type: 'text' },
      tooltip: 'VMAF score to target (0-100). Typically 90-96.',
    },
    {
      label: 'QP Range',
      name: 'qp_range',
      type: 'string',
      defaultValue: '10-50',
      inputUI: { type: 'text' },
      tooltip: 'QP floor-ceiling for target-quality search. E.g. "10-50".',
    },
    {
      label: 'Preset',
      name: 'preset',
      type: 'number',
      defaultValue: '4',
      inputUI: { type: 'text' },
      tooltip: 'aomenc: cpu-used (0-8, lower=slower/better). SVT-AV1: preset (0-13). Recommended: 3 for aom, 4-6 for SVT.',
    },
    {
      label: 'Max Encoded Percent',
      name: 'max_encoded_percent',
      type: 'number',
      defaultValue: '80',
      inputUI: { type: 'text' },
      tooltip: 'Abort if estimated output exceeds this % of source size. Set to 100 to disable.',
    },
    {
      label: 'Enable Downscale',
      name: 'downscale_enabled',
      type: 'boolean',
      defaultValue: 'false',
      inputUI: { type: 'switch' },
      tooltip: 'Downscale input using VapourSynth pre-filter before encoding.',
    },
    {
      label: 'Downscale Resolution',
      name: 'downscale_resolution',
      type: 'string',
      defaultValue: '1080p',
      inputUI: { type: 'dropdown', options: ['720p', '1080p', '1440p'] },
      tooltip: 'Target resolution for downscaling. Only used when downscale is enabled.',
    },
  ],
  outputs: [
    { number: 1, tooltip: 'Encode succeeded -- output file is the encoded video+audio MKV' },
    { number: 2, tooltip: 'Not processed -- compression target not met, input file passed through unchanged' },
  ],
});

const plugin = async (args) => {
  const fs   = require('fs');
  const path = require('path');
  const os   = require('os');

  // Shared modules — imported via relative path (stable inside Docker image)
  const sharedBase = path.join(__dirname, '..', '..', 'av1Shared', '1.0.0');
  const { createProcessManager } = require(path.join(sharedBase, 'processManager'));
  const { createLogger, humanSize } = require(path.join(sharedBase, 'logger'));
  const { detectHdrMeta, buildAomFlags, buildSvtFlags, calculateThreadBudget } = require(path.join(sharedBase, 'encoderFlags'));
  const { buildVsDownscaleLines, buildAv1anVmafResArgs } = require(path.join(sharedBase, 'downscale'));
  const { probeAudioSize, mergeAudioVideo } = require(path.join(sharedBase, 'audioMerge'));
  const { createAv1anTracker } = require(path.join(sharedBase, 'progressTracker'));

  // Parse inputs
  const inputs = args.inputs || {};
  const encoder           = String(inputs.encoder || 'svt-av1');
  const targetVmaf        = Number(inputs.target_vmaf) || 93;
  const qpRange           = String(inputs.qp_range || '10-50');
  const encPreset         = Number(inputs.preset) || 4;
  const maxEncodedPercent = Number(inputs.max_encoded_percent) || 80;
  const downscaleEnabled  = inputs.downscale_enabled === true || inputs.downscale_enabled === 'true';
  const downscaleRes      = String(inputs.downscale_resolution || '1080p');

  // Binary paths (installed to /usr/local/bin in Docker image)
  const BIN = {
    av1an:    '/usr/local/bin/av1an',
    ffmpeg:   '/usr/local/bin/ffmpeg',
    vspipe:   '/usr/local/bin/vspipe',
    mkvmerge: '/usr/local/bin/mkvmerge',
  };
  const vmafModel = '/usr/local/share/vmaf/vmaf_v0.6.1.json';

  // Validate binaries
  for (const b of Object.values(BIN)) {
    if (!fs.existsSync(b)) throw new Error(`Required binary not found: ${b}`);
  }
  if (!fs.existsSync(vmafModel)) throw new Error(`VMAF model not found: ${vmafModel}`);

  // Setup logger and process manager
  const { jobLog, dbg } = createLogger(args.jobLog, args.workDir);
  const pm = createProcessManager(jobLog, dbg);

  const updateWorker = (fields) => {
    if (typeof args.updateWorker === 'function') {
      try { args.updateWorker(fields); } catch (_) {}
    }
  };

  // Source file metadata
  const file = args.inputFileObj;
  const inputPath = file._id;
  const stream = (file.ffProbeData && file.ffProbeData.streams && file.ffProbeData.streams[0]) || {};
  const height = stream.height || 0;
  const availableThreads = os.cpus().length;

  // HDR metadata
  const { hdrAom, hdrSvt } = detectHdrMeta(stream);

  // Thread budget
  const is4kHdr = height >= 2160 && stream.color_transfer === 'smpte2084';
  const { maxWorkers, threadsPerWorker, svtLp } = calculateThreadBudget(availableThreads, encoder, is4kHdr);

  // Build encoder flags
  const encFlags = encoder === 'aom'
    ? buildAomFlags(encPreset, threadsPerWorker, hdrAom)
    : buildSvtFlags(encPreset, svtLp, hdrSvt);

  // Working directories
  const workBase = path.join(args.workDir, 'av1an-work');
  const vsDir = path.join(workBase, 'vs');
  const av1anTemp = path.join(workBase, 'work');
  const outputPath = path.join(args.workDir, 'av1-output.mkv');
  fs.mkdirSync(vsDir, { recursive: true });
  fs.mkdirSync(av1anTemp, { recursive: true });

  // Log header
  jobLog('='.repeat(64));
  jobLog(`AV1AN ENCODE  encoder=${encoder}  preset=${encPreset}`);
  jobLog(`  input     : ${inputPath}`);
  jobLog(`  resolution: ${stream.width || '?'}x${height || '?'}${downscaleEnabled ? ` -> ${downscaleRes}` : ''}`);
  jobLog(`  target    : VMAF ${targetVmaf}  QP-range ${qpRange}`);
  jobLog(`  threads   : cpu=${availableThreads}  workers=${maxWorkers}  threads/worker=${threadsPerWorker}`);
  jobLog('='.repeat(64));

  // Source size for dashboard
  const sourceSizeGb = (() => {
    try { return fs.statSync(inputPath).size / (1024 ** 3); } catch (_) { return 0; }
  })();

  updateWorker({ percentage: 0, startTime: Date.now(), status: 'Processing' });

  // Probe audio size
  const audioSizeGb = await probeAudioSize(inputPath, args.workDir, jobLog, dbg);

  // VapourSynth script
  const vpyScript = path.join(vsDir, 'source.vpy');
  const lwiCache = path.join(vsDir, 'source.lwi');
  const escPy = (s) => s.replace(/\\/g, '\\\\').replace(/'/g, "\\'");

  let vpyLines = [
    'import vapoursynth as vs',
    'from math import round',
    'core = vs.core',
    `src = core.lsmas.LWLibavSource(source='${escPy(inputPath)}', cachefile='${escPy(lwiCache)}')`,
  ];
  if (downscaleEnabled) {
    vpyLines = vpyLines.concat(buildVsDownscaleLines(downscaleRes));
  }
  vpyLines.push('src.set_output()');
  fs.writeFileSync(vpyScript, vpyLines.join('\n') + '\n');
  jobLog(`[vs] .vpy written${downscaleEnabled ? ` (Lanczos3 -> ${downscaleRes})` : ' (passthrough)'}`);

  // Pre-generate .lwi index
  if (!fs.existsSync(lwiCache)) {
    jobLog('[vs] pre-generating .lwi index...');
    updateWorker({ status: 'Indexing' });
    const lwiExit = await pm.spawnAsync(BIN.vspipe, ['--info', vpyScript], {
      cwd: vsDir,
      silent: true,
    });
    jobLog(lwiExit === 0 ? '[vs] .lwi index ready' : '[vs] WARNING: .lwi non-zero -- workers will retry');
  }

  // av1an args
  const av1anArgs = [
    '-i', vpyScript,
    '-o', outputPath,
    '--temp', av1anTemp,
    '-c', 'mkvmerge',
    '-e', encoder,
    '--sc-downscale-height', '540',
    '--scaler', 'lanczos',
    '--workers', String(maxWorkers),
    '--qp-range', qpRange,
    '--target-quality', String(targetVmaf),
    '--vmaf-path', vmafModel,
    '--vmaf-threads', '4',
    '--probes', '6',
    '--chunk-order', 'long-to-short',
    '--keep',
    '--resume',
    '--verbose',
  ];

  // VMAF resolution args
  if (downscaleEnabled) {
    av1anArgs.push(...buildAv1anVmafResArgs(downscaleRes));
  } else {
    av1anArgs.push('--probe-res', '1280x720', '--vmaf-res', '1280x720');
  }

  av1anArgs.push('-v', encFlags);

  // Install cancel handler
  let tracker;
  let sizeExceeded = false;

  pm.installCancelHandler(() => {
    if (tracker) tracker.stop();
  });

  // Start progress tracker
  updateWorker({ status: 'Scene Detection' });

  tracker = createAv1anTracker({
    workBase,
    maxWorkers,
    audioSizeGb,
    sourceSizeGb,
    maxEncodedPercent,
    updateWorker,
    jobLog,
    dbg,
    onSizeExceeded: () => {
      sizeExceeded = true;
      pm.killAll();
    },
  });
  tracker.start();

  // Spawn av1an
  const AV1AN_KEEP = /scene|chunk|encoded|vmaf|fps|eta|probe|error|warn|panic|crash/i;
  const av1anExit = await pm.spawnAsync(BIN.av1an, av1anArgs, {
    cwd: vsDir,
    filter: (l) => AV1AN_KEEP.test(l),
    onSpawn: (pid) => pm.startPpidWatcher(pid),
  });

  tracker.stop();

  // Evaluate result
  let encodeOk = false;
  if (sizeExceeded) {
    jobLog('[av1an] encode aborted: estimated output exceeds max-encoded-percent limit');
  } else if (av1anExit !== 0) {
    jobLog(`ERROR: av1an exited ${av1anExit}`);
  } else {
    encodeOk = true;
  }

  // Mux audio+subs if encode succeeded
  if (encodeOk) {
    if (!fs.existsSync(outputPath)) {
      jobLog(`ERROR: encoder output not found: ${outputPath}`);
      encodeOk = false;
    } else {
      const videoOnlyPath = outputPath + '.videoonly.mkv';
      fs.renameSync(outputPath, videoOnlyPath);
      updateWorker({ status: 'Muxing' });
      encodeOk = await mergeAudioVideo(videoOnlyPath, inputPath, outputPath, pm, jobLog, dbg);
      try { fs.unlinkSync(videoOnlyPath); } catch (_) {}
    }
  }

  // Cleanup
  pm.cleanup();

  // Output 2 — not processed
  if (sizeExceeded) {
    jobLog('='.repeat(64));
    jobLog('ENCODE SKIPPED -- output would exceed max-encoded-percent limit');
    jobLog('='.repeat(64));
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  // Error — throw for Tdarr error handle
  if (!encodeOk) {
    throw new Error('av1an encode failed -- check logs for details');
  }

  // Output 1 — success
  const inBytes = (() => { try { return fs.statSync(inputPath).size; } catch (_) { return 0; } })();
  const outBytes = (() => { try { return fs.statSync(outputPath).size; } catch (_) { return 0; } })();
  const pct = inBytes ? (((inBytes - outBytes) / inBytes) * 100).toFixed(1) : '?';

  jobLog('='.repeat(64));
  jobLog('ENCODE COMPLETE');
  jobLog(`  source  : ${humanSize(inBytes)}`);
  jobLog(`  output  : ${humanSize(outBytes)}  (${pct}% reduction)`);
  jobLog('='.repeat(64));

  updateWorker({ percentage: 100 });

  return {
    outputFileObj: Object.assign({}, file, { _id: outputPath, file: outputPath }),
    outputNumber: 1,
    variables: args.variables,
  };
};

module.exports.details = details;
module.exports.plugin = plugin;
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/index.js
git commit -m "feat: add av1anEncode FlowPlugin"
```

---

### Task 8: abAv1Encode plugin — index.js

**Files:**
- Create: `plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/index.js`

- [ ] **Step 1: Create abAv1Encode/1.0.0/index.js**

```js
// plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/index.js
'use strict';

const details = () => ({
  name: 'AV1 Encode (ab-av1)',
  description: [
    'Encodes video to AV1 using ab-av1 automatic VMAF-targeted CRF search.',
    'Uses SVT-AV1 with quality-optimized settings.',
    'Live progress, FPS, and ETA on dashboard. Cancel kills encoder immediately.',
  ].join(' '),
  style: { borderColor: 'purple' },
  tags: 'av1,ab-av1,svt-av1,vmaf',
  isStartPlugin: false,
  pType: '',
  requiresVersion: '2.00.01',
  sidebarPosition: -1,
  icon: 'faVideo',
  inputs: [
    {
      label: 'Target VMAF',
      name: 'target_vmaf',
      type: 'number',
      defaultValue: '93',
      inputUI: { type: 'text' },
      tooltip: 'VMAF score to target (0-100). Typically 90-96.',
    },
    {
      label: 'Min CRF',
      name: 'min_crf',
      type: 'number',
      defaultValue: '10',
      inputUI: { type: 'text' },
      tooltip: 'Minimum CRF bound for quality search.',
    },
    {
      label: 'Max CRF',
      name: 'max_crf',
      type: 'number',
      defaultValue: '50',
      inputUI: { type: 'text' },
      tooltip: 'Maximum CRF bound for quality search.',
    },
    {
      label: 'Preset',
      name: 'preset',
      type: 'number',
      defaultValue: '4',
      inputUI: { type: 'text' },
      tooltip: 'SVT-AV1 preset (0-13, lower=slower/better). Recommended: 4-6.',
    },
    {
      label: 'Max Encoded Percent',
      name: 'max_encoded_percent',
      type: 'number',
      defaultValue: '80',
      inputUI: { type: 'text' },
      tooltip: 'Abort if output exceeds this % of source size (uses ab-av1 native flag). Set to 100 to disable.',
    },
    {
      label: 'Enable Downscale',
      name: 'downscale_enabled',
      type: 'boolean',
      defaultValue: 'false',
      inputUI: { type: 'switch' },
      tooltip: 'Downscale output using ab-av1 native vfilter.',
    },
    {
      label: 'Downscale Resolution',
      name: 'downscale_resolution',
      type: 'string',
      defaultValue: '1080p',
      inputUI: { type: 'dropdown', options: ['720p', '1080p', '1440p'] },
      tooltip: 'Target resolution for downscaling. Only used when downscale is enabled.',
    },
  ],
  outputs: [
    { number: 1, tooltip: 'Encode succeeded -- output file is the encoded video+audio MKV' },
    { number: 2, tooltip: 'Not processed -- compression target not met, input file passed through unchanged' },
  ],
});

const plugin = async (args) => {
  const fs   = require('fs');
  const path = require('path');
  const os   = require('os');

  // Shared modules
  const sharedBase = path.join(__dirname, '..', '..', 'av1Shared', '1.0.0');
  const { createProcessManager } = require(path.join(sharedBase, 'processManager'));
  const { createLogger, humanSize } = require(path.join(sharedBase, 'logger'));
  const { detectHdrMeta, buildAbAv1SvtFlags } = require(path.join(sharedBase, 'encoderFlags'));
  const { buildAbAv1DownscaleArgs } = require(path.join(sharedBase, 'downscale'));
  const { createAbAv1Tracker } = require(path.join(sharedBase, 'progressTracker'));

  // Parse inputs
  const inputs = args.inputs || {};
  const targetVmaf        = Number(inputs.target_vmaf) || 93;
  const minCrf            = Number(inputs.min_crf) || 10;
  const maxCrf            = Number(inputs.max_crf) || 50;
  const encPreset         = Number(inputs.preset) || 4;
  const maxEncodedPercent = Number(inputs.max_encoded_percent) || 80;
  const downscaleEnabled  = inputs.downscale_enabled === true || inputs.downscale_enabled === 'true';
  const downscaleRes      = String(inputs.downscale_resolution || '1080p');

  // Binary paths
  const BIN_AB_AV1 = '/usr/local/bin/ab-av1';
  const vmafModel = '/usr/local/share/vmaf/vmaf_v0.6.1.json';

  if (!fs.existsSync(BIN_AB_AV1)) throw new Error(`Required binary not found: ${BIN_AB_AV1}`);
  if (!fs.existsSync(vmafModel)) throw new Error(`VMAF model not found: ${vmafModel}`);

  // Setup
  const { jobLog, dbg } = createLogger(args.jobLog, args.workDir);
  const pm = createProcessManager(jobLog, dbg);

  const updateWorker = (fields) => {
    if (typeof args.updateWorker === 'function') {
      try { args.updateWorker(fields); } catch (_) {}
    }
  };

  // Source file metadata
  const file = args.inputFileObj;
  const inputPath = file._id;
  const stream = (file.ffProbeData && file.ffProbeData.streams && file.ffProbeData.streams[0]) || {};
  const height = stream.height || 0;
  const availableThreads = os.cpus().length;

  // HDR metadata (for future use — ab-av1 passes through HDR natively via SVT flags)
  detectHdrMeta(stream);

  // ab-av1 lookahead calculation
  const srcFps = (() => {
    const r = stream.r_frame_rate || stream.avg_frame_rate || '24/1';
    const parts = r.split('/').map(Number);
    return parts[1] ? parts[0] / parts[1] : parts[0];
  })();
  const sampleFrames = Math.round(srcFps * 4); // 4-second samples
  const lookahead = Math.min(40, Math.max(8, Math.floor(sampleFrames * 0.25)));

  // Build SVT flags
  const svtFlags = buildAbAv1SvtFlags(availableThreads, lookahead);

  // Working directory
  const abWorkDir = path.join(args.workDir, 'ab-av1-work');
  const outputPath = path.join(args.workDir, 'ab-av1-output.mkv');
  fs.mkdirSync(abWorkDir, { recursive: true });

  // Log header
  const sourceSizeGb = (() => {
    try { return fs.statSync(inputPath).size / (1024 ** 3); } catch (_) { return 0; }
  })();

  jobLog('='.repeat(64));
  jobLog(`AB-AV1 ENCODE  preset=${encPreset}  vmaf=${targetVmaf}  crf=${minCrf}-${maxCrf}`);
  jobLog(`  input     : ${inputPath}`);
  jobLog(`  resolution: ${stream.width || '?'}x${height || '?'}${downscaleEnabled ? ` -> ${downscaleRes}` : ''}`);
  jobLog(`  max%      : ${maxEncodedPercent}`);
  jobLog(`  threads   : ${availableThreads}`);
  jobLog('='.repeat(64));

  updateWorker({ percentage: 0, startTime: Date.now(), status: 'CRF Search' });

  // ab-av1 args
  const abArgs = [
    'auto-encode',
    '--input', inputPath,
    '--output', outputPath,
    '--preset', String(encPreset),
    '--min-vmaf', String(targetVmaf),
    '--min-crf', String(minCrf),
    '--max-crf', String(maxCrf),
    '--vmaf', `n_threads=4:model=path=${vmafModel}`,
    '--max-encoded-percent', String(maxEncodedPercent),
    '--verbose',
  ];

  if (downscaleEnabled) {
    abArgs.push(...buildAbAv1DownscaleArgs(downscaleRes));
  }

  // Append SVT flags
  svtFlags.split(/\s+/).filter(Boolean).forEach((tok) => abArgs.push(tok));

  // Progress tracker
  let sizeExceeded = false;

  const tracker = createAbAv1Tracker({
    outputPath,
    sourceSizeGb,
    updateWorker,
    jobLog,
    dbg,
    onSizeExceeded: () => { sizeExceeded = true; },
  });

  pm.installCancelHandler(() => { tracker.stop(); });
  tracker.startInterval();

  // Spawn ab-av1
  const abExit = await pm.spawnAsync(BIN_AB_AV1, abArgs, {
    cwd: abWorkDir,
    onLine: tracker.onLine,
    filter: () => false, // suppress raw lines; tracker handles selective logging
    onSpawn: (pid) => pm.startPpidWatcher(pid),
  });

  tracker.stop();

  // Evaluate result
  let encodeOk = false;
  if (abExit !== 0) {
    if (sizeExceeded) {
      jobLog('[ab-av1] encode stopped: compression target not met');
    } else {
      jobLog(`ERROR: ab-av1 exited ${abExit}`);
    }
  } else {
    encodeOk = true;
  }

  // Cleanup
  pm.cleanup();

  // Output 2 — not processed
  if (sizeExceeded) {
    jobLog('='.repeat(64));
    jobLog('ENCODE SKIPPED -- output would exceed max-encoded-percent limit');
    jobLog('='.repeat(64));
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  // Error — throw for Tdarr error handle
  if (!encodeOk) {
    throw new Error('ab-av1 encode failed -- check logs for details');
  }

  // Validate output
  if (!fs.existsSync(outputPath) || fs.statSync(outputPath).size === 0) {
    throw new Error('ab-av1 output file missing or empty');
  }

  // Output 1 — success
  const inBytes = (() => { try { return fs.statSync(inputPath).size; } catch (_) { return 0; } })();
  const outBytes = (() => { try { return fs.statSync(outputPath).size; } catch (_) { return 0; } })();
  const pct = inBytes ? (((inBytes - outBytes) / inBytes) * 100).toFixed(1) : '?';

  jobLog('='.repeat(64));
  jobLog('ENCODE COMPLETE');
  jobLog(`  source  : ${humanSize(inBytes)}`);
  jobLog(`  output  : ${humanSize(outBytes)}  (${pct}% reduction)`);
  jobLog('='.repeat(64));

  updateWorker({ percentage: 100 });

  return {
    outputFileObj: Object.assign({}, file, { _id: outputPath, file: outputPath }),
    outputNumber: 1,
    variables: args.variables,
  };
};

module.exports.details = details;
module.exports.plugin = plugin;
```

- [ ] **Step 2: Commit**

```bash
git add plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/index.js
git commit -m "feat: add abAv1Encode FlowPlugin"
```

---

### Task 9: Dockerfile integration — COPY plugins into both images

**Files:**
- Modify: `Dockerfile` (tdarr and tdarr_node stages)

- [ ] **Step 1: Add COPY instructions for plugins**

In the `tdarr` stage (after the existing COPY and RUN lines), add:

```dockerfile
# FlowPlugins for av1an and ab-av1
COPY plugins/FlowPlugins/LocalFlowPlugins/ /app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/
```

In the `tdarr_node` stage (after the existing COPY and RUN lines), add:

```dockerfile
# FlowPlugins for av1an and ab-av1
COPY plugins/FlowPlugins/LocalFlowPlugins/ /app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile
git commit -m "feat: copy FlowPlugins into tdarr and tdarr_node Docker images"
```

---

### Task 10: Smoke test — verify plugin discovery

**Files:**
- Modify: `build.sh` or manual test

This task verifies the plugins are correctly placed and loadable inside the container.

- [ ] **Step 1: Build the stack-only target to verify COPY works**

Run: `./build.sh --stack-only`
Expected: Build succeeds. (Plugins are not in av1-stack, so this just confirms no build breakage.)

- [ ] **Step 2: Build the full images**

Run: `./build.sh`
Expected: Build succeeds for both tdarr and tdarr_node targets.

- [ ] **Step 3: Verify plugin files exist in tdarr image**

Run:
```bash
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr:latest -la /app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr:latest -la /app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr:latest -la /app/Tdarr_Server/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/
```
Expected: All files present (index.js for plugins, all .js files for shared).

- [ ] **Step 4: Verify plugin files exist in tdarr_node image**

Run:
```bash
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr_node:latest -la /app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/av1anEncode/1.0.0/
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr_node:latest -la /app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/abAv1Encode/1.0.0/
docker run --rm --entrypoint ls ghcr.io/empaa/tdarr_node:latest -la /app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins/av1Shared/1.0.0/
```
Expected: All files present.

- [ ] **Step 5: Verify require path resolves**

Run:
```bash
docker run --rm --entrypoint node ghcr.io/empaa/tdarr_node:latest -e "
  const path = require('path');
  const base = '/app/Tdarr_Node/assets/app/plugins/FlowPlugins/LocalFlowPlugins';
  const plugin = require(path.join(base, 'av1anEncode', '1.0.0', 'index.js'));
  console.log('av1anEncode details:', JSON.stringify(plugin.details().name));
  const plugin2 = require(path.join(base, 'abAv1Encode', '1.0.0', 'index.js'));
  console.log('abAv1Encode details:', JSON.stringify(plugin2.details().name));
"
```
Expected:
```
av1anEncode details: "AV1 Encode (av1an)"
abAv1Encode details: "AV1 Encode (ab-av1)"
```

- [ ] **Step 6: Commit any test infrastructure changes if needed**

```bash
git add -A && git status
# Only commit if there are changes
```
