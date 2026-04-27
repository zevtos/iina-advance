# Known limitations — HDR / DV pipeline (Phase 1)

This document tracks what is intentionally out of scope or deferred for the
first HDR / DV pass in this IINA-Advance fork. It complements the user-facing
README and is the reference for issues that look like bugs but are accepted
trade-offs.

Last updated: 2026-04-27 (Phase 1c/1d landing).

## What works in v1

- **Custom libmpv build.** `other/build_mpv.sh` produces
  `deps/lib/libmpv.2.dylib` with mpv PR #16818 ("vo_libmpv: introduce
  'gpu-next' render backend") cherry-picked, libplacebo statically linked
  with HDR / DV / HDR10+ / Dolby Vision RPU support, and all transitive
  Homebrew dependencies bundled at `@rpath/`.
- **Opt-in `gpu-next` render backend.** Pref `useGpuNextBackend` switches
  mpv from the default OpenGL renderer to libplacebo's gpu-next via
  `MPV_RENDER_PARAM_BACKEND="gpu-next"` at render-context create time.
  When enabled, libplacebo handles HDR10 / HLG / Dolby Vision RPU reshape
  internally and writes back into the same OpenGL FBO that
  `GLVideoLayer` already provides.
- **HDR10 baseline rendering.** Existing IINA-Advance EDR path
  (`VideoView_HDR.swift`, formerly inline in `VideoView.swift`) continues
  to work, now also with gpu-next when the pref is on.
- **Subtitles at paper-white luminance on EDR.** `--blend-subtitles=video`
  is applied whenever the EDR path is taken, so libass output is composited
  into the video frame before tone-mapping and lands at SDR ref white
  (~203 nits) instead of full display peak (~1500 nits on XDR).
- **AppKit overlay colorspace.** `ViewportView`'s layer is tagged
  `extendedSRGB` so macOS WindowServer composites OSC / OSD / sidebars as
  SDR over EDR video without overlay UI looking washed out or glowing.
- **Battery / thermal saver mode.** `PerfManager` observes
  `IOPSGetProvidingPowerSourceType` and `NSProcessInfo.thermalState`,
  classifies into `full / batterySaver / thermalWarn / emergency`, and
  on profile change it clears `glsl-shaders` for every active player core.
  Pref `batteryMode` overrides (`auto / alwaysFull / alwaysSaver`).
  `.iinaPerfProfileChanged` notification is posted for future OSC
  consumers.

## Deferred to v1.x

These items have a clear path forward but are not in the v1 release.
The escape hatch defined at the start of Phase 1 explicitly allowed
descoping them in favor of the release blockers (subs / OSD / battery).

### DV Profile 7 FEL → 8.1 conversion via ffmpeg `dovi_processing` BSF
- ffmpeg ≥ 7.0 ships a `dovi_processing` bitstream filter that converts
  Profile 7 FEL streams to Profile 8.1, after which libplacebo's RPU
  reshape works natively.
- Wiring: an `--vd-lavc-bsfs="dovi_processing=mode=2"`-style mpv option
  set from `MPV_Init.swift`, gated on a new pref so users can opt out.
- Today: P7 streams play as their HDR10 base layer only (acceptable but
  loses per-shot reshape information).

### HDR10+ ST.2094-40 dynamic tone-mapping observation
- libplacebo handles per-scene metadata internally once gpu-next is in
  the chain; the deferred work is wiring an mpv property observer for
  `hdr-metadata` so IINA can show a "HDR10+" badge in the OSC and log
  scene-by-scene transitions for diagnostics.
- Today: HDR10+ content plays correctly via gpu-next libplacebo, but
  IINA itself doesn't surface the "HDR10+" detection.

### SDR-on-EDR-display transition handling
- When a playlist mixes SDR and HDR clips on an EDR-capable display,
  the layer toggles `wantsExtendedDynamicRangeContent` between clips
  and produces a brief (one-frame) gamut flash at the transition.
- Wanted behavior: keep the EDR layer on for SDR clips and instruct
  mpv to render SDR at `target-peak=203` (paper-white reference).
- Wiring is small; deferred only for scoping reasons.

### Save / restore of user GLSL shader chain across battery transitions
- `PerfManager` clears `glsl-shaders` on entering `batterySaver+`. A
  transition back to `full` does *not* re-apply the user's chain — the
  player keeps playing without shaders until next mpv core init.
- A clean fix needs ShaderManager (Phase 2 of the broader fork plan)
  to own the user's chain and re-apply it on profile change.
- Workaround today: toggle the pref or restart playback to re-load
  shaders from `mpv.conf`.

### RIFE / heavy vapoursynth filter throttling
- `PerfManager` only handles `glsl-shaders` today. RIFE-style frame
  interpolation typically lives as a vapoursynth `vf` filter and is
  unaffected by the current battery throttle.
- Needs a generic VFManager that knows which filters are "heavy" so
  PerfManager can drop them temporarily.

### OSC indicators (HDR mode badge, battery / thermal badge)
- `PerfManager.Profile.oscBadge` defines the symbols; `VideoView_HDR`
  already classifies HDR/SDR/HLG. The deferred work is the OSC view
  edits to surface these in the player UI.
- `.iinaPerfProfileChanged` is already posted to make subscription
  trivial when this lands.

### Native Metal render layer
- The simplified Phase 1 plan keeps `CAOpenGLLayer` (`GLVideoLayer`)
  as the only rendering path. This works because mpv PR #16818's
  gpu-next backend currently only exposes a *single* context backend
  (`libmpv_gpu_next_context_gl`) — there is no Metal context yet,
  upstream or in the PR.
- A future v2 effort would either:
  1. write `libmpv_gpu_next_context_metal.c` upstream and contribute it
     to mpv, then wire a `CAMetalLayer` here, or
  2. keep OpenGL on macOS until upstream ships Metal support.
- Apple's OpenGL is "deprecated" but still supported through at least
  macOS 26; this is not an immediate blocker.

### XCTest coverage for HDR mode classification
- The Phase 1 architecture called for `HDRModeTests.swift` with
  synthetic mpv property maps. The fork doesn't currently configure a
  test target alongside the iina target, and adding one needs schema /
  scheme work that is out of scope.

## Hardware limits (not fixable in software)

- **Dolby Vision Profile 7 MEL** is treated identically to Profile 8.1
  by the dovi BSF path; the perceptual difference is small.
- **HDR over external DisplayPort** to non-XDR panels: works but quality
  varies by panel. We don't make per-panel guarantees.
- **HDR mode change flicker**: macOS' compositor can't sub-frame
  reconfigure layer EDR state, so a one-frame black or wrong-gamut
  transition is unavoidable without the SDR-on-EDR fix above.

## Where to read more

- `other/build_mpv.sh` — the exact mpv / libplacebo / libdovi pin and
  the meson invocation.
- `iina/PerfManager.swift` — power / thermal observation and profile
  classification.
- `iina/VideoView_HDR.swift` — EDR detection and tone-mapping setup.
- `iina/GLVideoLayer.swift` — render-context creation including the
  optional `MPV_RENDER_PARAM_BACKEND` param.
