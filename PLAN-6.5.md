# PLAN-6.5: Camoufox Screencast Data Plane (Before PLAN-7)

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers and performance agents

## 1. Executive Decision

Insert this plan between PLAN-6 and PLAN-7.

Single goal:

- move frame pixels off per-frame screenshot polling to Camoufox/Juggler screencast push.

This is the "6.5" bridge before canvas work in PLAN-7.

## 2. Scope (Pruned)

PLAN-6.5 focuses on item 2 only:

- stop relying on per-frame screenshot polling for pixel transport,
- keep existing control/input semantics,
- use Camoufox/Juggler screencast push with fallback to screenshot mode.

Scope gate (hard):

- Any new work not directly required for item 2 is out of scope for PLAN-6.5.
- If a behavior/tuning already exists in-tree, keep it as-is.
- Do not add new tuning tracks in PLAN-6.5 for scheduler/adaptive/hover/canvas/engine migration.

### 2.1 Item 2: "Stop using screenshot RPC for frame pixels" (primary focus)

This is feasible with Camoufox internals:

- Juggler protocol contains `Page.startScreencast`, `Page.stopScreencast`, `Page.screencastFrameAck`, and `Page.screencastFrame`.
- Camoufox Juggler target code uses `nsIScreencastService` for pushed frames.

But current Python Playwright client cannot call it directly:

- `BrowserContext.new_cdp_session()` is Chromium-only.
- direct channel call to `startScreencast` currently fails with unknown protocol scheme.

Therefore this plan requires a small Playwright driver protocol/dispatcher patch layer.

## 3. Non-Negotiable Constraints

- Camoufox remains the browser engine.
- No Camoufox source compilation.
- No Camoufox forking.
- Existing keyboard/mouse/navigation command semantics must remain unchanged.
- Existing screenshot path remains available as hard fallback.
- No user-visible breakage on stock Emacs.
- No requirement to land PLAN-7 first.
- Runtime-only tunables are acceptable as supporting tweaks, but they are not the primary mechanism of this plan.

## 4. Architecture Decision

Control/data split:

- control plane (unchanged): current JSON command path for input/navigation.
- data plane (new): pushed screencast frames from Camoufox via patched Playwright driver events.

Fallback:

- if screencast capability/protocol patch is absent or fails, daemon automatically reverts to `page.screenshot()` path.

## 5. Implementation Requirements

## 5.1 Playwright Driver Micro-Patch (required)

Patch local Playwright driver package used by `embr` to expose screencast to Python client.

Required protocol additions:

- page command to start screencast (embr-private name preferred),
- page command to stop screencast,
- page event carrying frame payload + dimensions + monotonic-ish timestamp.

Required server dispatcher behavior:

- bridge to existing internal `page.screencast.setOptions(...)` and stop path,
- forward `Page.Events.ScreencastFrame` to client event,
- keep behavior isolated (no impact unless enabled).

Required patching policy:

- version/checksum guard in setup flow,
- patch must fail closed (disable screencast mode, keep screenshot mode),
- clear log when patch is skipped due version drift.

## 5.2 Daemon (`embr.py`) Changes (required)

Add frame source selection:

- `frame_source=auto|screenshot|screencast`.

Mode rules:

- `auto`: try screencast probe first, fallback to screenshot.
- `screenshot`: current behavior exactly.
- `screencast`: require screencast; hard error if unavailable.

Screencast mode behavior:

- register event listener for pushed frames,
- keep queue depth at 1 (latest frame wins),
- emit same frame metadata contract to Emacs (`frame`, `frame_id`, `capture_done_mono_ms`, etc.),
- reuse existing scheduler/adaptive/hover behavior without expanding those systems in this plan.

Failure behavior:

- on repeated screencast errors/disconnects, auto-fallback to screenshot path in `auto`,
- in forced `screencast` mode, return explicit error and stop stream cleanly.

## 5.3 Emacs (`embr.el`) Changes (required)

Add user control:

- `embr-frame-source` with values `auto`, `screenshot`, `screencast`.

Init payload must include selected frame source.

No rendering-path rewrite is required in this plan:

- continue using current JPEG decode/display path in Emacs,
- PLAN-7 remains responsible for canvas rendering acceleration.

## 5.4 Setup and Tooling Changes (required)

`setup.sh` (or helper script) must:

- detect installed Playwright version in embr venv,
- apply/remove driver patch deterministically,
- report applied patch version in setup output.

Add one diagnostic command/log surface:

- print effective frame source (`screenshot` vs `screencast`) at startup.

## 6. Milestones

### M0: Feasibility Spike (must pass before full build)

Deliver:

- proof that patched driver can stream screencast frames to Python daemon,
- proof of clean start/stop lifecycle,
- proof of screenshot fallback on patch disable.

Exit gate:

- receives >= 300 frames in 30 seconds without daemon deadlock.

### M1: Daemon Integration

Deliver:

- `frame_source` negotiation and probe logic,
- screencast event ingestion + latest-frame queue,
- fallback automation.

### M2: Emacs Integration

Deliver:

- new defcustom and init wiring,
- user-visible status message of active source.

### M3: Validation and Rollout

Deliver:

- benchmark report vs screenshot baseline,
- stability report and rollback instructions,
- recommendation for default (`auto` or keep screenshot default).

## 7. Acceptance Criteria

## 7.1 Functional

- `auto` mode selects screencast when patch is present and healthy.
- hard fallback to screenshot works without restart in recoverable failures.
- no regressions in navigate/back/forward/click/type/scroll workflows.

## 7.2 Performance (vs screenshot baseline on same machine)

- `input_to_next_frame_ms p95` improves by >= 20% in video + interaction scenario.
- `command_ack_latency_ms p95` improves by >= 15% under frame churn.
- freeze events (>750ms no frame while active) are not worse than baseline.

## 7.3 Stability

- zero new daemon crash class in acceptance scenarios.
- no persistent frame stall after transient screencast failure.

## 8. Test Matrix

Each run: 10 minutes.

- `S1`: baseline browsing.
- `S2`: 1080p60 playback + mixed input.
- `S3`: heavy hover/click stress.
- `S4`: long-session endurance.

Run each with:

- screenshot mode,
- auto mode (with screencast patch enabled),
- forced screencast mode (when available).

## 9. Rollback Requirements

- user can set `embr-frame-source` to `screenshot` and recover instantly.
- disabling/removing driver patch must not break startup.
- logs must clearly state fallback reason.

## 10. Reviewer Rejection Criteria

Reject if any are true:

- screencast path requires leaving Camoufox,
- screencast path requires Camoufox compilation or forking,
- any substantial new work is introduced outside item 2 scope,
- no deterministic fallback to screenshot,
- setup patching is version-fragile without guard,
- no measured improvement on p95 responsiveness,
- protocol patch leaks into unrelated Playwright behavior.

## 11. Relationship to PLAN-7

PLAN-6.5 and PLAN-7 are complementary:

- PLAN-6.5 attacks capture-side bottleneck (how frame bytes are produced/delivered from browser stack).
- PLAN-7 attacks Emacs-side render/file-path overhead (how frame bytes are consumed).

Expected sequence:

1. land PLAN-6.5 for capture/data-plane relief,
2. then land PLAN-7 to reduce Emacs render overhead further.

## 12. Deliverables

- `PLAN-6.5` code changes in daemon + Emacs + setup tooling,
- Playwright driver micro-patch assets and version guard,
- perf report comparing screenshot vs screencast modes,
- README updates for new `embr-frame-source` knob and fallback behavior.

## 13. Definition of Done

PLAN-6.5 is complete when:

- Camoufox-based screencast data path works in `auto` mode,
- fallback to screenshot is reliable and documented,
- acceptance criteria in section 7 are evaluated and reported,
- docs and setup tooling are synchronized.

## 14. Source Evidence Used for This Plan

Camoufox/Juggler sources (local research copies):

- `additions/juggler/protocol/Protocol.js` (`startScreencast`, `screencastFrameAck`, `stopScreencast`, `screencastFrame` event)
- `additions/juggler/protocol/PageHandler.js` (method handlers)
- `additions/juggler/TargetRegistry.js` (`nsIScreencastService` start/ack flow)

Playwright runtime evidence (installed in embr venv):

- Firefox backend has internal screencast handling (`server/firefox/ffPage.js`, `server/screencast.js`)
- Client-facing protocol does not expose screencast commands/events by default (`driver/package/protocol.yml`)
- live probe result:
  - `new_cdp_session` on Firefox fails (Chromium-only),
  - direct channel `startScreencast` call fails with unknown protocol scheme.

## Implementation Policy Override (Execution Style)

This repository uses a continuous implementation style for performance work.

- Implement phases continuously; do not block on per-phase benchmarks or formal reports.
- Keep diagnostics and benchmark tooling in the codebase as optional tools.
- Any acceptance gate, report requirement, or intermediate target in this plan is non-blocking during implementation.
- Formal validation/testing for sign-off is performed once all phases in this plan are implemented.
- Plan completion does not require maintaining long-term report artifacts.
