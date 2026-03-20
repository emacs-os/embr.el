# PLAN-6: Aggressive-Full Camoufox Runtime Tuning

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers and performance agents

## 1. Executive Decision

Implement the Addendum-A path from PLAN-5 as an `aggressive` profile with full runtime tuning enabled in one pass.

This plan is explicit about execution style:

- tune everything in the aggressive bundle at once,
- do not run per-knob micro-bench loops between changes,
- perform one integrated validation phase at the end.

## 2. Non-Negotiable Constraints

- No Camoufox recompilation for this plan.
- Runtime tunables only (Camoufox/Firefox prefs and launch options).
- Keep uBlock Origin enabled.
- Keep images enabled.
- Keep non-virtual headless mode.
- Keep immediate rollback path to `strict` and `balanced`.

## 3. Scope

In scope:

- implement `aggressive` profile in Emacs + daemon plumbing,
- apply full aggressive runtime preference bundle,
- run one end-to-end benchmark and compatibility validation pass,
- decide go/no-go for opt-in release.

Out of scope:

- source-level Camoufox patching,
- compiling custom Camoufox binaries,
- incremental per-knob tuning cycles.

## 4. Rationale

PLAN-5 recovers performance with balanced risk. PLAN-6 targets additional speed by relaxing higher-cost stealth/isolation defaults, accepting higher detection/challenge risk.

This is for users who prioritize responsiveness and speed over maximum stealth margin.

## 5. Profile Model Requirements

Required profiles after implementation:

- `strict` (existing baseline)
- `balanced` (PLAN-5)
- `aggressive` (PLAN-6 full bundle)

Rules:

- default profile remains unchanged unless separately approved.
- `aggressive` must be opt-in.
- selecting `aggressive` must show explicit warning text in Emacs/messages.

## 6. Aggressive-Full Runtime Bundle (MUST Implement)

Apply all of the following in `aggressive` profile unless a pref is unsupported at runtime.

## 6.1 Isolation Relaxations

- `fission.autostart = false`
- `fission.webContentIsolationStrategy = 0`
- `permissions.isolateBy.userContext = false`
- `network.cookie.cookieBehavior = 0`

Notes:

- These are high-risk for anti-bot posture and site-behavior changes.
- Runtime must log which keys were applied.

## 6.2 Process and Scheduling Relaxations

- `dom.ipc.processPrelaunch.enabled = true`
- `dom.ipc.processCount = 8`
- `dom.iframe_lazy_loading.enabled = true`

## 6.3 Session and BFCache Recovery

- `fission.bfcacheInParent = true`
- `browser.sessionhistory.max_entries = 50`
- `browser.sessionhistory.max_total_viewers = 8`
- `browser.sessionstore.max_tabs_undo = 25`
- `browser.sessionstore.max_windows_undo = 3`
- `browser.sessionstore.restore_tabs_lazily = true`

## 6.4 Network Predictor and Prefetch Recovery

- `network.dns.disablePrefetch = false`
- `network.dns.disablePrefetchFromHTTPS = false`
- `network.prefetch-next = true`
- `network.predictor.enabled = true`

## 6.5 Cache Behavior

- `browser.cache.memory.enable = true`
- `browser.cache.disk.enable = true`
- `browser.cache.disk_cache_ssl = true`

## 6.6 Steady-State Behavioral Requirements

- keep `humanize = false` by default.
- keep addon defaults (do not exclude uBO).
- do not set `block_images`.
- do not use `headless="virtual"`.

## 7. Implementation Requirements

## 7.1 `embr.el` Requirements

- add `aggressive` to Camoufox profile defcustom.
- pass profile selection to daemon init payload.
- show explicit warning when launching with `aggressive`.
- provide one interactive command to print effective profile.

## 7.2 `embr.py` Requirements

- add deterministic profile-to-pref mapping for `aggressive`.
- merge order must be deterministic:
  1. base prefs,
  2. profile prefs,
  3. user overrides,
  4. explicit color-scheme enforcement.
- log applied aggressive pref keys at startup.
- unknown/unsupported pref behavior must fail gracefully.

## 7.3 `README.md` Requirements

- document `aggressive` profile as high-risk opt-in.
- list aggressive bundle at high level.
- include rollback instructions to `balanced` and `strict`.
- include compatibility caveat language.

## 7.4 Optional Setup Requirement

If PLAN-5 geoip split is not yet landed, it may be included, but it is not mandatory for PLAN-6 acceptance.

## 8. Single-Pass Validation Policy

This plan intentionally avoids per-knob intermediate benchmarking.

Required validation flow:

1. Implement full aggressive bundle.
2. Run one comprehensive benchmark/compatibility pass:
   - `strict` baseline,
   - `balanced` comparison,
   - `aggressive` candidate.
3. Produce one consolidated report and decision.

No intermediate tuning loops are required for acceptance of this plan.

## 9. Acceptance Criteria

## 9.1 Performance Must-Haves (vs `balanced`)

- `input_to_next_visible_ms p95` improves by >= 8%
- `domcontentloaded_ms p95` improves by >= 10%
- back/forward revisit latency p95 improves by >= 15%

## 9.2 Stability Must-Haves

- no new crash class,
- no new daemon fatal error class,
- freeze behavior not materially worse than `balanced` baseline.

## 9.3 Compatibility Risk Budget

Aggressive is high risk, but must remain usable.

Acceptance threshold:

- anti-bot/challenge friction increase <= 20% vs `balanced` on fixed site set,
- critical workflows (login, navigation, playback, form submit) pass on target sites.

If threshold exceeded, aggressive remains available only as experimental/dev profile, not recommended in docs.

## 10. Test Matrix

Each scenario runs 10 minutes unless otherwise noted.

- `A1`: content-heavy browsing and navigation
- `A2`: media + mixed interaction (scroll/click/type)
- `A3`: tab churn + back/forward revisit stress
- `A4`: form-heavy authenticated flow
- `A5`: bot-sensitive site challenge sampling (manual score)

Minimum interaction volume for `A2/A3`:

- >=400 key events
- >=250 scroll events
- >=120 click events
- >=90 seconds pointer movement

## 11. Reporting Requirements

Deliver one consolidated report containing:

- profile comparison table (`strict` vs `balanced` vs `aggressive`),
- p50/p95/p99 latency metrics,
- navigation/revisit metrics,
- freeze count/duration,
- compatibility/friction scorecard,
- explicit recommendation:
  - `ship aggressive (opt-in)` or
  - `keep aggressive experimental only`.

## 12. Rollback and Safety Requirements

- user can switch profiles without reinstall.
- unknown profile or bad pref map must fallback to `strict`.
- startup log must include active profile and pref count.
- docs must contain immediate rollback snippet.

## 13. Reviewer Rejection Criteria

Reject if any are true:

- aggressive profile not fully wired end-to-end,
- missing consolidated final report,
- uBO disabled/excluded,
- images blocked,
- virtual headless path introduced,
- no explicit compatibility risk accounting,
- no rollback path documented.

## 14. Risks

Primary risks:

- higher anti-bot challenges,
- site-specific breakage from cookie/isolation relaxations,
- privacy/stealth posture degradation.

Mitigations:

- aggressive remains opt-in,
- clear warning messaging,
- immediate rollback to `balanced`/`strict`,
- maintain compatibility scorecard in release notes.

## 15. Definition of Done

PLAN-6 is complete when:

- aggressive profile bundle in section 6 is implemented,
- single-pass validation in section 8 is completed,
- acceptance criteria in section 9 are evaluated and reported,
- README and profile docs are synchronized,
- rollout recommendation is explicitly documented.

## 16. Future Path (If Runtime Ceiling Hit)

If aggressive runtime tuning still misses goals, next path would require source-level Camoufox patch strategy and custom builds. That is explicitly out of scope for PLAN-6.

