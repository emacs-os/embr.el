# PLAN-2: `embr-booster` (C) Transport and Scheduling Spec

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: coding agents implementing the booster and integration

## 1. Executive Decision

We will build an external booster process now.

- Language: **C** (not Go, not Rust)
- Build system: **Makefile**
- Source location: **`./libexec`**
- Initial target platform: Linux (POSIX), matching current `embr` assumptions
- Escalation scope: **full escalation is mandatory** (E1 + E2 + E3), not conditional on missed targets

The booster will sit between Emacs and `embr.py` and provide low-latency, non-blocking, backpressure-aware transport plus message prioritization/drop policies.

## 2. Why We Are Doing This

Current architecture works but still has perceptible latency and micro-stalls under high load (especially video + mixed mouse input).

The current pain is not only JSON parsing speed. It is mostly queueing and head-of-line contention across:

1. Emacs <-> daemon control traffic,
2. daemon event emission and flush behavior,
3. rendering pressure during rapid frame notifications.

A booster gives us explicit scheduling and backpressure control in one place, without replacing Emacs or Camoufox.

## 3. Goals

Primary goals (ranked):

1. Improve perceived interaction responsiveness (click/key/scroll first).
2. Keep UI fresh (avoid stale frame behavior).
3. Preserve enough visual smoothness for practical browsing/video.

Secondary goals:

- isolate transport/scheduling policy from app logic,
- add measurable telemetry for objective tuning,
- keep operational safety and diagnosability high.

## 4. Non-Goals

- Replacing Playwright/Camoufox.
- Eliminating all CDP contention.
- Introducing a new binary wire protocol in v1.
- Rewriting `embr` entirely in C.

## 5. High-Level Architecture

### 5.1 Process Topology

Target topology after integration:

`Emacs (embr.el) <-> embr-booster (C) <-> embr.py <-> Camoufox/Playwright`

`embr-booster` responsibilities:

- spawn and supervise `embr.py`,
- perform async/non-blocking bidirectional forwarding,
- classify messages into priority classes,
- enforce queue limits and drop/coalesce policy,
- emit optional perf telemetry,
- fail fast and surface clear errors.

### 5.2 Protocol Strategy

v1 is protocol-preserving:

- Emacs side still sends newline-delimited JSON commands.
- Daemon side still emits newline-delimited JSON responses/frames.
- Booster must transparently pass through unknown keys/commands.

Any protocol extensions in v1 must be additive and backward-compatible.

## 6. `./libexec` File and Build Requirements

The implementation MUST be placed under `./libexec`.

Minimum required files:

- `libexec/embr-booster.c` (main executable implementation)
- `libexec/Makefile` (build, test helpers, install target)

Allowed optional files (if implementation benefits):

- `libexec/booster_queue.c`
- `libexec/booster_queue.h`
- `libexec/booster_parse.c`
- `libexec/booster_parse.h`
- `libexec/booster_stats.c`
- `libexec/booster_stats.h`

Build requirements:

- Compiler: `cc`/`gcc`/`clang` via Makefile.
- Standard: C11 minimum (`-std=c11`).
- Warnings: `-Wall -Wextra -Wpedantic` (or stricter).
- Optimization: release target with `-O2` minimum.
- Default binary output path: `libexec/embr-booster`.

## 7. Booster Functional Requirements

## 7.1 Process Lifecycle

MUST:

- Launch `embr.py` as child process with piped stdin/stdout/stderr.
- Forward child stderr to booster stderr (or to a configured log file).
- Propagate child exit status.
- On booster termination, terminate child cleanly and avoid zombies.

SHOULD:

- support graceful shutdown timeout and forced kill fallback.

## 7.2 Transport Model

MUST implement independent read/write paths so one blocked direction cannot stall the other.

Required internal channels:

1. Emacs -> Booster ingest
2. Booster -> Python write
3. Python -> Booster ingest
4. Booster -> Emacs write

Implementation may use threads + ring buffers or `poll/epoll` state machine. Either is acceptable if all SLOs are met.

## 7.3 Priority Classes

Booster MUST classify messages and schedule by class:

- `P0` (critical): navigation, back/forward, refresh, quit, command responses/errors
- `P1` (interactive): key/type/click/mousedown/mouseup/scroll/tab ops
- `P2` (hover): mousemove
- `P3` (visual churn): frame notifications

Rules:

- `P0` and `P1` never dropped under normal operation.
- `P2` and `P3` are drop/coalesce eligible.

## 7.4 Coalescing and Drop Policy

MUST:

- Coalesce consecutive `mousemove` updates to latest.
- Coalesce frame notifications to latest when downstream is behind.
- Prefer dropping stale `P3` before delaying `P1`.

MUST NOT:

- reorder command/response pairs in ways that break semantics,
- drop non-idempotent control commands,
- hide daemon errors.

## 7.5 Backpressure Controls

MUST:

- enforce bounded queue capacity per class,
- expose queue depth metrics,
- when queue exceeds high-water mark, apply low-priority shedding first.

SHOULD:

- support per-class high/low watermarks configurable at startup.

## 7.6 Input-Priority Window

MUST implement a temporary input-priority window after `P1` receive:

- duration configurable (`input_priority_window_ms`), default `125ms`.
- during this window, frame forwarding is rate-limited or replace-latest only.
- objective: reduce input-to-visible-action latency spikes.

## 7.7 Fail-Open Behavior

MUST:

- if booster fails to start, `embr.el` can fall back to direct `embr.py` launch.
- if booster crashes during runtime, error should be explicit and diagnosable.

## 8. CLI and Config Requirements

`embr-booster` CLI MUST support:

- `--` followed by daemon command (default command may be supplied by caller)
- `--log-level {error,warn,info,debug,trace}`
- `--queue-capacity N` (global default)
- `--queue-capacity-p2 N`
- `--queue-capacity-p3 N`
- `--input-priority-window-ms N`
- `--frame-forward-max-hz N` (optional cap during pressure)
- `--stats-jsonl PATH` (optional perf log sink)

Environment variable overrides are optional but recommended.

## 9. Emacs Integration Requirements (`embr.el`)

`embr.el` integration work MUST:

- add optional mode to launch booster instead of direct `embr.py`,
- keep default path backward-compatible unless user opts in (or maintainers explicitly choose booster default),
- surface clear diagnostics in `*embr-stderr*`.

Required defcustoms (names may vary but semantics must match):

- booster enabled toggle,
- booster binary path,
- booster args list,
- input-priority window,
- queue/drop tuning knobs (if exposed to user).

## 10. Telemetry and Observability Requirements

## 10.1 Event Logging

When telemetry is enabled, booster MUST emit structured JSONL with monotonic timestamps.

Required events:

- `rx_emacs`, `tx_python`, `rx_python`, `tx_emacs`
- `queue_depth`
- `drop_mousemove`, `drop_frame`
- `coalesce_mousemove`, `coalesce_frame`
- `input_priority_start`, `input_priority_end`
- `child_exit`

Required fields:

- `ts_ms`
- `event`
- `class` (when relevant)
- `queue_depth` (when relevant)
- `reason` (for drops/coalescing)
- `cmd` (if parsed)

## 10.2 Metrics Summary Tooling

v1 MAY include a small parser script, but implementation handoff MUST include reproducible instructions to compute:

- p50/p95/p99 command-ack latency,
- p50/p95/p99 input-to-next-frame latency,
- frame freeze count/duration,
- drop counts by class,
- queue depth distributions.

## 11. Performance Acceptance Requirements

All gates must pass on the same machine/session used for baseline.

### 11.1 Stability Gates (MUST)

- No booster crash in 10-minute stress runs.
- No child process leak/zombie after repeated start/stop cycles.
- No protocol corruption (invalid JSON lines produced by booster).

### 11.2 Responsiveness Gates (MUST)

In high-load scenarios (video + interaction):

- interactive command ack latency `p95 <= 30ms`, `p99 <= 70ms`
- input-to-next-frame latency `p95 <= 120ms`, `p99 <= 220ms`

### 11.3 Freeze Gates (MUST)

- no freeze > 1500ms,
- at most 1 freeze > 750ms per 10-minute stress run.

### 11.4 Throughput Floors (MUST)

- interactive scenario average rendered FPS >= 18,
- idle/watch scenario average rendered FPS >= 40 (when configured for 60).

## 12. Test Matrix

Required scenarios (10 minutes each):

- A: baseline browsing, no video,
- B: 1080p60 video + mixed input,
- C: stress hover + click/drag,
- D: keyboard-dominant flow.

Required workload minima for B/C:

- >=300 key events,
- >=200 scroll events,
- >=100 click events,
- >=60s cumulative pointer movement.

## 13. Security and Robustness Requirements

MUST:

- treat all inbound JSON as untrusted text,
- avoid unbounded allocations from malformed lines,
- guard against partial-line and oversized-line issues,
- avoid busy loops on EOF/broken pipe.

SHOULD:

- impose max line length guardrail with explicit error handling.

## 14. Implementation Milestones

### M0: Baseline Harness

Deliver:

- documented baseline measurements without booster.
- machine/env snapshot.

### M1: Booster Skeleton (`libexec/embr-booster.c` + Makefile)

Deliver:

- child process spawn/supervision,
- transparent forwarding with no policy logic,
- clean shutdown and error handling.

Exit criteria:

- functional parity with direct mode.

### M2: Queueing + Non-blocking Scheduling

Deliver:

- independent direction handling,
- bounded queues,
- class-based scheduling.

Exit criteria:

- no directional head-of-line stalls under synthetic stress.

### M3: Coalescing + Drop Policies

Deliver:

- mousemove coalescing,
- frame replace-latest,
- pressure-triggered shedding.

Exit criteria:

- measurable reduction in tail latency spikes.

### M4: Input-Priority Window + Tunables

Deliver:

- post-input window behavior,
- runtime knobs and docs.

Exit criteria:

- responsiveness SLOs improved versus M2/M3.

### M5: Emacs Integration + Docs

Deliver:

- `embr.el` launch path for booster,
- README updates including setup/usage/tuning,
- troubleshooting section.

Exit criteria:

- maintainable user experience and clear operational behavior.

### M6: Mandatory Control-Plane Escalation

Deliver:

- booster-to-daemon control hints (JSON additive) for dynamic capture pressure,
- daemon support for hints such as `desired_fps` and `frame_shed_level`,
- telemetry proving hints are applied and effective.

Exit criteria:

- improved p95 input latency versus M5 under stress runs without violating freeze/FPS gates.

### M7: Mandatory Data-Plane Escalation

Deliver:

- out-of-band frame metadata/control channel managed by booster,
- compatibility bridge for existing JSON-line mode during migration,
- explicit prioritization isolation between interactive control and visual churn.

Exit criteria:

- measurable reduction in tail latencies and stale-frame behavior versus M6.

### M8: Mandatory Hard Escalation Program

Deliver:

- architecture spike and implementation path for deeper transport separation
  (shared memory/eventfd or alternate renderer transport),
- decision record selecting one hard-escalation architecture for continued rollout,
- prototype benchmark evidence on selected direction.

Exit criteria:

- selected hard-escalation direction demonstrates clear upside and has an approved implementation path.

## 15. Full Escalation Program (Mandatory)

Escalation is not conditional in this plan. E1, E2, and E3 are committed phases.
Acceptance gates still apply, but the roadmap proceeds through all escalation levels.

### E1: Control-Plane Escalation (mandatory)

- Add optional booster-to-daemon control hints (still JSON/additive) for dynamic capture pressure (`desired_fps`, `frame_shed_level`).
- Daemon adapts screenshot cadence directly based on booster pressure signals.

Purpose:

- reduce wasted capture work instead of only dropping notifications downstream.

### E2: Data-Plane Escalation (mandatory)

- Introduce an out-of-band frame metadata/control channel managed by booster.
- Keep compatibility mode for existing JSON lines.

Purpose:

- further decouple interactive commands from visual churn.

### E3: Hard Escalation (mandatory)

- Evaluate deeper architecture change (shared memory/eventfd or alternate renderer transport).
- Implement the selected hard-escalation architecture within this program after decision record approval.

## 16. Review and Rejection Rules

Reviewers must reject any booster implementation that:

- lacks objective before/after metrics,
- introduces unbounded queues,
- drops critical commands,
- breaks protocol compatibility without migration path,
- omits required escalation-phase deliverables,
- leaves docs/config desynced.

## 17. Required Artifacts from Coding Agents

Each delivery must include:

- changed file list,
- architecture note,
- benchmark report (baseline vs candidate),
- SLO pass/fail table,
- operational notes (known limitations + tuning guidance).

## 18. Definition of Done

Done means:

- `libexec/embr-booster.c` and `libexec/Makefile` exist and build cleanly,
- booster integrates with `embr.el` with documented operational mode,
- MUST performance/stability gates pass,
- documentation and defaults are synchronized,
- all mandatory escalation phases (M6-M8 / E1-E3) are completed with evidence artifacts.

## 19. Initial Defaults (for first implementation)

Recommended starting defaults:

- `queue-capacity`: 256 total
- `queue-capacity-p2`: 32
- `queue-capacity-p3`: 8 (replace-latest semantics)
- `input-priority-window-ms`: 125
- `frame-forward-max-hz` under pressure: 20

These are starting points only and must be validated by telemetry.

## 20. Notes for Agent Execution

- Keep write scope narrow per phase.
- Avoid broad refactors in first booster pass.
- Prioritize correctness and observability over premature micro-optimization.
- Execute phases sequentially and retain measurable artifacts at each phase boundary.
