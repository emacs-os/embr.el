# PLAN-3: Post-Booster Rendering and Transport Overhaul

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers and performance agents

## 1. Program Intent

`PLAN-2` commits to a full booster program. `PLAN-3` is the next stage: reduce or eliminate the architectural ceilings caused by full-frame screenshot transport and repeated decode/redraw work.

This plan assumes booster work exists and uses it as the control-plane foundation.

## 2. Product Outcome

Make `embr` feel near-native for interactive browsing while maintaining acceptable video usability.

Priority order:

1. Input-to-visible-response latency.
2. Frame freshness.
3. Visual smoothness.
4. CPU and power efficiency.

## 3. Core Hypothesis

Past improvements mainly optimize scheduling around the existing full-frame path. The next large gains require reducing data volume and decode churn.

Biggest leverage points:

- fewer full-frame captures,
- smaller frame payloads,
- decoupled control and frame transport,
- lower Emacs-side redraw cost.

## 4. Scope

In scope:

- capture policy redesign,
- partial update pipeline,
- binary frame transport,
- shared memory transport (Linux-first),
- Emacs render-path optimization,
- benchmark/replay harness for repeatable evaluation.

Out of scope:

- replacing Emacs as UI host,
- replacing Camoufox in this plan,
- browser feature expansion unrelated to responsiveness.

## 5. Non-Goals

- perfect parity with native Firefox compositor,
- support for every OS in first pass of new transport,
- broad UX redesign.

## 6. Architecture Tracks

`PLAN-3` is a multi-track program. All tracks are mandatory unless superseded by an approved architecture decision record (ADR).

### 6.1 Track A: Activity-Driven Capture Policy

Goal:

- Capture only when likely to improve visible output.

Requirements:

- Introduce activity states (`interactive`, `watch`, `idle`, `background`).
- Drive capture cadence by state and recent input/DOM activity.
- Add short suppression windows after high-priority input.
- Provide deterministic state transition telemetry.

### 6.2 Track B: Partial Update Pipeline (Dirty Regions)

Goal:

- Replace full-frame-only updates with region/tile updates when feasible.

Requirements:

- Define tile grid or rect stream format.
- Send only changed tiles/rects under normal interaction.
- Fallback to full-frame keyframes at bounded intervals.
- Ensure visual correctness under scroll, animation, and video.

### 6.3 Track C: Binary Frame Channel

Goal:

- Move frame payloads off JSON lines.

Requirements:

- Keep JSON lines as control protocol.
- Add dedicated binary framing channel for image/tile data.
- Include sequence IDs and timestamps in frame metadata.
- Preserve graceful fallback to legacy full-frame mode.

### 6.4 Track D: Shared Memory Transport (Linux-first)

Goal:

- Remove large frame payloads from pipe transport.

Requirements:

- Implement shm ring buffer for frame/tile payloads.
- Use lightweight control notifications (pipe/eventfd/json control plane).
- Ensure buffer overrun handling and sequence-gap detection.
- Provide fallback when shm unavailable.

### 6.5 Track E: Emacs Render Path Optimization

Goal:

- Reduce redraw and decode overhead in Emacs.

Requirements:

- Avoid unnecessary buffer erase/reinsert cycles when possible.
- Drop stale frame/tile generations before decode.
- Prefer latest generation rendering with explicit generation IDs.
- Add render telemetry (`decode_ms`, `render_ms`, dropped generations).

### 6.6 Track F: Deterministic Replay Harness

Goal:

- Benchmark with repeatable mixed input + page activity traces.

Requirements:

- Record/replay input traces and scenario metadata.
- Produce machine-readable reports with p50/p95/p99 metrics.
- Compare candidate vs baseline with fixed scenario definitions.

## 7. Acceptance SLOs (Program-Level)

All MUST gates must pass on reference hardware and one secondary machine class.

### 7.1 Input Responsiveness MUST

Under mixed high-load scenario (video + interaction):

- `command_ack_latency_ms`: `p95 <= 20`, `p99 <= 50`
- `input_to_next_visible_ms`: `p95 <= 90`, `p99 <= 160`

### 7.2 Freshness MUST

- `frame_or_tile_staleness_ms`: `p95 <= 130`, `p99 <= 220`

### 7.3 Freeze MUST

- No freeze > `1000ms`
- At most 1 freeze > `500ms` per 10-minute stress run

### 7.4 Throughput MUST

- Mixed interactive scenario rendered FPS average `>= 24`
- Watch scenario rendered FPS average `>= 45` at target 60

### 7.5 Efficiency SHOULD

- CPU reduction of >=15% versus PLAN-2 baseline in watch scenario.
- Lower dropped-input incidence versus PLAN-2 baseline.

## 8. Scenario Suite

Each scenario runs 10 minutes and is replayable.

- `S1`: baseline browsing, text-heavy sites, no video
- `S2`: 1080p60 video with mixed key/click/scroll
- `S3`: animation-heavy page with hover/click stress
- `S4`: keyboard-dominant workflow
- `S5`: tab-switching and navigation bursts

Workload minima for `S2/S3`:

- >=400 key events
- >=250 scroll events
- >=120 click events
- >=90 seconds pointer movement

## 9. Data and Telemetry Requirements

Must emit structured logs covering:

- capture decisions and activity state transitions,
- frame/tile generation IDs and timestamps,
- queue depths and drop/coalesce events,
- decode and render timings,
- end-to-end latency derivation fields.

Minimum correlation fields:

- `seq_id`
- `gen_id`
- `ts_ms`
- `path` (`legacy_full_frame`, `binary_full_frame`, `tile`, `shm_tile`)

## 10. Milestones

### M0: Baseline Lock

Deliver:

- freeze current PLAN-2 metrics as comparison baseline,
- publish reference environment profile.

### M1: Activity-Driven Capture

Deliver:

- state machine and adaptive capture policy,
- telemetry and tuning knobs.

Exit:

- measurable latency improvement vs M0.

### M2: Binary Frame Channel v1

Deliver:

- control/data channel split,
- binary payload framing with sequence metadata,
- legacy fallback compatibility.

Exit:

- reduced control-plane contention and lower tail latency.

### M3: Dirty Region Prototype

Deliver:

- tile/rect encode path,
- keyframe + delta policy,
- correctness validation on representative sites.

Exit:

- data volume reduction with no major visual corruption.

### M4: Shared Memory Transport

Deliver:

- shm ring buffer implementation,
- notifier/control integration,
- overflow and desync recovery behavior.

Exit:

- substantial payload-path overhead reduction versus M2.

### M5: Emacs Render Overhaul

Deliver:

- generation-aware stale drop strategy,
- optimized decode/render pipeline,
- instrumentation for render hot path.

Exit:

- reduced `decode_ms + render_ms` tails and improved interactivity.

### M6: Replay Harness and Report Tooling

Deliver:

- deterministic scenario replay,
- one-command benchmark+report output.

Exit:

- reproducible pass/fail evaluation of SLOs.

### M7: Integration and Rollout Policy

Deliver:

- configuration defaults,
- staged rollout flags,
- migration and troubleshooting docs.

Exit:

- deployable profile with clear rollback switches.

## 11. Required File/Module Expectations

Expected touched areas:

- booster codebase (`libexec/*`) for new channels/scheduling,
- `embr.py` for capture strategy and transport integration,
- `embr.el` for render path and protocol integration,
- docs (`README.md`, migration notes),
- benchmark tooling and report scripts.

## 12. ADR Requirements

Must create ADRs for:

- tile format selection,
- binary framing format,
- shm strategy and synchronization model,
- fallback behavior and compatibility boundaries.

ADR template minimum:

- context,
- options considered,
- decision,
- risks,
- validation evidence.

## 13. Rollout Strategy

- default remains stable path until SLO gates pass,
- enable new transport behind feature flags,
- progressively promote features as gates pass,
- keep on-demand fallback until two stable releases pass.

## 14. Risk Register

Risk:

- Dirty-region correctness bugs causing visual artifacts.
Mitigation:

- periodic keyframes, checksum/assertion tools, artifact detection tests.

Risk:

- shm synchronization bugs and rare desync states.
Mitigation:

- sequence checks, watchdog recovery, robust fallback switch.

Risk:

- Emacs render optimization introduces display regressions.
Mitigation:

- side-by-side legacy path toggle and replay comparison.

Risk:

- complexity outruns maintainability.
Mitigation:

- ADR discipline, milestone gates, strict scope boundaries.

## 15. Review Rejection Criteria

Reject if any of the following is true:

- no measurable before/after evidence,
- missing correlation fields for end-to-end timing,
- protocol changes without compatibility path,
- visual correctness regressions are unquantified,
- docs and defaults are out of sync.

## 16. Required Artifacts per Milestone

- architecture note,
- benchmark report (baseline vs candidate),
- SLO pass/fail table,
- known issues and mitigation actions,
- updated docs/config tables where applicable.

## 17. Definition of Done

`PLAN-3` is complete when:

- all mandatory tracks (A-F) are implemented or superseded by accepted ADRs,
- program-level MUST SLOs are met on required environments,
- rollout profile is documented and stable,
- maintainers can diagnose regressions with provided telemetry and replay tooling.

## 18. Immediate Next Action

Create implementation tickets from milestones M1-M7 with explicit owners and non-overlapping write scopes, then execute in sequence while preserving benchmark comparability.


## Implementation Policy Override (Execution Style)

This repository uses a continuous implementation style for performance work.

- Implement phases continuously; do not block on per-phase benchmarks or formal reports.
- Keep diagnostics and benchmark tooling in the codebase as optional tools.
- Any acceptance gate, report requirement, or intermediate target in this plan is non-blocking during implementation.
- Formal validation/testing for sign-off is performed once all phases in this plan are implemented.
- Plan completion does not require maintaining long-term report artifacts.
