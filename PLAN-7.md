# PLAN-7: Canvas-Aware Dual Rendering Pipeline

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers and performance agents

## 1. Executive Summary

`PLAN-7` adds a dual rendering path:

- Path A: current JPEG/file path (works everywhere).
- Path B: canvas-accelerated path (used when Canvas patch support is detected).

Goal:

- preserve universal compatibility,
- automatically use a faster display path when available,
- avoid any requirement that users patch Emacs just to run `embr`.

## 2. Research Findings (Input to Design)

The `emacs-canvas-patch` and `doom-on-emacs` materials indicate:

- Canvas is introduced as an image type (`:type canvas`) with `:canvas-id`, `:canvas-width`, `:canvas-height`.
- Native module API additions include `canvas_pixel` and `canvas_refresh`.
- The patch is not upstream in stock Emacs and requires applying patch + recompiling Emacs.
- Doom demo uses `image-type-available-p 'canvas` for availability checks and module C glue to write pixels and refresh.

Implication:

- We must feature-detect at runtime and support fallback by default.

## 3. Product Requirements

## 3.1 MUST: Dual Support

`embr` must support both:

- standard Emacs (no canvas patch),
- canvas-patched Emacs.

## 3.2 MUST: Automatic Capability Detection

At startup, `embr` must detect canvas capability and choose backend.

## 3.3 MUST: Better Pipe When Available

If canvas path is available, frame transport must avoid disk JPEG file roundtrip and use a lower-overhead pipeline.

## 3.4 MUST: Safe Fallback

If detection fails or canvas path errors at runtime, `embr` must degrade to legacy path without crashing the session.

## 4. Compatibility Matrix

Supported runtime states:

1. `stock-emacs`:
   - backend = `legacy-jpeg-file`
   - behavior = current.

2. `patched-emacs + no module`:
   - backend = `legacy-jpeg-file`
   - behavior = current with warning.

3. `patched-emacs + canvas module`:
   - backend = `canvas-stream`
   - behavior = accelerated path enabled.

4. `patched-emacs + module load failure`:
   - backend = fallback `legacy-jpeg-file`
   - behavior = recover and continue.

## 5. Runtime Detection Specification

Detection should be explicit and layered.

## 5.1 Layer 1: Elisp Capability Check

- `(image-type-available-p 'canvas)` must return non-nil.

## 5.2 Layer 2: Module Availability Check

- load `embr-canvas` module from `libexec`.
- call module function `embr_canvas_supported_p`.
- module should verify env function pointers for canvas API.

## 5.3 Layer 3: Smoke Render Check

- create tiny canvas image spec (for example 4x4),
- perform one pixel write + refresh through module,
- verify no error.

Only if all three pass, choose `canvas-stream` backend.

## 6. Rendering Backend Abstraction

Introduce a rendering backend interface in `embr.el`:

- `embr--backend-init`
- `embr--backend-on-frame`
- `embr--backend-shutdown`
- `embr--backend-name`

Required backends:

- `legacy-jpeg-file` (existing behavior),
- `canvas-stream` (new behavior).

## 7. Canvas-Stream Pipeline Design

## 7.1 Control/Data Split

Keep JSON control protocol for commands/responses.

Add dedicated frame data channel for canvas backend.

Recommended v1 transport:

- UNIX domain socket for frame payloads,
- length-prefixed frame packets with monotonic sequence IDs.

## 7.2 Packet Format (v1)

Per frame packet:

- `uint32 seq`
- `uint32 width`
- `uint32 height`
- `uint32 jpeg_len`
- `jpeg_bytes[jpeg_len]`

(Initial v1 keeps JPEG capture in daemon to minimize browser-side changes.)

## 7.3 Emacs Module Role

`embr-canvas` module responsibilities:

- decode incoming JPEG payload in C (prefer libjpeg-turbo if available),
- write decoded RGBA/BGRA pixels into `canvas_pixel` buffer,
- call `canvas_refresh`.

This replaces Elisp file read + `create-image` per frame for canvas path.

## 7.4 Sequence and Stale-Frame Policy

- maintain latest `seq` rendered,
- drop out-of-order or stale packets,
- prefer newest frame under pressure.

## 8. Daemon Changes (`embr.py`)

## 8.1 Init Contract

Add optional init fields:

- `render_backend` (`legacy-jpeg-file` or `canvas-stream`)
- `frame_socket_path` (when canvas-stream)

## 8.2 Legacy Path

No behavior regression.

## 8.3 Canvas Path

- continue screenshot capture loop,
- send JPEG bytes to frame socket using packet format,
- emit lightweight JSON metadata as needed (title/url/frame seq).

## 9. Emacs Lisp Changes (`embr.el`)

Required additions:

- backend detection and selection logic,
- canvas image spec management (`:type canvas` with stable `:canvas-id`),
- frame socket reader/process integration,
- backend metrics counters and debug command.

`embr.el` must expose a user override:

- `embr-render-backend-preference`: `auto`, `legacy`, `canvas`

Behavior:

- `auto` tries canvas then falls back.
- `legacy` bypasses detection.
- `canvas` attempts canvas and errors clearly if unavailable.

## 10. Native Module Requirements (`libexec`)

Create module implementation in `libexec`.

Required files:

- `libexec/embr-canvas.c`
- `libexec/Makefile` updates for module target

Required exported module functions:

- `embr_canvas_supported_p`
- `embr_canvas_blit_jpeg`
- `embr_canvas_version`

`embr_canvas_blit_jpeg` contract:

- args: `(canvas-spec-or-object, bytes, width, height, seq)` or equivalent
- effect: decode + copy + refresh
- return: success flag / error code

## 11. Safety and Fallback Requirements

MUST:

- fallback to legacy on module load failure,
- fallback to legacy on repeated decode/render errors,
- never hard-crash Emacs due canvas path failure.

SHOULD:

- include rate-limited warning logs,
- include command to force backend switch during session for debugging.

## 12. Performance Requirements

Compare canvas backend against legacy on same machine.

### 12.1 MUST: Latency and Throughput

- frame render path CPU in Emacs process improves by >= 20% in video scenario,
- `input_to_next_visible_ms p95` improves by >= 10%,
- rendered FPS in stress scenario improves by >= 15%.

### 12.2 MUST: Stability

- no increase in crash/fatal error class,
- no sustained freeze regression vs legacy.

### 12.3 SHOULD: Tail Improvement

- `input_to_next_visible_ms p99` improves by >= 10%,
- dropped stale frame ratio decreases under burst load.

## 13. Test Plan

## 13.1 Matrix

- `T1`: stock Emacs -> legacy path
- `T2`: patched Emacs without module -> legacy fallback
- `T3`: patched Emacs with module -> canvas path
- `T4`: forced runtime failure in canvas path -> fallback works

## 13.2 Scenarios

Each scenario 10 minutes:

- normal browsing,
- video + mixed interaction,
- tab churn and navigation bursts,
- long session endurance.

## 13.3 Validation Outputs

- backend selection log,
- capability check report,
- latency/FPS comparison table,
- fallback incident report.

## 14. Milestones

### M0: Capability Detection and Backend Abstraction

Deliver:

- backend interface,
- detection logic,
- no-regression legacy path.

### M1: Frame Socket and Protocol

Deliver:

- daemon frame socket writer,
- Emacs socket reader integration,
- packet sequencing.

### M2: Canvas Module v1

Deliver:

- module build + load,
- JPEG decode + canvas refresh path,
- error handling and diagnostics.

### M3: Full Integration and Fallback

Deliver:

- auto selection,
- runtime fallback,
- user backend override.

### M4: Perf Validation and Docs

Deliver:

- benchmark report,
- README/backend docs,
- rollout recommendation.

## 15. Reviewer Rejection Criteria

Reject if:

- canvas path is not optional/fallback-safe,
- stock Emacs behavior regresses,
- backend detection is unreliable/ambiguous,
- no measurable perf evidence,
- docs do not explain capability and fallback behavior.

## 16. Definition of Done

PLAN-7 is complete when:

- dual backend support is implemented,
- automatic canvas detection works reliably,
- canvas path is functional on patched Emacs with module,
- fallback to legacy is robust,
- performance improvements meet section 12 thresholds,
- documentation is complete.

## 17. Source References

- Canvas patch repository:
  - https://github.com/minad/emacs-canvas-patch
- Canvas patch README:
  - https://raw.githubusercontent.com/minad/emacs-canvas-patch/main/README.org
- Canvas demo Elisp:
  - https://raw.githubusercontent.com/minad/emacs-canvas-patch/main/canvas-demo.el
- Canvas patch diff:
  - https://raw.githubusercontent.com/minad/emacs-canvas-patch/main/canvas.diff
- Doom on Emacs (Canvas usage example):
  - https://github.com/minad/doom-on-emacs
  - https://raw.githubusercontent.com/minad/doom-on-emacs/master/README.org
- Upstream discussion:
  - https://debbugs.gnu.org/cgi/bugreport.cgi?bug=80281


## Implementation Policy Override (Execution Style)

This repository uses a continuous implementation style for performance work.

- Implement phases continuously; do not block on per-phase benchmarks or formal reports.
- Keep diagnostics and benchmark tooling in the codebase as optional tools.
- Any acceptance gate, report requirement, or intermediate target in this plan is non-blocking during implementation.
- Formal validation/testing for sign-off is performed once all phases in this plan are implemented.
- Plan completion does not require maintaining long-term report artifacts.
