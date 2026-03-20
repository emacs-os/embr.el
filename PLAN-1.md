# embr Responsiveness Plan and Implementation Spec

Document status: Draft for implementation handoff
Last updated: 2026-03-20
Owner: Core maintainers
Primary audience: coding agents implementing performance and responsiveness improvements

## 1. Problem Statement

`embr` is now usable under high-load scenarios (including 60 FPS video), but interaction still feels less responsive than native Firefox. The dominant pain points are:

- perceptible latency between user input and visible reaction,
- occasional micro-stalls under simultaneous screenshot + input load,
- reduced confidence in mouse responsiveness during video playback,
- uneven behavior depending on hover/click/scroll mix.

The core architectural reality is unchanged: Emacs and Python share a narrow control/data channel through Playwright/CDP and screenshot transport. This plan defines an input-first scheduling strategy with measurable acceptance requirements.

## 2. Product Goal

Make `embr` feel reliably responsive during interactive browsing, with video playback still smooth enough for practical use.

Priority order:

1. Input responsiveness and predictability.
2. Frame freshness (avoid stale visuals).
3. Visual smoothness/FPS.

## 3. Non-Goals

- Perfect parity with native Firefox compositor behavior.
- Replacing Playwright/Camoufox.
- Building a full automated integration test framework for Emacs UI in this phase.
- Eliminating all packet/pipe contention in every edge case.

## 4. Scope

In scope:

- daemon scheduling and load-shedding behavior,
- adaptive capture policy,
- hover pressure reduction,
- performance instrumentation and reporting,
- user-facing tuning knobs (defcustom + protocol + docs),
- acceptance procedure and pass/fail gates.

Out of scope:

- broad feature work unrelated to responsiveness,
- unrelated keybinding or UI changes,
- protocol redesign beyond what is needed for these goals.

## 5. Key Terms and Metrics

All metrics use monotonic timestamps.

- `command_ack_latency_ms`: Time from command receive in daemon to `{ok:true}` response emit for that command.
- `input_to_next_frame_ms`: Time from daemon receive of an interactive input command (`mousemove`, `click`, `mousedown`, `mouseup`, `key`, `type`, `scroll`) to next emitted frame notification.
- `frame_interval_ms`: Time between consecutive emitted frame notifications.
- `frame_staleness_ms`: Age of frame at the time Emacs renders it (`render_time - capture_done_time`).
- `freeze_event`: Any interval where no frame is emitted for more than `freeze_threshold_ms` while browsing is active.
- `dropped_frame_ratio`: Dropped captures or skipped renders divided by capture opportunities.

Metric quantiles required in reports: `p50`, `p95`, `p99`, plus max.

## 6. Measurable Requirements (Acceptance SLOs)

All MUST items are mandatory for acceptance.

### 6.1 MUST: Stability and Safety

- No daemon crash, deadlock, or unrecoverable error during all acceptance scenarios.
- Zero command-loop timeout errors attributable to scheduler logic.
- Zero regressions in existing commands and key behaviors.

### 6.2 MUST: Input Responsiveness

Under `Scenario B` and `Scenario C` (defined in section 10):

- `command_ack_latency_ms` for interactive input:
  - `p95 <= 30 ms`
  - `p99 <= 70 ms`
  - `max <= 150 ms` (excluding explicit navigation operations)
- `input_to_next_frame_ms`:
  - `p95 <= 120 ms`
  - `p99 <= 220 ms`

### 6.3 MUST: Freeze Budget

- `freeze_threshold_ms = 750`.
- Zero freeze events longer than `1500 ms`.
- At most `1` freeze event per 10-minute stress run above `750 ms` and below `1500 ms`.

### 6.4 MUST: Frame Freshness

Under interactive load (`Scenario B/C`):

- `frame_staleness_ms p95 <= 180 ms`.
- `frame_staleness_ms p99 <= 300 ms`.

### 6.5 MUST: Throughput Floor

Under interactive load:

- Effective rendered FPS average `>= 18`.

Under watch/idle load (minimal input):

- Effective rendered FPS average `>= 40` when configured target is 60.

### 6.6 MUST: Backward Compatibility

- Existing defaults must keep current workflows functional.
- If new defcustom variables are added, defaults must preserve sane behavior without user changes.
- Protocol changes must be implemented in both `embr.py` and `embr.el`.
- README configuration tables and both `use-package` blocks must be synchronized.

### 6.7 SHOULD: UX Quality Targets

- Interaction should subjectively feel "immediate" for keypress and click in normal browsing.
- Pointer hover should remain useful, but may be degraded under heavy load.
- Visual jitter should not exceed current baseline.

## 7. Design Requirements

### 7.1 MUST: Input-First Scheduling

Implement scheduler semantics where interactive input preempts non-critical frame capture.

Required behavior:

- On interactive input receive, enter temporary `input-priority` window (`input_priority_window_ms`).
- During this window, screenshot capture is suppressed or rate-limited.
- Stale pending frames are dropped rather than rendered late.
- Scheduler must never block command processing.

### 7.2 MUST: Adaptive Capture Controller

Adaptive policy must tune capture pressure at runtime.

Required behavior:

- Dynamically lower capture load when budget overrun is detected (e.g., long capture duration, growing frame age, elevated input pressure).
- Recover gradually when system is stable (hysteresis required; no oscillation thrash).
- Bound adaptation by configured min/max limits.

### 7.3 MUST: Hover Load Shedding

Hover traffic is lowest priority input class.

Required behavior:

- Coalesce mousemove aggressively.
- Do not enqueue redundant hover updates when position movement is below threshold.
- Allow reduced hover send rate under load.

### 7.4 SHOULD: Interaction and Watch Modes

Provide explicit or implicit mode behavior:

- interactive mode: low latency bias,
- watch mode: higher FPS bias when idle.

This can be automatic (activity-based) or user-configurable presets.

## 8. Configuration Requirements

If introduced, config knobs must be exposed as Emacs defcustoms and passed through protocol.

Suggested required knobs:

- `embr-input-priority-window-ms` (default: `125`)
- `embr-max-frame-age-ms` (default: `180`)
- `embr-adaptive-capture` (default: `t`)
- `embr-adaptive-fps-min` (default: `12`)
- `embr-adaptive-fps-max` (default: existing `embr-fps`)
- `embr-adaptive-jpeg-quality-min` (default: `45`)
- `embr-hover-move-threshold-px` (default: `2`)
- `embr-hover-rate-min` (default: `2`)

If different names are selected, they must still cover equivalent control surfaces and be documented.

## 9. Instrumentation and Observability Requirements

### 9.1 MUST: Built-in Perf Logging

Implement structured JSONL perf logging in daemon (and Emacs where needed) behind a config flag.

Required event schema fields:

- `ts_ms` (monotonic)
- `event`
- `cmd` (when relevant)
- `cmd_id` (when relevant)
- `mode` (`interactive` or `watch` when relevant)
- `fps_target`, `fps_effective` snapshot fields when relevant
- `jpeg_quality` snapshot when relevant

Required event types:

- command lifecycle: receive/ack
- frame lifecycle: capture_start/capture_done/frame_emit/frame_drop
- scheduler transitions: mode change, input-priority window start/end
- adaptation events: step down/up with reason

### 9.2 MUST: Report Generator

Provide a repeatable report command or script that ingests perf logs and outputs:

- summary table with p50/p95/p99/max for required metrics,
- freeze event counts and durations,
- effective fps distribution,
- adaptation step counts.

Output can be markdown or plain text, but must be deterministic and easy to diff.

## 10. Acceptance Test Protocol

Use same machine/session for baseline and candidate run. Log machine details in report.

### 10.1 Test Environment Capture

Record:

- CPU model
- core/thread count
- RAM
- OS + kernel
- Emacs version
- Python version
- Camoufox/Playwright versions
- target monitor refresh rate if relevant

### 10.2 Scenarios

Each scenario runs for `10 minutes`.

- `Scenario A (Baseline browsing)`: static news/documentation pages, typical typing/navigation, no video.
- `Scenario B (Video + mixed input)`: 1080p60 video playback, continuous mixed interactions (scroll, clicks, occasional hover movement).
- `Scenario C (Stress hover/click)`: video or animation-heavy page while doing frequent mouse moves + click/drag interactions.
- `Scenario D (Keyboard dominant)`: navigation and search using keyboard only, minimal mouse movement.

### 10.3 Input Pattern Requirements

For `Scenario B/C`, include:

- at least 300 key events,
- at least 200 scroll events,
- at least 100 click events,
- at least 60 seconds cumulative pointer movement.

### 10.4 Pass/Fail Rules

Build is accepted only if all MUST requirements in section 6 are satisfied across scenarios B and C, and no regressions in scenario A/D.

## 11. Implementation Work Breakdown (for Coding Agents)

### Phase 1: Instrumentation First (Mandatory)

Deliverables:

- Perf event logging capability with low overhead toggle.
- Command/frame event IDs and timestamps.
- Baseline report from current branch before behavior change.

Acceptance gate:

- Event logs generated without crashes.
- Report includes all required metric families.

### Phase 2: Input-Priority Scheduler (Mandatory)

Deliverables:

- Input-priority window logic.
- Frame suppression/drop policy while interactive input active.
- Command loop non-blocking guarantee retained.

Acceptance gate:

- Meets responsiveness/freeze SLOs or demonstrates measurable improvement toward them.

### Phase 3: Adaptive Controller (Mandatory)

Deliverables:

- Runtime adaptation of FPS and/or JPEG quality.
- Hysteresis to avoid oscillation.
- Telemetry for adaptation decisions.

Acceptance gate:

- Outperforms fixed policy in Scenario B/C on p95 latency without violating FPS floor.

### Phase 4: Hover Load Management (Mandatory)

Deliverables:

- Movement threshold filtering.
- Dynamic hover rate cap under pressure.

Acceptance gate:

- No degradation in click reliability; lower hover-induced latency spikes.

### Phase 5: Documentation and Defaults (Mandatory)

Deliverables:

- README updates (`use-package` blocks, config table, key behavior notes if changed).
- Migration notes for new variables.

Acceptance gate:

- README and code defaults fully consistent.

## 12. File-Level Expectations

Expected files touched by implementation:

- `embr.py`: scheduler, adaptation, telemetry.
- `embr.el`: new defcustoms, protocol fields, optional perf toggles.
- `README.md`: config/keybinding/behavior updates.
- Optional helper script for report generation (if added, place under repo root or `tools/`).

## 13. Regression Checklist

Must validate manually before merge:

- startup, setup, and uninstall flows unaffected,
- navigate/back/forward/refresh unchanged,
- click and drag still work,
- keyboard forwarding unchanged,
- tabs/list/switch unaffected,
- hints/fill/text extraction unaffected,
- copy/paste bridge unaffected,
- no runaway CPU from timers/tasks,
- daemon exits cleanly.

## 14. Code Quality and Review Requirements

Reviewers must reject implementation if:

- behavior changes are unmeasured,
- thresholds are claimed without logs/reports,
- adaptation logic has no hysteresis,
- scheduler blocks command loop,
- docs are out of sync with defcustoms/protocol,
- broad refactors introduce unrelated risk.

Reviewers should request follow-up if:

- SLOs are barely met with fragile tuning,
- improvements rely on machine-specific assumptions,
- logs are too noisy for routine use.

## 15. Risk Register and Mitigations

Risk: Over-aggressive frame suppression makes UI feel frozen.
Mitigation: enforce frame throughput floor and max suppression window.

Risk: Adaptive controller oscillation.
Mitigation: use bounded step sizes + cooldown intervals + hysteresis bands.

Risk: Hover degradation harms usability.
Mitigation: preserve minimum hover responsiveness and expose configurable thresholds.

Risk: Logging overhead distorts results.
Mitigation: make logging optional and benchmark with/without logging enabled.

Risk: Hidden regressions in non-performance features.
Mitigation: run regression checklist in section 13 every pass.

## 16. Delivery Artifacts Required from Coding Agents

Each implementation PR/change set must include:

- concise architecture note of scheduler/adaptation approach,
- baseline vs candidate perf report for scenarios A-D,
- explicit statement of which SLOs passed/failed,
- list of new config variables and defaults,
- README sync confirmation.

## 17. Definition of Done

This plan is complete when an implementation:

- satisfies all MUST acceptance requirements,
- ships with reproducible metrics and reporting,
- preserves existing core features,
- keeps documentation fully synchronized,
- demonstrates materially improved input responsiveness under 60 FPS video stress.

## 18. Optional Future Work (Post-Acceptance)

- differential/region-based updates instead of full-frame JPEG each cycle,
- smarter render invalidation from DOM/page activity,
- dedicated performance benchmark harness automation,
- transport redesign beyond CDP screenshot-heavy path.


## Implementation Policy Override (Execution Style)

This repository uses a continuous implementation style for performance work.

- Implement phases continuously; do not block on per-phase benchmarks or formal reports.
- Keep diagnostics and benchmark tooling in the codebase as optional tools.
- Any acceptance gate, report requirement, or intermediate target in this plan is non-blocking during implementation.
- Formal validation/testing for sign-off is performed once all phases in this plan are implemented.
- Plan completion does not require maintaining long-term report artifacts.
