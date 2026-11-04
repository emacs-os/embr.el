#!/usr/bin/env python3
"""Read embr perf logs and print a source-aware performance report.

Supports single-file analysis and multi-file comparison (screenshot
vs auto vs screencast).  When multiple files are given, computes
median-across-runs per source and prints baseline deltas.

Warm-up exclusion: the first 60s of each log is discarded before
analysis (per PLAN-3 section 8.4).

Uses only the Python standard library.

Usage:
    python3 tools/embr-perf-report.py                        # single log
    python3 tools/embr-perf-report.py run1.jsonl run2.jsonl   # compare
    python3 tools/embr-perf-report.py --no-warmup log.jsonl   # skip warmup
    python3 tools/embr-perf-report.py --min-runs 3 *.jsonl    # enforce min runs
    python3 tools/embr-perf-report.py --appendix-dir out/ *.jsonl  # per-run files
"""

import json
import os
import sys
import tempfile

PERF_LOG_PATH = os.path.join(tempfile.gettempdir(), "embr-perf.jsonl")

FREEZE_THRESHOLD_MS = 750
SEVERE_FREEZE_MS = 1500
WARMUP_MS = 60000
MIN_RUNS_DEFAULT = 1


def percentiles(values, pcts=(50, 95, 99)):
    """Return dict of percentile values from a sorted list."""
    if not values:
        return {p: None for p in pcts}
    s = sorted(values)
    n = len(s)
    out = {}
    for p in pcts:
        k = (p / 100) * (n - 1)
        lo = int(k)
        hi = min(lo + 1, n - 1)
        out[p] = s[lo] + (k - lo) * (s[hi] - s[lo])
    return out


def median(values):
    """Return the median of a list of numbers."""
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def fmt_ms(v):
    if v is None:
        return "  n/a"
    return f"{v:8.1f}"


def load_events(path, warmup_ms=WARMUP_MS):
    """Load JSONL events from a perf log, excluding warm-up period."""
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    if not events or warmup_ms <= 0:
        return events
    ts_list = [e["ts_ms"] for e in events if "ts_ms" in e]
    if not ts_list:
        return events
    cutoff = min(ts_list) + warmup_ms
    return [e for e in events if e.get("ts_ms", 0) >= cutoff]


def print_section(title, values, unit="ms", out=None):
    """Print percentile breakdown for a list of values."""
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    if not values:
        p(f"\n  {title}: no data")
        return
    pv = percentiles(values)
    mx = max(values)
    p(f"\n  {title} (n={len(values)})")
    p(f"    p50  {fmt_ms(pv[50])} {unit}")
    p(f"    p95  {fmt_ms(pv[95])} {unit}")
    p(f"    p99  {fmt_ms(pv[99])} {unit}")
    p(f"    max  {fmt_ms(mx)} {unit}")


def analyze_source(events, source_label, out=None):
    """Analyze and print metrics for a single frame source.

    Return a metrics dict for cross-run comparison.
    """
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    cmd_acks = [e for e in events if e.get("event") == "cmd_ack"]
    frame_emits = [e for e in events if e.get("event") == "frame_emit"]
    frame_renders = [e for e in events if e.get("event") == "frame_render"]
    capture_dones = [e for e in events if e.get("event") == "capture_done"]

    interactive_cmds = {
        "mousemove", "click", "mousedown", "mouseup", "key", "type", "scroll",
    }

    # Command latency.
    all_latencies = [e["latency_ms"] for e in cmd_acks if "latency_ms" in e]
    interactive_latencies = [
        e["latency_ms"] for e in cmd_acks
        if "latency_ms" in e and e.get("cmd") in interactive_cmds
    ]
    print_section("Command ack latency (all)", all_latencies, out=out)
    print_section("Command ack latency (interactive)",
                  interactive_latencies, out=out)

    # Input-to-next-frame.
    input_to_frame = [
        e["input_to_frame_ms"] for e in frame_emits
        if "input_to_frame_ms" in e
    ]
    print_section("Input-to-next-frame latency", input_to_frame, out=out)

    # Frame interval.
    intervals = [e["interval_ms"] for e in frame_emits if "interval_ms" in e]
    print_section("Frame interval", intervals, out=out)
    if intervals:
        p50 = percentiles(intervals)[50]
        if p50 and p50 > 0:
            p(f"    effective FPS (1000/p50): {1000 / p50:.1f}")

    # Frame staleness.
    staleness = [e["frame_staleness_ms"] for e in frame_renders
                 if "frame_staleness_ms" in e]
    print_section("Frame staleness (capture_done -> render)",
                  staleness, out=out)

    # Source-specific capture metrics.
    if source_label == "screenshot":
        captures = [e["capture_ms"] for e in capture_dones
                    if "capture_ms" in e]
        print_section("Capture duration (screenshot only)",
                      captures, out=out)
        sizes = [e["bytes"] for e in capture_dones if "bytes" in e]
    else:
        p("\n  Capture duration: n/a (screencast, browser-driven)")
        sizes = [e["bytes"] for e in frame_emits if "bytes" in e]

    if sizes:
        pv = percentiles(sizes)
        p(f"\n  Frame size (n={len(sizes)})")
        p(f"    p50  {fmt_ms(pv[50])} bytes")
        p(f"    p95  {fmt_ms(pv[95])} bytes")
        p(f"    max  {fmt_ms(max(sizes))} bytes")

    # Ack health (screencast only).
    if source_label != "screenshot":
        ack_ok_vals = [e.get("ack_ok", 0) for e in frame_emits
                       if "ack_ok" in e]
        ack_err_vals = [e.get("ack_errors", 0) for e in frame_emits
                        if "ack_errors" in e]
        total_ok = max(ack_ok_vals) if ack_ok_vals else 0
        total_err = max(ack_err_vals) if ack_err_vals else 0
        total_acks = total_ok + total_err
        err_rate = total_err / total_acks if total_acks > 0 else 0
        p("\n  Ack health (screencast)")
        p(f"    ack_ok:     {total_ok}")
        p(f"    ack_errors: {total_err}")
        p(f"    error_rate: {err_rate:.4%}")

    # Freeze events.
    freezes = [i for i in intervals if i >= FREEZE_THRESHOLD_MS]
    severe = [i for i in intervals if i >= SEVERE_FREEZE_MS]
    p(f"\n  Freeze events (>={FREEZE_THRESHOLD_MS}ms): {len(freezes)}")
    if freezes:
        top = sorted(freezes, reverse=True)[:10]
        p(f"    durations: {', '.join(f'{v:.0f}ms' for v in top)}")
    p(f"  Severe freezes (>={SEVERE_FREEZE_MS}ms): {len(severe)}")

    # FPS distribution.
    if intervals:
        fps_values = [1000 / i for i in intervals if i > 0]
        if fps_values:
            buckets = [(0, 10), (10, 20), (20, 30), (30, 40),
                       (40, 50), (50, 999)]
            labels = ["0-10", "10-20", "20-30", "30-40", "40-50", "50+"]
            p(f"\n  FPS distribution (n={len(fps_values)})")
            for (lo, hi), label in zip(buckets, labels):
                count = sum(1 for f in fps_values if lo <= f < hi)
                pct = count / len(fps_values) * 100
                bar = "#" * int(pct / 2)
                p(f"    {label:6s}  {count:5d}  ({pct:5.1f}%)  {bar}")

    # Frame drops (per-reason breakdown).
    frame_drops = [e for e in events if e.get("event") == "frame_drop"]
    render_skips = sum(e.get("frames_skipped", 0) for e in frame_renders)
    by_reason = {}
    for e in frame_drops:
        r = e.get("reason", "unknown")
        by_reason[r] = by_reason.get(r, 0) + 1
    total_drops = len(frame_drops) + render_skips
    total_opp = len(frame_emits) + len(frame_drops)
    ratio = total_drops / total_opp if total_opp else 0
    p(f"\n  Frame drops (daemon={len(frame_drops)}, "
      f"render_skips={render_skips})")
    if by_reason:
        for reason in sorted(by_reason):
            p(f"    {reason:25s}  {by_reason[reason]}")
    p(f"    dropped_frame_ratio: {ratio:.3f} "
      f"({total_drops}/{total_opp})")

    return {
        "input_to_frame": percentiles(input_to_frame),
        "intervals": percentiles(intervals),
        "staleness": percentiles(staleness),
        "freezes": len(freezes),
        "total_frames": len(frame_emits),
    }


def print_screencast_health(events, out=None):
    """Print screencast-specific health telemetry."""
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    ack_errors = [e for e in events
                  if e.get("event") == "screencast_ack_error"]
    fallback_triggers = [e for e in events
                         if e.get("event") == "fallback_trigger"]
    fallback_completes = [e for e in events
                          if e.get("event") == "fallback_complete"]
    stall_starts = [e for e in events if e.get("event") == "stall_start"]
    stall_ends = [e for e in events if e.get("event") == "stall_end"]
    sc_errors = [e for e in events
                 if e.get("event") == "screencast_error"]

    if not any([ack_errors, fallback_triggers, stall_starts, sc_errors]):
        p("\n  Screencast health: clean (no errors/fallbacks/stalls)")
        return

    p("\n  Screencast health:")
    p(f"    ack_errors:         {len(ack_errors)}")
    p(f"    stall_starts:       {len(stall_starts)}")
    p(f"    stall_ends:         {len(stall_ends)}")
    p(f"    fallback_triggers:  {len(fallback_triggers)}")
    for ft in fallback_triggers:
        p(f"      reason: {ft.get('reason', '?')}")
    p(f"    fallback_completes: {len(fallback_completes)}")
    p(f"    screencast_errors:  {len(sc_errors)}")


def print_summary(events, path=None, out=None):
    """Print overall session summary."""
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    cmd_receives = [e for e in events if e.get("event") == "cmd_receive"]
    frame_emits = [e for e in events if e.get("event") == "frame_emit"]
    ts_list = [e["ts_ms"] for e in events if "ts_ms" in e]
    duration_s = ((max(ts_list) - min(ts_list)) / 1000
                  if len(ts_list) >= 2 else 0)
    avg_fps = len(frame_emits) / duration_s if duration_s > 0 else 0

    versions = {e.get("schema_version", 1) for e in events}
    sources = {e.get("frame_source", "screenshot") for e in events}

    p("\n  Summary")
    if path:
        p(f"    Log:             {path}")
    p(f"    Schema versions: {sorted(versions)}")
    p(f"    Sources:         {', '.join(sorted(sources))}")
    p(f"    Total commands:  {len(cmd_receives)}")
    p(f"    Total frames:    {len(frame_emits)}")
    p(f"    Duration:        {duration_s:.1f}s (after warmup)")
    p(f"    Avg FPS:         {avg_fps:.1f}")


def print_delta(label, baseline_val, candidate_val, out=None):
    """Print delta between two metric values."""
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    if baseline_val is None or candidate_val is None:
        p(f"    {label:35s}  n/a")
        return
    delta = candidate_val - baseline_val
    pct = (delta / baseline_val * 100) if baseline_val != 0 else 0
    p(f"    {label:35s}  {candidate_val:8.1f}  "
      f"(delta: {delta:+.1f}ms, {pct:+.1f}%)")


def run_single_report(events, path=None, warmup_ms=0, out=None):
    """Generate report for a single log file.  Return per-source metrics."""
    p = print if out is None else lambda *a, **kw: print(*a, **kw, file=out)
    sources = {}
    for e in events:
        src = e.get("frame_source", "screenshot")
        sources.setdefault(src, []).append(e)

    p("=" * 60)
    p("  embr performance report")
    if path:
        p(f"  log: {path}")
    p(f"  sources: {', '.join(sorted(sources))}")
    if warmup_ms > 0:
        p(f"  warm-up excluded: first {warmup_ms / 1000:.0f}s")
    p("=" * 60)

    source_metrics = {}
    for source in sorted(sources):
        sevents = sources[source]
        p(f"\n{'- ' * 30}")
        p(f"  Frame source: {source}")
        if source == "screenshot":
            note = "(screenshot-only metrics marked)"
        else:
            note = "(capture timing is browser-driven, not measured)"
        p(f"  {note}")
        p(f"{'- ' * 30}")
        metrics = analyze_source(sevents, source, out=out)
        source_metrics[source] = metrics

    print_screencast_health(events, out=out)
    print_summary(events, path=path, out=out)
    p("=" * 60)
    return source_metrics


def main():
    # Parse args.
    warmup_ms = WARMUP_MS
    min_runs = MIN_RUNS_DEFAULT
    appendix_dir = None
    paths = []
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--no-warmup":
            warmup_ms = 0
        elif args[i] == "--min-runs" and i + 1 < len(args):
            i += 1
            min_runs = int(args[i])
        elif args[i] == "--appendix-dir" and i + 1 < len(args):
            i += 1
            appendix_dir = args[i]
        else:
            paths.append(args[i])
        i += 1
    if not paths:
        paths = [PERF_LOG_PATH]

    for path in paths:
        if not os.path.exists(path):
            print(f"No perf log found at {path}")
            print("Enable with (setq embr-perf-log t) and restart embr.")
            sys.exit(1)

    if appendix_dir:
        os.makedirs(appendix_dir, exist_ok=True)

    # Load all runs.
    all_runs = []
    for path in paths:
        events = load_events(path, warmup_ms=warmup_ms)
        if not events:
            print(f"Perf log is empty (or entirely warm-up): {path}")
            sys.exit(1)
        all_runs.append((path, events))

    def extract_scenario(path):
        """Extract scenario tag from filename (e.g., S1_screenshot_r1 -> S1)."""
        base = os.path.splitext(os.path.basename(path))[0]
        parts = base.split("_")
        if parts and len(parts[0]) >= 2 and parts[0][0] == "S" and parts[0][1:].isdigit():
            return parts[0]
        return "all"

    # Collect metrics per (scenario, source) across all runs.
    # Key = (scenario, source), value = list of metrics dicts.
    aggregate = {}

    for run_idx, (path, events) in enumerate(all_runs):
        scenario = extract_scenario(path)

        # Print to stdout.
        source_metrics = run_single_report(
            events, path=path if len(all_runs) > 1 else None,
            warmup_ms=warmup_ms)

        for source, metrics in source_metrics.items():
            aggregate.setdefault((scenario, source), []).append(metrics)

        # Write per-run appendix if requested.
        if appendix_dir:
            base = os.path.splitext(os.path.basename(path))[0]
            appendix_path = os.path.join(appendix_dir, f"{base}.txt")
            with open(appendix_path, "w") as f:
                run_single_report(
                    events,
                    path=path,
                    warmup_ms=warmup_ms,
                    out=f)
            print(f"  appendix written: {appendix_path}")

    # ── Aggregate comparison ─────────────────────────────────────
    if len(aggregate) <= 1 and len(all_runs) <= 1:
        return

    # Group scenarios.
    scenarios = sorted({k[0] for k in aggregate})
    sources_seen = sorted({k[1] for k in aggregate})

    def median_metric(metrics_list, key, pct=95):
        vals = [m.get(key, {}).get(pct) for m in metrics_list
                if m.get(key, {}).get(pct) is not None]
        return median(vals)

    def compute_medians(runs):
        return {
            "input_to_frame_p95": median_metric(runs, "input_to_frame"),
            "interval_p95": median_metric(runs, "intervals"),
            "staleness_p95": median_metric(runs, "staleness"),
            "freezes": median([r.get("freezes", 0) for r in runs]),
            "total_frames": median([r.get("total_frames", 0) for r in runs]),
            "run_count": len(runs),
        }

    any_below_min = False

    for scenario in scenarios:
        print(f"\n{'=' * 60}")
        print(f"  Aggregate: scenario={scenario}")
        print(f"{'=' * 60}")

        # Run count per source + min-runs check.
        print(f"\n  Run count per source (minimum required: {min_runs}):")
        below_min = False
        scenario_medians = {}
        for source in sources_seen:
            key = (scenario, source)
            runs = aggregate.get(key, [])
            if not runs:
                continue
            n = len(runs)
            flag = "" if n >= min_runs else "  ** BELOW MINIMUM **"
            if n < min_runs:
                below_min = True
            print(f"    {source:15s}  {n} run(s){flag}")
            m = compute_medians(runs)
            scenario_medians[source] = m
            print(f"\n  {source} (median across {n} run(s)):")
            print(f"    input_to_frame p95: {fmt_ms(m['input_to_frame_p95'])} ms")
            print(f"    frame_interval p95: {fmt_ms(m['interval_p95'])} ms")
            print(f"    staleness p95:      {fmt_ms(m['staleness_p95'])} ms")
            print(f"    freezes (median):   {m['freezes']}")
            print(f"    total frames:       {m['total_frames']}")

        if below_min:
            any_below_min = True
            print(f"\n  WARNING: some sources have fewer than {min_runs} "
                  f"runs for {scenario}.")

        # Delta vs screenshot baseline for this scenario.
        if "screenshot" in scenario_medians and len(scenario_medians) > 1:
            baseline = scenario_medians["screenshot"]
            print(f"\n  Delta vs screenshot baseline (scenario={scenario}):")
            for source in sorted(scenario_medians):
                if source == "screenshot":
                    continue
                cand = scenario_medians[source]
                print(f"\n    {source} vs screenshot "
                      f"({cand['run_count']} vs "
                      f"{baseline['run_count']} runs):")
                print_delta("input_to_frame p95",
                            baseline["input_to_frame_p95"],
                            cand["input_to_frame_p95"])
                print_delta("frame_interval p95",
                            baseline["interval_p95"],
                            cand["interval_p95"])
                print_delta("staleness p95",
                            baseline["staleness_p95"],
                            cand["staleness_p95"])
                b_f = baseline["freezes"]
                c_f = cand["freezes"]
                if b_f is not None and c_f is not None:
                    print(f"    {'freezes':35s}  {c_f:8.0f}  "
                          f"(baseline: {b_f:.0f})")

    print(f"\n{'=' * 60}")

    if any_below_min:
        sys.exit(2)


if __name__ == "__main__":
    main()
