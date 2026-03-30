#!/usr/bin/env python3
"""Fix inverted VMAF model path logic in av1an-core/src/metrics/vmaf.rs.

Bug: when a model path ending in .json is provided, av1an uses the builtin
version= string instead of path=. The .json / non-.json branches are swapped
in both run_vmaf and run_vmaf_weighted.
"""
import sys
from pathlib import Path

target = Path("av1an-core/src/metrics/vmaf.rs")
src = target.read_text()

# ── Fix 1: run_vmaf ────────────────────────────────────────────────────────────
old_run_vmaf = r'''        let model_path = if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!("path={}", ffmpeg::escape_path_in_filter(&model)?)
        };'''

new_run_vmaf = r'''        let model_path = if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!("path={}", ffmpeg::escape_path_in_filter(&model)?)
        } else {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        };'''

if old_run_vmaf not in src:
    print("PATCH FAILED: run_vmaf model_path block not found in vmaf.rs", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_run_vmaf, new_run_vmaf, 1)
print("Patched: run_vmaf model_path logic")

# ── Fix 2: run_vmaf_weighted ───────────────────────────────────────────────────
old_weighted = r'''    let model_str = if let Some(model) = model {
        if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!(
                "path={}{}",
                ffmpeg::escape_path_in_filter(&model)?,
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        }'''

new_weighted = r'''    let model_str = if let Some(model) = model {
        if model.as_ref().as_os_str().to_string_lossy().ends_with(".json") {
            format!(
                "path={}{}",
                ffmpeg::escape_path_in_filter(&model)?,
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        } else {
            format!(
                "version={}{}",
                get_vmaf_model_version(probing_vmaf_features),
                if disable_motion {
                    "\\:motion.motion_force_zero=true"
                } else {
                    ""
                }
            )
        }'''

if old_weighted not in src:
    print("PATCH FAILED: run_vmaf_weighted model_str block not found in vmaf.rs", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_weighted, new_weighted, 1)
print("Patched: run_vmaf_weighted model_str logic")

target.write_text(src)
print("Done: vmaf.rs patched successfully.")
