# FlowPlugins Design: av1an & ab-av1 for Tdarr

## Overview

Two Tdarr FlowPlugins that expose the AV1 encoding stack (av1an and ab-av1) built into the Docker image. A shared utility library handles common concerns (process management, progress tracking, logging, audio merging, encoder flags, downscaling).

The plugins are baked into the Docker image — not volume-mounted — since av1an and ab-av1 only exist in this custom build.

## File Structure

```
plugins/FlowPlugins/LocalFlowPlugins/
  av1Shared/1.0.0/
    processManager.js
    progressTracker.js
    logger.js
    audioMerge.js
    encoderFlags.js
    downscale.js
  av1anEncode/1.0.0/
    index.js
  abAv1Encode/1.0.0/
    index.js
```

Source lives in the repo at `plugins/` and is COPYed into the Tdarr plugin path during Docker build. The shared module is imported via relative path from each plugin (`../../av1Shared/1.0.0/<module>`).

## Plugin Interfaces

### av1anEncode

| Parameter | Type | Default | Description |
|---|---|---|---|
| encoder | dropdown | `svt-av1` | `aom` (quality) or `svt-av1` (speed) |
| target_vmaf | number | `93` | VMAF target (0-100) |
| qp_range | string | `10-50` | QP floor-ceiling for target-quality search |
| preset | number | `4` | aomenc cpu-used (0-8) or SVT preset (0-13) |
| max_encoded_percent | number | `80` | Abort if estimated output > N% of source |
| downscale_enabled | boolean | `false` | Enable VapourSynth input downscale |
| downscale_resolution | dropdown | `1080p` | `720p` / `1080p` / `1440p` |

### abAv1Encode

| Parameter | Type | Default | Description |
|---|---|---|---|
| target_vmaf | number | `93` | VMAF target (0-100) |
| min_crf | number | `10` | Minimum CRF bound |
| max_crf | number | `50` | Maximum CRF bound |
| preset | number | `4` | SVT-AV1 preset (0-13) |
| max_encoded_percent | number | `80` | Abort if output > N% of source (native ab-av1 flag) |
| downscale_enabled | boolean | `false` | Enable native ab-av1 downscale |
| downscale_resolution | dropdown | `1080p` | `720p` / `1080p` / `1440p` |

### Outputs (both plugins)

- **Output 1:** File processed (encoded MKV with video + audio)
- **Output 2:** File not processed (compression target not met)
- **Error handle:** Plugin failure (crash, unexpected exit)

Two explicit outputs are declared. Errors trigger Tdarr's built-in error handle, not a third output.

## Shared Library Modules

### processManager.js

- `spawnEncoder(bin, args, env)` — spawns child process with `detached: true` (process group leader), tracks in active children list, returns child process handle
- `startPpidWatcher(encoderPid)` — spawns a detached bash script that polls `kill -0 workerPid` every 2 seconds; on parent death, sends SIGTERM then SIGKILL to encoder process group
- `killAll()` — sends SIGTERM to all active process groups via `kill(-pid)`, follows up with SIGKILL after 3 second timeout
- Signal handlers (SIGTERM/SIGINT/disconnect) as lightweight backup — call `killAll()` then exit

The PPID watchdog is the primary cleanup mechanism. It ensures encoder child processes are terminated when a Tdarr job is cancelled, since Tdarr does not send signals to the plugin process — it simply disconnects.

### progressTracker.js

Two tracker implementations:

**av1an tracker** — file-based polling every 5 seconds:
- Reads phase status from av1an's log directory (Indexing, Scene Detecting, Encoding, Muxing)
- Reads `scenes.json` for total frames/chunks and `done.json` for completed chunks
- Calculates FPS from per-worker log files using trimmed-mean + EWA smoothing (same algorithm as old plugin)
- **Output size:** encoded chunks directory size + probed audio size
- **Estimated final size:** trajectory extrapolation `(encoded size / progress%) + audio size`
- Early-exit check starts only after a delay (configurable, e.g. 10% progress) to allow estimation to stabilize

**ab-av1 tracker** — stdout line parsing:
- Parses `N% N fps` lines from ab-av1 stdout
- Tracks phases: CRF search, video encode, post-encode (audio/mux)
- **Output size:** reads actual output file size on disk
- **Estimated final size:** recalculated on each `N%` update as trajectory `(file size / progress%)`
- Compression limit detection: parses log output to distinguish "exceeded max-encoded-percent" (native ab-av1 flag) from actual errors

Both trackers push stats to Tdarr dashboard via `updateWorker()`: percentage, FPS, ETA, output size, estimated final size, status phase.

### logger.js

- `createLogger(jobLog, workDir)` — returns `{ log(line), debug(line), flush() }`
- `log()` — filtered output to Tdarr dashboard; only passes lines matching meaningful patterns (phase transitions, progress summaries, CRF results, errors, warnings)
- `debug()` — writes everything to `{workDir}/av1-debug.log`
- Debug log lives in workDir only (auto-cleaned by Tdarr after job completes)

### audioMerge.js

Used by av1anEncode only (ab-av1 handles muxing internally).

- `probeAudioSize(inputPath, workDir, env)` — extracts non-video tracks with `mkvmerge -D` to a temp file, returns size in GB. Called before encode starts so audio size can be added to all size estimates.
- `mergeAudioVideo(videoPath, inputPath, outputPath, env)` — muxes av1an's video-only output with original audio and subtitle tracks via mkvmerge

### encoderFlags.js

- `buildAomFlags(preset, hdrMeta)` — returns aomenc flag string: end-usage=q, tune=ssim, tile config, lag-in-frames, chroma deltaq, trellis quant, HDR CICP metadata passthrough
- `buildSvtFlags(preset, threads, hdrMeta)` — returns SVT-AV1 flag string: variance-boost, tf-strength, lookahead, keyint, thread pool (--lp), HDR CICP metadata passthrough
- `detectHdrMeta(streams)` — extracts color_primaries, color_transfer, color_space, chroma_location from input stream metadata; maps to encoder-specific flag values

HDR metadata handling and encoder parameters are carried over from the tested old plugin implementation.

### downscale.js

- `RESOLUTION_PRESETS` — `720p` -> `1280x720`, `1080p` -> `1920x1080`, `1440p` -> `2560x1440`
- `writeVapourSynthConfig(pluginDir)` — writes `vapoursynth.conf` with plugin directory paths for av1an's VapourSynth integration
- `buildVsFilterArgs(targetRes)` — returns av1an arguments for VapourSynth input downscale pre-filter
- `buildAbAv1DownscaleArgs(targetRes)` — returns ab-av1 native downscale arguments

## Orchestration Flows

### av1anEncode

1. Validate inputs, resolve binary paths
2. Detect HDR metadata from input streams
3. Build encoder flags (aom or svt-av1)
4. If downscale enabled: configure VapourSynth pre-filter
5. Probe audio size for size estimation
6. Create `workBase` subdirectory in `args.workDir`
7. Spawn av1an with `--log-dir` in workBase, all temp/chunk dirs in workBase
8. Start PPID watchdog
9. Start progress tracker — polls phases, progress, sizes every 5s
10. After progress stabilizes (~10%): begin early-exit checks against max_encoded_percent
11. On early-exit triggered: kill encoder, route to output 2
12. On encode success: merge audio/subs with mkvmerge
13. Validate output file exists and has size > 0
14. Route to output 1
15. On any failure: error handle

### abAv1Encode

1. Validate inputs, resolve binary paths
2. Detect HDR metadata from input streams
3. Build SVT-AV1 flags (hq tier settings)
4. If downscale enabled: add native downscale args
5. Spawn ab-av1 with `--max-encoded-percent` flag, working directory in `args.workDir`
6. Start PPID watchdog
7. Start progress tracker — parses stdout, reads output file size on each % update
8. On process exit: parse log to determine outcome
9. If compression limit exceeded (log indicates max% abort): route to output 2
10. Validate output file exists and has size > 0
11. Route to output 1
12. On any failure: error handle

### Key differences

- av1an requires post-encode mkvmerge step for audio/subs; ab-av1 does not
- av1an early-exit is plugin-managed (kill process); ab-av1 uses native `--max-encoded-percent` flag
- av1an progress from file polling; ab-av1 progress from stdout parsing
- av1an size estimation is smoother (continuous chunk completion); ab-av1 recalculates only on % updates

## Thread Budget

Conservative starting strategy — no oversubscription, tunable later:

- `availableThreads = os.cpus().length` (trust OS-reported count, includes hyperthreading)

**av1an + aom** (fewer workers, more threads each — aom scales well per-thread, high memory per worker):
- `threadsPerWorker = Math.max(4, Math.floor(availableThreads / 4))`
- `maxWorkers = Math.max(1, Math.floor(availableThreads / threadsPerWorker))`

**av1an + svt-av1** (more workers, fewer threads each — SVT has internal thread pool capped at --lp 6):
- `threadsPerWorker = Math.min(6, Math.max(4, Math.floor(availableThreads / 6)))`
- `maxWorkers = Math.max(1, Math.floor(availableThreads / threadsPerWorker))`

**ab-av1:** single process, SVT-AV1 manages its own threads internally.

**4K/HDR content:** halve `maxWorkers` to reduce memory pressure.

Thread budget is a starting point — to be tuned based on real-world testing.

## Error Handling

```
Encode process exits
  +-- exit code 0
  |     +-- output file exists and size > 0 --> Output 1 (processed)
  |     +-- output file missing/empty -------> Error handle
  +-- killed by early-exit check (av1an) ----> Output 2 (not processed)
  +-- ab-av1 log: compression limit exceeded -> Output 2 (not processed)
  +-- any other non-zero exit / crash -------> Error handle
```

For av1an: also verify mkvmerge step succeeded before declaring output 1.

Error handle behavior: flush debug log, log error summary to dashboard, let Tdarr's error handle take over.

## Dockerfile Integration

- Plugin source stored in repo at `plugins/FlowPlugins/LocalFlowPlugins/`
- COPY into Tdarr's plugin path in both `tdarr` and `tdarr_node` Docker stages
- Exact Tdarr plugin path to be confirmed from base image during implementation
