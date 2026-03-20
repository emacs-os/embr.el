# PLAN-5: Camoufox Performance Recovery (Balanced Stealth)

Document status: implementation specification
Last updated: 2026-03-20
Owner: `embr` maintainers
Audience: core implementers and performance agents

## 1. Executive Summary

`embr` moved from vanilla Playwright Firefox to Camoufox for anti-bot/human-likeness reliability. This improved real-world site compatibility, but introduced perceived performance regression versus pre-Camoufox behavior.

`PLAN-5` defines a strict, measurable tuning program to recover performance while preserving practical human-usable stealth posture.

This plan is not about removing Camoufox. It is about tuning Camoufox for a better speed/stealth balance.

## 2. Hard Product Constraints

These constraints are mandatory for this plan:

- Keep Camoufox as browser engine.
- Keep uBlock Origin enabled (do not exclude default uBO addon).
- Keep images enabled (no `block_images=True`).
- Do not use virtual display mode (`headless="virtual"`).
- Preserve normal human browsing UX in Emacs.

## 3. Current Baseline in `embr`

Current code path (as of this plan):

- `embr.py` uses `AsyncNewBrowser(..., headless=True, enable_cache=True, persistent_context=True, os="linux", screen/window constrained)`.
- `embr.py` currently does not pass `geoip=True`.
- `setup.sh` installs `camoufox[geoip]` unconditionally.
- Color scheme is explicitly enforced via `firefox_user_prefs` when chosen.

Observed implication:

- Runtime may carry Camoufox defaults that prioritize stealth consistency over speed in areas like history/cache/prefetch/process behavior.
- Optional geoip functionality is installed even when not used.

## 4. Research Findings (External)

Based on Camoufox docs and repo material:

- Camoufox explicitly reports performance regression in recent period and active development status.
- Camoufox exposes many runtime knobs (`humanize`, `enable_cache`, `exclude_addons`, `headless`, `geoip`, `config`, and toggles).
- uBO is included by default and can be excluded (we will not exclude it).
- `humanize` defaults to `False`.
- Camoufox config contains performance-relevant preferences (fission/process count/session history/cache/prefetch/predictor).

Source links are listed in section 19.

## 5. Goals

Primary goals:

1. Recover a meaningful fraction of pre-Camoufox responsiveness.
2. Keep anti-bot compatibility acceptable for real human browsing.
3. Provide explicit profile-based tuning with measurable outcomes.

Secondary goals:

- reduce startup and warm-navigation latency,
- improve back/forward and revisit behavior,
- keep tuning maintainable and reversible.

## 6. Non-Goals

- Removing Camoufox.
- Disabling uBO.
- Disabling images.
- Switching to virtual display mode.
- Maximizing anonymity at all costs.

## 7. Hypotheses

H1:

- The largest recoverable speed is in restoring parts of Firefox caching/history/prefetch behavior currently constrained by Camoufox defaults.

H2:

- Some process-model defaults can be tuned for lower latency on typical desktop hardware.

H3:

- Optional geoip package/install overhead can be reduced with minimal risk when geoip is unused.

H4:

- A balanced profile can improve UX without materially harming human-site success rates.

## 8. Required Profile Model

`PLAN-5` introduces explicit Camoufox runtime profiles in `embr`.

Mandatory profiles:

- `strict` (baseline-preserving): current behavior, minimal changes.
- `balanced` (target profile): performance-first but still practical stealth.

Optional profile (future only):

- `aggressive` is not part of core implementation. It is documented only in Addendum A.

## 9. Functional Requirements

## 9.1 MUST: Profile Selection

Add an Emacs-facing configuration for Camoufox profile selection.

Required behavior:

- default profile must be `strict` on first release,
- user can opt into `balanced`,
- profile choice is passed to daemon initialization.

## 9.2 MUST: Safe Merge of Preferences

`embr.py` must merge profile prefs with existing runtime prefs (including color scheme overrides) deterministically.

Required behavior:

- no profile may remove existing explicit color scheme behavior,
- profile prefs are additive/override only where defined,
- unknown profile errors must be explicit and non-crashing.

## 9.3 MUST: Keep Required UX/Stealth Choices

The implementation must enforce:

- uBO retained (no `exclude_addons` override for UBO),
- `block_images` remains false/unused,
- no virtual display mode introduction,
- `humanize` remains disabled by default unless explicitly configured.

## 9.4 MUST: GeoIP Installation Split

Setup path must support installing Camoufox without geoip extras by default for non-geoip users.

Required behavior:

- default install path can be plain `camoufox` package,
- optional path enables `camoufox[geoip]` only when requested,
- behavior documented clearly.

## 10. `balanced` Profile Requirements

`balanced` should restore user-perceived browsing speed while avoiding obviously high-risk stealth regressions.

Initial required preference candidate set for A/B testing:

- `dom.ipc.processPrelaunch.enabled = true`
- `browser.cache.memory.enable = true`
- `browser.sessionhistory.max_entries = 50` (or tuned value)
- `browser.sessionhistory.max_total_viewers = 8` (or tuned value)
- `network.dns.disablePrefetch = false`
- `network.dns.disablePrefetchFromHTTPS = false`
- `network.prefetch-next = true`
- `network.predictor.enabled = true`

Process count tuning requirement:

- sweep candidate values for `dom.ipc.processCount` (for example: 8, 12, 16)
- choose value by measured latency/resource tradeoff on reference hardware

Out of scope for `balanced` (reserved for Addendum A):

- disabling fission isolation defaults,
- major anti-detect patch relaxations,
- disabling core stealth invariants.

## 11. Performance Requirements and Acceptance Gates

All gates compare candidate profile against `strict` baseline on same machine/session.

### 11.1 MUST: Responsiveness

Under mixed interaction scenario:

- `input_to_next_visible_ms p95` improves by >= 12%
- `input_to_next_visible_ms p99` does not regress
- `command_ack_latency_ms p95` does not regress

### 11.2 MUST: Navigation and Revisit

- `domcontentloaded_ms p95` improves by >= 10%
- back/forward revisit latency p95 improves by >= 20%

### 11.3 MUST: Stability

- no increase in crash count,
- no new long freezes (> 1.5s) relative to baseline,
- no new protocol/daemon fatal errors.

### 11.4 MUST: Human-Site Compatibility

Define a fixed site set used by maintainers.

Acceptance:

- challenge/friction incidence must not worsen by more than 10% vs baseline,
- critical real-user workflows (login/navigation/media/form input) remain functional.

### 11.5 SHOULD: Efficiency

- CPU in watch scenario improves by >= 5% or remains neutral with clear UX gain,
- memory increase acceptable if user-visible latency improvements are achieved.

## 12. Benchmark Protocol

## 12.1 Scenario Set

Each scenario runs 10 minutes:

- `C1`: normal reading/navigation across content-heavy sites
- `C2`: media + mixed input (scroll, click, text entry)
- `C3`: tab switching + back/forward revisits
- `C4`: form-heavy session

## 12.2 Metrics Collection

Must capture:

- startup init time (`init` to first usable frame),
- navigation timing (`domcontentloaded` and interactive readiness proxy),
- input latency metrics from existing performance harness,
- freeze counts and duration,
- CPU and RSS snapshots.

## 12.3 Comparative Runs

Required run order:

1. `strict` baseline x2
2. `balanced` candidate x2
3. choose winner on median of repeated runs

## 13. Implementation Requirements by File

Expected touched files:

- `embr.el`:
  - new defcustoms for Camoufox profile and optional advanced prefs,
  - protocol field pass-through for selected profile,
  - docs/help text.

- `embr.py`:
  - profile-to-prefs mapping,
  - deterministic merge of profile prefs + existing prefs,
  - initialization option plumbing.

- `setup.sh`:
  - split install behavior for geoip extra vs plain install.

- `README.md`:
  - new config entries and defaults,
  - clear explanation of strict vs balanced profiles,
  - setup notes for geoip optional install.

## 14. Security and Risk Requirements

MUST:

- keep high-risk stealth relaxations out of default path,
- log profile selection at startup for diagnostics,
- preserve deterministic fallback to `strict` on unknown config.

SHOULD:

- expose a one-command way to print current profile + active prefs subset,
- include warning text when non-strict profile is enabled.

## 15. Milestones

### M0: Baseline Lock

Deliver:

- freeze strict-profile baseline metrics,
- finalize test site set and scenario scripts.

### M1: Plumbing and Profile Abstraction

Deliver:

- profile config exposed in Emacs,
- daemon support for profile selection,
- no behavior change in `strict`.

### M2: GeoIP Packaging Split

Deliver:

- setup flow for plain camoufox default,
- optional geoip install path.

### M3: Balanced Prefs A/B Matrix

Deliver:

- controlled sweep for cache/history/process/predictor candidates,
- report with winning combination.

### M4: Integration and Docs

Deliver:

- chosen balanced profile implemented,
- README and configuration docs synchronized.

### M5: Final Validation

Deliver:

- acceptance report with pass/fail against section 11,
- recommendation on default profile promotion timeline.

## 16. Review Rejection Criteria

Reject if any are true:

- uBO is disabled or default-excluded,
- images are blocked by default,
- virtual display mode is introduced as default/required,
- no strict vs balanced comparative metrics provided,
- stealth/compatibility regressions are unmeasured,
- docs/config are out of sync.

## 17. Expected Improvement Envelope

Estimated incremental gains for this plan (vs current strict baseline):

- startup and warm navigation: 8% to 20%
- back/forward and revisit responsiveness: 15% to 35%
- perceived interactivity under mixed browsing: 10% to 25%

These are planning estimates, not guaranteed acceptance outcomes.

## 18. Definition of Done

`PLAN-5` is complete when:

- strict and balanced profiles are implemented and documented,
- geoip install split is implemented and documented,
- mandatory gates in section 11 pass,
- no hard-constraint violations in section 2,
- release recommendation is backed by reproducible benchmark evidence.

## 19. Sources Used (Research)

- Camoufox Python usage docs:
  - https://camoufox.com/python/usage/
- Camoufox stealth overview (performance status note):
  - https://camoufox.com/stealth/
- Camoufox cursor movement behavior/defaults:
  - https://camoufox.com/fingerprint/cursor-movement/
- Camoufox default addon behavior (uBO and exclusion mechanism):
  - https://camoufox.com/fingerprint/addons/
- Camoufox installation/geoip notes:
  - https://camoufox.com/python/installation/
  - https://camoufox.com/python/geoip/
- Camoufox repository and config defaults:
  - https://github.com/daijro/camoufox
  - https://raw.githubusercontent.com/daijro/camoufox/main/settings/camoufox.cfg

## Addendum A: Future Recommendation (Optional, Not in Core PLAN-5)

This addendum corresponds to the previously discussed "optional 6" path.

Purpose:

- recover more speed by relaxing higher-risk stealth defaults.

Scope (future experiment only):

- evaluate fission/isolation relaxations and related anti-detect tradeoffs,
- evaluate more aggressive process/isolation reductions,
- evaluate broader stealth patch relaxations where measurable speed payoff exists.

Requirements for any Addendum-A trial:

- must be behind explicit `aggressive` profile toggle,
- must never become default without separate approval,
- must include stricter anti-bot challenge tracking,
- must provide rollback to `strict` and `balanced` immediately.

Expected upside/risk:

- upside may exceed balanced profile gains,
- detection/challenge risk is materially higher,
- intended only for users prioritizing speed over stealth headroom.

