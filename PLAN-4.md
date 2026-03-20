# PLAN-4: No-Emacs-Patch Performance Frontier

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers, performance agents, release reviewers

## 1. Purpose

`PLAN-4` is the performance-frontier program after `PLAN`, `PLAN-2`, and `PLAN-3`.

It is focused on one question:

How far can we push FPS and latency while preserving `embr` architecture constraints and maintainability?

## 2. Hard Constraints

This plan has non-negotiable constraints:

- No Emacs source patching.
- No Emacs fork maintenance.
- No dependency on private Emacs internals.
- Linux-first delivery, with clean fallback behavior.

Allowed extension mechanisms:

- Emacs Lisp changes in `embr.el`.
- External helper binaries under `libexec/`.
- Emacs dynamic modules.
- Daemon/booster changes (`embr.py`, `libexec/embr-booster*`).

## 3. Program Intent

`PLAN-3` tackles major transport and render-path changes.

`PLAN-4` pushes further by targeting the remaining hard limits:

- residual decode and redraw overhead,
- cross-process copy overhead,
- scheduler jitter under burst load,
- unpredictable tail latency in mixed interactive/video scenarios.

## 4. Success Definition

Primary success criteria, ranked:

1. Lowest input-to-visible latency.
2. Lowest tail-latency variance.
3. Highest sustainable rendered FPS.
4. Highest stability under 10-minute stress scenarios.
5. Preserve maintainable no-patch architecture.

## 5. Quantitative Targets

Targets are relative to the final accepted `PLAN-3` baseline.

### 5.1 Latency Targets

Under high-load interactive scenario (`video + mixed input`):

- `command_ack_latency_ms`: `p95 <= 15`, `p99 <= 35`
- `input_to_next_visible_ms`: `p95 <= 65`, `p99 <= 120`
- `input_to_stable_visual_ms` (optional derived metric): `p95 <= 110`

### 5.2 Freshness and Freeze Targets

- `frame_or_tile_staleness_ms`: `p95 <= 90`, `p99 <= 170`
- No freeze event > `750ms`
- At most one freeze > `350ms` per 10-minute stress run

### 5.3 Throughput Targets

- Mixed interactive scenario: rendered FPS average `>= 30`
- Watch scenario at target 60: rendered FPS average `>= 52`
- Stretch goal: rendered FPS average `>= 58` on reference machine

### 5.4 Efficiency Targets

- CPU reduction >= 10% versus final `PLAN-3` path in watch scenario
- Equal or lower dropped-input incidence versus final `PLAN-3`

## 6. Architectural Thesis

To reach these targets without patching Emacs, we must combine:

- tighter control/data separation,
- fewer copies between producer and renderer,
- generation-aware render rejection,
- deterministic scheduling policies,
- small but strict feature flags and rollback paths.

## 7. Workstreams

All workstreams are mandatory unless replaced by accepted ADR.

### W1: Transport Finalization (No-Control Contention)

Goal:

- Make control-plane traffic practically independent from frame payload pressure.

Requirements:

- Keep JSON control path lightweight and non-blocking.
- Use dedicated frame transport path with explicit backpressure semantics.
- Ensure control commands remain P0/P1 priority at all times.
- Track queue depth and service times with high-resolution timestamps.

### W2: Copy Elimination Program

Goal:

- Reduce data copies from frame producer to Emacs-visible buffer.

Requirements:

- Introduce shared-memory-first payload path where available.
- Minimize serialization of large image/tile payloads.
- Define and enforce maximum copy budget per frame path.
- Measure and report copy count by path (`legacy`, `binary`, `shm`).

### W3: Emacs Dynamic Module Acceleration (No Patch)

Goal:

- Reduce decode and conversion overhead without touching Emacs core.

Requirements:

- Prototype dynamic module for hot-path decode/ingest work.
- Keep module optional behind feature flag.
- Maintain full compatibility fallback when module missing.
- Report p95/p99 decode and render improvements with and without module.

### W4: Frame Model Upgrade (Temporal + Spatial)

Goal:

- Cut visual payload and staleness simultaneously.

Requirements:

- Blend keyframe + delta/tile update policy.
- Add generation IDs, dependencies, and stale rejection rules.
- Use bounded keyframe interval to avoid drift and artifact accumulation.
- Validate correctness across scroll, animation, tab switch, and video.

### W5: Real-Time Scheduling and Jitter Control

Goal:

- Reduce jitter spikes during bursts.

Requirements:

- Define scheduling policy for booster/daemon workers.
- Add optional CPU affinity and priority tuning knobs.
- Bound timer jitter and queue service jitter with telemetry.
- Ensure no starvation of critical control traffic.

### W6: Perceptual Latency Layer

Goal:

- Improve perceived immediacy even when absolute work remains.

Requirements:

- Immediate visual acknowledgement paths for critical input classes.
- Configurable short suppression windows and predictive frame pull timing.
- Guarantee no correctness regressions from perceptual optimizations.
- Measure user-visible response timing separately from raw command ack.

### W7: Benchmark and Replay Excellence

Goal:

- Make performance claims reproducible and comparable.

Requirements:

- Deterministic replay traces with fixed scenario definitions.
- One-command run producing machine-readable and markdown reports.
- Include trend regression checks across versions.
- Include optional thermal/CPU governor capture in reports.

## 8. No-Emacs-Patch Compliance Requirements

Every implementation PR in `PLAN-4` must explicitly state:

- whether it uses Emacs Lisp only, dynamic module, or external helper,
- confirmation that no Emacs source patch is required,
- fallback behavior when optional acceleration layer is unavailable.

Reviewers must reject changes violating this policy.

## 9. Milestone Roadmap

### M0: Baseline Freeze and Budget Model

Deliver:

- lock final `PLAN-3` baseline metrics,
- latency budget decomposition by stage,
- copy-path decomposition by stage.

Exit:

- agreed bottleneck map and budget table.

### M1: Transport Hardening

Deliver:

- final control/data split hardening,
- queue policy and backpressure invariant checks,
- stress-tested P0/P1 starvation prevention.

Exit:

- control latency tails improved or unchanged under max frame pressure.

### M2: Shared-Memory Payload Path

Deliver:

- stable shm transport path with sequence control,
- overflow/desync recovery,
- fallback and metrics parity checks.

Exit:

- measurable copy and latency reduction versus M1.

### M3: Dynamic Module Decode Prototype

Deliver:

- optional module implementation for ingest/decode hot path,
- compatibility and safety tests,
- fallback-only path unchanged.

Exit:

- demonstrated p95 decode/render tail improvement on reference machine.

### M4: Frame Model Maturity

Deliver:

- keyframe/delta production and consumption path,
- generation dependency rules and stale drop policy,
- visual correctness tests.

Exit:

- payload reduction with artifact rate within acceptance threshold.

### M5: Jitter and Scheduling Tuning

Deliver:

- CPU affinity/priority options and safe defaults,
- jitter telemetry and regression charts,
- guidance for default and high-performance profiles.

Exit:

- lower jitter and tighter p99 stability under stress.

### M6: Perceptual Response Enhancements

Deliver:

- immediate response cues for critical input,
- calibrated suppression/pull timing,
- correctness validation reports.

Exit:

- improved input-to-visible p95 without regression in correctness metrics.

### M7: Tooling and Gating Completion

Deliver:

- deterministic replay harness finalization,
- standard performance report format,
- automated pass/fail gate checks.

Exit:

- one-command reproducible gate verification.

### M8: Rollout and Hardening

Deliver:

- production-ready defaults,
- staged rollout plan,
- rollback runbook,
- final release notes and troubleshooting.

Exit:

- two consecutive stable release candidates meeting MUST gates.

## 10. Acceptance Gates

### 10.1 Functional Gates

- All existing core browser commands remain correct.
- No protocol corruption or desync under stress.
- Optional acceleration layers fail safely to fallback path.

### 10.2 Performance Gates

- All numeric targets in section 5 met in reference scenarios.
- No performance regressions versus final `PLAN-3` baseline on non-target scenarios.

### 10.3 Stability Gates

- No crash loops in 10-minute stress runs.
- No child process leaks or zombie behavior.
- No unbounded memory growth in booster/daemon/render loop.

## 11. Scenario Matrix

Each scenario runs 10 minutes and is replayable.

- `F1`: text-heavy browsing, moderate interactivity
- `F2`: 1080p60 video with mixed key/click/scroll
- `F3`: animation-heavy hover/click stress
- `F4`: keyboard-dominant navigation/search
- `F5`: rapid tab switching and back/forward bursts
- `F6`: long-session endurance (30 minutes)

Required load minima for `F2/F3`:

- >=500 key events
- >=300 scroll events
- >=150 click events
- >=120 seconds cumulative pointer movement

## 12. Metrics and Telemetry

Mandatory metrics:

- `command_ack_latency_ms`
- `input_to_next_visible_ms`
- `input_to_stable_visual_ms` (if implemented)
- `frame_or_tile_staleness_ms`
- `queue_service_jitter_ms`
- `decode_ms`
- `render_ms`
- copy-count per transport path
- freeze event count/duration

Mandatory correlation fields:

- `ts_ms`
- `seq_id`
- `gen_id`
- `scenario_id`
- `path`
- `queue_class`

## 13. ADR Requirements

Required ADRs:

- dynamic module boundary and API,
- shm synchronization model and failure handling,
- keyframe/delta format and invalidation policy,
- scheduler and affinity policy,
- fallback policy and feature-flag default strategy.

Each ADR must include:

- decision context,
- alternatives,
- measurable tradeoffs,
- risk mitigation,
- validation evidence.

## 14. Security and Safety Requirements

- Treat all inbound control data as untrusted.
- Validate length fields and frame metadata bounds.
- Prevent oversized allocation from malformed or hostile payloads.
- Ensure safe shutdown on broken pipes and partial writes.
- Ensure optional module failures cannot crash Emacs session startup.

## 15. Release Profiles

Define at least two runtime profiles:

- `balanced` (default): stable low-latency with conservative resource usage.
- `max-perf`: aggressive low-latency/high-FPS tuning with explicit caveats.

Each profile must have documented knobs and expected resource envelope.

## 16. Reviewer Rejection Criteria

Reject if:

- no quantitative before/after evidence,
- no replay-based reproducibility,
- no explicit no-Emacs-patch compliance statement,
- missing safe fallback behavior,
- protocol or rendering correctness regressions are unquantified,
- docs and defaults are inconsistent.

## 17. Expected Improvement Envelope

Expected incremental gains versus final `PLAN-3` baseline:

- p95 input-to-visible latency: 10% to 35% improvement
- p99 tail latency: 15% to 40% improvement
- rendered FPS in stress scenarios: 15% to 50% improvement

These are directional planning estimates, not acceptance guarantees.

## 18. Definition of Done

`PLAN-4` is complete when:

- all workstreams W1-W7 are implemented or superseded by accepted ADRs,
- all MUST gates pass across required scenarios,
- no-Emacs-patch policy is upheld for delivered architecture,
- rollout profiles are documented and stable,
- maintainers can diagnose regressions with provided telemetry and replay tools.

## 19. Immediate Next Action

Create implementation tickets for M1-M8 with explicit owners, disjoint write scopes where possible, and mandatory benchmark evidence per milestone.

