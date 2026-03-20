#!/usr/bin/env python3
"""embr daemon: headless Chromium controlled via JSON over stdin/stdout."""

import asyncio
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

FRAME_PATH = os.path.join(tempfile.gettempdir(), "embr-frame.jpg")
PERF_LOG_PATH = os.path.join(tempfile.gettempdir(), "embr-perf.jsonl")
SCRIPT_DIR = Path(__file__).resolve().parent
BLOCKLIST_PATH = SCRIPT_DIR / "blocklist.txt"


class PerfLog:
    """Lightweight JSONL performance logger.  No-op when disabled."""

    INTERACTIVE_CMDS = {
        "mousemove", "click", "mousedown", "mouseup", "key", "type", "scroll",
    }

    def __init__(self):
        self.enabled = False
        self.cmd_id = 0
        self.frame_id = 0
        self.last_frame_emit_ts = None
        self.last_interactive_input_ts = None
        self._file = None

    def enable(self):
        self.enabled = True
        self._file = open(PERF_LOG_PATH, "w", buffering=1)

    def log(self, event, **fields):
        if not self.enabled:
            return
        fields["event"] = event
        fields["ts_ms"] = round(time.monotonic() * 1000, 2)
        self._file.write(json.dumps(fields) + "\n")

    def next_cmd_id(self):
        self.cmd_id += 1
        return self.cmd_id

    def next_frame_id(self):
        self.frame_id += 1
        return self.frame_id

    def close(self):
        if self._file:
            self._file.close()
            self._file = None


def load_blocklist():
    """Load blocked domains from blocklist.txt into a set."""
    if not BLOCKLIST_PATH.exists():
        return set()
    domains = set()
    with open(BLOCKLIST_PATH) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                domains.add(line)
    return domains


async def main():
    from playwright.async_api import async_playwright
    from cloakbrowser.download import ensure_binary
    from cloakbrowser.config import IGNORE_DEFAULT_ARGS, get_default_stealth_args
    pw = await async_playwright().start()
    perf = PerfLog()
    context = None
    page = None
    loop_task = None
    running = True
    target_fps = 30
    jpeg_quality = 80
    cached_title = ""
    frame_count = 0

    # Input-priority scheduler state.
    input_priority_until = 0.0      # monotonic ts — capture suppressed until this
    mode = "watch"                  # "interactive" or "watch"
    input_priority_window_s = 0.035 # from init params (default 35ms)

    # Adaptive capture controller state.
    adaptive_enabled = False
    fps_min = 40
    fps_max = 60          # set to user-configured ceiling at init
    quality_min = 65
    quality_max = 80      # set to user-configured ceiling at init
    capture_ema = 0.0
    stable_frames = 0
    adapt_cooldown = 0
    last_rendered_frame_id = 0

    user_data_dir = Path.home() / ".local" / "share" / "embr" / "chromium-profile"
    user_data_dir.mkdir(parents=True, exist_ok=True)

    print("embr: engine=cloakbrowser", file=sys.stderr)

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    def emit_frame(obj):
        """Emit a frame notification on stdout."""
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    async def write_frame():
        """Take a JPEG screenshot, write atomically to disk, notify Emacs."""
        nonlocal cached_title, frame_count, capture_ema
        fid = perf.next_frame_id()
        t0 = time.monotonic()
        perf.log("capture_start", frame_id=fid)
        jpg_bytes = await page.screenshot(type="jpeg", quality=jpeg_quality)
        t_capture_done = time.monotonic()
        capture_ms = round((t_capture_done - t0) * 1000, 2)
        perf.log("capture_done", frame_id=fid, capture_ms=capture_ms,
                 bytes=len(jpg_bytes))
        # Update capture EMA for adaptive controller.
        alpha = 0.2
        capture_ema = alpha * capture_ms + (1 - alpha) * capture_ema
        tmp = FRAME_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(jpg_bytes)
        os.rename(tmp, FRAME_PATH)
        frame_count += 1
        if frame_count % 15 == 0:
            cached_title = await page.title()
        capture_done_mono_ms = round(t_capture_done * 1000, 2)
        emit_frame({"frame": True, "title": cached_title, "url": page.url,
                    "pressure": mode == "interactive" or target_fps < fps_max,
                    "frame_id": fid, "capture_done_mono_ms": capture_done_mono_ms})
        now = time.monotonic()
        emit_fields = dict(frame_id=fid, fps_target=target_fps,
                           jpeg_quality=jpeg_quality, mode=mode,
                           fps_effective=round(1000 / max(1, capture_ms), 1))
        if perf.last_frame_emit_ts is not None:
            emit_fields["interval_ms"] = round(
                (now - perf.last_frame_emit_ts) * 1000, 2)
        if perf.last_interactive_input_ts is not None:
            emit_fields["input_to_frame_ms"] = round(
                (now - perf.last_interactive_input_ts) * 1000, 2)
            perf.last_interactive_input_ts = None
        perf.log("frame_emit", **emit_fields)
        perf.last_frame_emit_ts = now

    async def screenshot_loop():
        """Continuously capture frames at target FPS."""
        nonlocal mode, input_priority_until, stable_frames, adapt_cooldown
        nonlocal target_fps, jpeg_quality
        in_priority_window = False
        while running:
            if page is not None:
                # Input-priority: suppress capture during the window.
                now = time.monotonic()
                if now < input_priority_until:
                    in_priority_window = True
                    perf.log("frame_drop", reason="input_priority",
                             frame_id=perf.frame_id + 1)
                    await asyncio.sleep(0.01)
                    continue
                if in_priority_window:
                    in_priority_window = False
                    perf.log("input_priority_end")
                if mode != "watch":
                    old = mode
                    mode = "watch"
                    perf.log("mode_change", old_mode=old, new_mode="watch")

                start = asyncio.get_event_loop().time()
                try:
                    await write_frame()
                except Exception as e:
                    print(f"embr: screenshot error: {e}", file=sys.stderr)

                # Adaptive capture controller.
                if adaptive_enabled:
                    if adapt_cooldown > 0:
                        adapt_cooldown -= 1
                    else:
                        frame_budget_ms = 1000 / target_fps
                        if capture_ema > frame_budget_ms * 0.7:
                            # Step down — reduce pressure.
                            old_fps, old_q = target_fps, jpeg_quality
                            if target_fps > fps_min:
                                target_fps = max(fps_min, target_fps - 2)
                            elif jpeg_quality > quality_min:
                                jpeg_quality = max(quality_min,
                                                   jpeg_quality - 5)
                            if (target_fps, jpeg_quality) != (old_fps, old_q):
                                perf.log("adapt_step", direction="down",
                                         fps=target_fps,
                                         jpeg_quality=jpeg_quality,
                                         capture_ema_ms=round(capture_ema, 1),
                                         reason="budget_overrun")
                                adapt_cooldown = 30
                                stable_frames = 0
                        elif capture_ema < frame_budget_ms * 0.5:
                            stable_frames += 1
                            if stable_frames >= 60:
                                # Step up — recover.
                                old_fps, old_q = target_fps, jpeg_quality
                                if jpeg_quality < quality_max:
                                    jpeg_quality = min(quality_max,
                                                       jpeg_quality + 5)
                                elif target_fps < fps_max:
                                    target_fps = min(fps_max, target_fps + 1)
                                if (target_fps, jpeg_quality) != (old_fps,
                                                                  old_q):
                                    perf.log("adapt_step", direction="up",
                                             fps=target_fps,
                                             jpeg_quality=jpeg_quality,
                                             capture_ema_ms=round(
                                                 capture_ema, 1),
                                             reason="stable")
                                    adapt_cooldown = 60
                                    stable_frames = 0
                        else:
                            stable_frames = 0

                elapsed = asyncio.get_event_loop().time() - start
                await asyncio.sleep(max(0, (1 / target_fps) - elapsed))
            else:
                await asyncio.sleep(0.05)

    # ── Mouse handling ──────────────────────────────────────────────
    # Clicks use page.evaluate() (Runtime domain) — never contends
    # with the screenshot loop's Page.captureScreenshot traffic.
    # Mousemove uses CDP page.mouse.move() for isTrusted=true (CSS
    # :hover), as fire-and-forget with cancel-and-replace so it can
    # never block anything.
    mouse_move_task = None

    _MOUSE_JS = """([type, x, y]) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return;
        const opts = {bubbles: true, cancelable: true, view: window,
                      clientX: x, clientY: y, button: 0};
        el.dispatchEvent(new PointerEvent(type.replace('mouse', 'pointer'), opts));
        el.dispatchEvent(new MouseEvent(type, opts));
    }"""

    _CLICK_JS = """([x, y]) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return;
        const opts = {bubbles: true, cancelable: true, view: window,
                      clientX: x, clientY: y, button: 0};
        for (const t of ['pointerdown','mousedown','pointerup','mouseup','click'])
            el.dispatchEvent(new MouseEvent(t, opts));
    }"""

    async def handle(cmd, params):
        nonlocal context, page, running, loop_task, target_fps, jpeg_quality, cached_title
        nonlocal input_priority_window_s
        nonlocal adaptive_enabled, fps_min, fps_max, quality_min, quality_max

        if cmd == "init":
            if params.get("perf_log"):
                perf.enable()
            width = params.get("width", 1280)
            height = params.get("height", 720)
            sw = params.get("screen_width", 1920)
            sh = params.get("screen_height", 1080)
            binary_path = ensure_binary()
            chrome_args = get_default_stealth_args()
            context_opts = dict(
                user_data_dir=str(user_data_dir),
                executable_path=binary_path,
                headless=True,
                args=chrome_args,
                ignore_default_args=IGNORE_DEFAULT_ARGS + ["--mute-audio"],
                viewport={"width": width, "height": height},
                screen={"width": sw, "height": sh},
                accept_downloads=False,
            )
            color_scheme = params.get("color_scheme")
            if color_scheme:
                context_opts["color_scheme"] = color_scheme
            context = await pw.chromium.launch_persistent_context(**context_opts)
            # Ad blocking via request interception.
            blocked = load_blocklist()
            if blocked:
                def is_blocked(host):
                    """Check host and all parent domains against blocklist."""
                    parts = host.split(".")
                    for i in range(len(parts)):
                        if ".".join(parts[i:]) in blocked:
                            return True
                    return False

                async def block_ads(route):
                    host = urlparse(route.request.url).hostname or ""
                    if is_blocked(host):
                        await route.abort()
                    else:
                        await route.continue_()
                await context.route("**/*", block_ads)
            # Fake caret: CDP screenshots don't capture the native caret.
            # Inject a DOM element that polls cursor position in focused inputs.
            dom_caret = params.get("dom_caret", False)
            _CARET_BODY = """
if (window.__embr_caret) return;
window.__embr_caret = true;
function embrStartCaret() {
    var el = document.createElement('div');
    el.id = '__embr_caret';
    el.style.cssText = 'position:fixed;z-index:2147483647;width:2px;height:16px;background:red;pointer-events:none;display:none;';
    document.body.appendChild(el);
    setInterval(function() {
        try {
            var ae = document.activeElement;
            if (!ae || ae === document.body || ae === document.documentElement) {
                el.style.display = 'none';
                return;
            }
            var tag = ae.tagName;
            var isInput = (tag === 'INPUT' || tag === 'TEXTAREA') && ae.selectionStart != null;
            var editable = ae.isContentEditable;
            if (!isInput && !editable) {
                el.style.display = 'none';
                return;
            }
            if (editable) {
                var sel = window.getSelection();
                if (sel && sel.rangeCount && sel.isCollapsed) {
                    var r = sel.getRangeAt(0).cloneRange();
                    r.collapse(false);
                    var rect = r.getBoundingClientRect();
                    if (rect && rect.height > 0) {
                        el.style.left = rect.left + 'px';
                        el.style.top = rect.top + 'px';
                        el.style.height = rect.height + 'px';
                        el.style.background = getComputedStyle(ae).color || 'red';
                        el.style.display = 'block';
                        return;
                    }
                }
                el.style.display = 'none';
                return;
            }
            var pos = ae.selectionStart;
            var cs = getComputedStyle(ae);
            var br = ae.getBoundingClientRect();
            var m = document.createElement('div');
            var props = ['font','letterSpacing','textTransform','paddingLeft','paddingRight','paddingTop','paddingBottom','borderLeftWidth','borderRightWidth','borderTopWidth','borderBottomWidth','boxSizing'];
            m.style.cssText = 'position:absolute;top:-9999px;left:-9999px;visibility:hidden;white-space:pre;overflow:hidden;';
            for (var i = 0; i < props.length; i++) m.style[props[i]] = cs[props[i]];
            m.style.width = br.width + 'px';
            if (tag === 'TEXTAREA') m.style.whiteSpace = 'pre-wrap';
            var textBefore = ae.value.substring(0, pos);
            m.textContent = textBefore;
            var sp = document.createElement('span');
            sp.textContent = '|';
            m.appendChild(sp);
            document.body.appendChild(m);
            var spRect = sp.getBoundingClientRect();
            var mRect = m.getBoundingClientRect();
            m.remove();
            var lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
            var x = br.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft) + (spRect.left - mRect.left) - ae.scrollLeft;
            var y = br.top + (spRect.top - mRect.top) - ae.scrollTop;
            el.style.left = x + 'px';
            el.style.top = y + 'px';
            el.style.height = lh + 'px';
            el.style.background = cs.color || 'red';
            el.style.display = 'block';
        } catch(e) { console.error('embr caret:', e); }
    }, 50);
}
if (document.body) embrStartCaret();
else document.addEventListener('DOMContentLoaded', embrStartCaret);
"""
            if dom_caret:
                await context.add_init_script(_CARET_BODY)

            target_fps = params.get("fps", 60)
            jpeg_quality = params.get("jpeg_quality", 80)

            # Input-priority scheduler params.
            input_priority_window_s = params.get(
                "input_priority_window_ms", 35) / 1000.0

            # Adaptive capture controller params.
            adaptive_enabled = bool(params.get("adaptive_capture", False))
            fps_min = params.get("adaptive_fps_min", 40)
            fps_max = target_fps
            quality_min = params.get("adaptive_jpeg_quality_min", 65)
            quality_max = jpeg_quality

            page = context.pages[0] if context.pages else await context.new_page()
            if dom_caret:
                try:
                    await page.evaluate("() => {" + _CARET_BODY + "}")
                except Exception:
                    pass
            loop_task = asyncio.create_task(screenshot_loop())
            return {"ok": True, "frame_path": FRAME_PATH}

        if context is None or page is None:
            return {"error": "not initialized — send init first"}

        if cmd == "navigate":
            url = params["url"]
            if not url.startswith(("http://", "https://", "file://")):
                url = "https://" + url
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=10000)
            except Exception:
                pass  # Timeout or nav error — page state visible via screenshots.
            cached_title = await page.title()
            return {"ok": True}

        # Mousemove: fire-and-forget CDP (isTrusted=true for CSS :hover).
        # Cancel-and-replace — each new move cancels the previous.
        if cmd == "mousemove":
            # Drop hover during input-priority window.
            if time.monotonic() < input_priority_until:
                return {"ok": True}
            nonlocal mouse_move_task
            if mouse_move_task and not mouse_move_task.done():
                mouse_move_task.cancel()
            async def _move(x, y):
                try:
                    await page.mouse.move(x, y)
                except Exception:
                    pass
            mouse_move_task = asyncio.create_task(
                _move(params.get("x", 0), params.get("y", 0)))
            return {"ok": True}

        # Frame rendered ack from Emacs — logs true staleness at render time.
        # Emacs echoes capture_done_mono_ms (daemon monotonic) back so we
        # compute staleness entirely within the daemon's monotonic clock.
        if cmd == "frame_rendered":
            nonlocal last_rendered_frame_id
            fid = params.get("frame_id", 0)
            capture_mono = params.get("capture_done_mono_ms", 0)
            now_mono_ms = round(time.monotonic() * 1000, 2)
            staleness = round(now_mono_ms - capture_mono, 2) if capture_mono else 0
            skipped = max(0, fid - last_rendered_frame_id - 1)
            perf.log("frame_render", frame_id=fid,
                     frame_staleness_ms=staleness,
                     frames_skipped=skipped)
            last_rendered_frame_id = fid
            return {"ok": True}

        # Click: JS evaluate (Runtime domain, no CDP pipe contention).
        if cmd == "click":
            asyncio.create_task(
                page.evaluate(_CLICK_JS, [params["x"], params["y"]]))
            return {"ok": True}
        # Mousedown/mouseup: CDP (isTrusted=true, needed for native text
        # selection).  Fire-and-forget — infrequent (one per drag) so they
        # find gaps in the pipe like keyboard events.
        if cmd == "mousedown":
            async def _down(x, y):
                try:
                    await page.mouse.move(x, y)
                    await page.mouse.down()
                except Exception:
                    pass
            asyncio.create_task(_down(params["x"], params["y"]))
            return {"ok": True}
        if cmd == "mouseup":
            async def _up(x, y):
                try:
                    await page.mouse.move(x, y)
                    await page.mouse.up()
                except Exception:
                    pass
            asyncio.create_task(_up(params["x"], params["y"]))
            return {"ok": True}

        # Keyboard and scroll are also fire-and-forget: these are
        # high-frequency input commands that must never block the
        # command loop under CDP contention.
        if cmd in ("type", "key", "scroll"):
            async def _input(c, p):
                try:
                    if c == "type":
                        await page.keyboard.type(p["text"])
                    elif c == "key":
                        await page.keyboard.press(p["key"])
                    elif c == "scroll":
                        await page.evaluate(
                            "window.scrollBy({{left: {}, top: {}, behavior: '{}'}})".format(
                                p.get("delta_x", 0), p.get("delta_y", 0),
                                p.get("behavior", "instant")))
                except Exception:
                    pass
            asyncio.create_task(_input(cmd, params))
            return {"ok": True}

        if cmd == "back":
            try:
                await page.go_back(wait_until="domcontentloaded", timeout=5000)
            except Exception:
                pass
            cached_title = await page.title()
            return {"ok": True}

        if cmd == "forward":
            try:
                await page.go_forward(wait_until="domcontentloaded", timeout=5000)
            except Exception:
                pass
            cached_title = await page.title()
            return {"ok": True}

        if cmd == "refresh":
            try:
                await page.reload(wait_until="domcontentloaded", timeout=10000)
            except Exception:
                pass
            cached_title = await page.title()
            return {"ok": True}

        if cmd == "js":
            result = await page.evaluate(params["expr"])
            return {"ok": True, "result": result}

        if cmd == "hints":
            # Inject hint labels onto all clickable elements, return their info.
            hints = await page.evaluate("""() => {
                // Remove old hints if any.
                document.querySelectorAll('.embr-hint').forEach(e => e.remove());
                const sel = 'a, button, input, select, textarea, [onclick], [role="button"], [role="link"], [tabindex]';
                const els = Array.from(document.querySelectorAll(sel)).filter(el => {
                    const r = el.getBoundingClientRect();
                    const s = getComputedStyle(el);
                    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
                });
                const chars = 'asdfghjkl';
                function label(n) {
                    let s = '';
                    do {
                        s = chars[n % chars.length] + s;
                        n = Math.floor(n / chars.length) - 1;
                    } while (n >= 0);
                    return s;
                }
                const results = [];
                els.forEach((el, i) => {
                    const r = el.getBoundingClientRect();
                    const tag = label(i);
                    const hint = document.createElement('div');
                    hint.className = 'embr-hint';
                    hint.textContent = tag;
                    hint.style.cssText = 'position:fixed;z-index:2147483647;background:#ffee00;color:#000;font:bold 12px monospace;padding:1px 3px;border:1px solid #000;border-radius:2px;pointer-events:none;';
                    hint.style.left = r.left + 'px';
                    hint.style.top = r.top + 'px';
                    document.body.appendChild(hint);
                    results.push({tag: tag, x: r.left + r.width/2, y: r.top + r.height/2, text: (el.textContent || el.value || '').trim().slice(0, 60)});
                });
                return results;
            }""")
            return {"ok": True, "hints": hints}

        if cmd == "hints-clear":
            await page.evaluate("() => document.querySelectorAll('.embr-hint').forEach(e => e.remove())")
            return {"ok": True}

        if cmd == "text":
            text = await page.inner_text("body")
            return {"ok": True, "text": text}

        if cmd == "fill":
            await page.fill(params["selector"], params["value"])
            return {"ok": True}

        if cmd == "select":
            await page.select_option(params["selector"], params["value"])
            return {"ok": True}

        if cmd == "new-tab":
            new_page = await context.new_page()
            url = params.get("url", "about:blank")
            if url != "about:blank" and not url.startswith(("http://", "https://", "file://")):
                url = "https://" + url
            if url != "about:blank":
                await new_page.goto(url, wait_until="domcontentloaded", timeout=30000)
            page = new_page
            return {"ok": True, "tab_index": len(context.pages) - 1}

        if cmd == "close-tab":
            if len(context.pages) <= 1:
                return {"error": "cannot close last tab"}
            await page.close()
            page = context.pages[-1]
            await page.bring_to_front()
            return {"ok": True, "tab_index": len(context.pages) - 1}

        if cmd == "list-tabs":
            tabs = []
            for i, p in enumerate(context.pages):
                tabs.append({"index": i, "title": await p.title(), "url": p.url,
                             "active": p == page})
            return {"ok": True, "tabs": tabs}

        if cmd == "switch-tab":
            idx = params["index"]
            if 0 <= idx < len(context.pages):
                page = context.pages[idx]
                await page.bring_to_front()
                cached_title = await page.title()
                return {"ok": True}
            return {"error": f"tab index out of range: {idx}"}

        if cmd == "quit":
            running = False
            if loop_task:
                loop_task.cancel()
                try:
                    await loop_task
                except asyncio.CancelledError:
                    pass
            if context:
                await context.close()
            await pw.stop()
            perf.close()
            try:
                os.unlink(FRAME_PATH)
            except OSError:
                pass
            return None  # signals exit

        return {"error": f"unknown command: {cmd}"}

    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_event_loop().connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        line = await reader.readline()
        if not line:
            break

        # Batch-read: collect this line plus any already buffered.
        pending = [line]
        while b'\n' in reader._buffer:
            pending.append(await reader.readline())

        # Parse all pending lines; coalesce consecutive mousemoves so they
        # don't starve real commands after a slow handler (click/navigate).
        commands = []
        last_mousemove = None
        for raw in pending:
            text = raw.decode("utf-8").strip()
            if not text:
                continue
            try:
                msg = json.loads(text)
            except json.JSONDecodeError as e:
                emit({"error": f"invalid JSON: {e}"})
                continue
            if msg.get("cmd") == "mousemove":
                last_mousemove = msg
            else:
                # Flush any accumulated mousemove before a real command
                # so the cursor position is up-to-date.
                if last_mousemove is not None:
                    commands.append(last_mousemove)
                    last_mousemove = None
                commands.append(msg)
        if last_mousemove is not None:
            commands.append(last_mousemove)

        should_exit = False
        for msg in commands:
            cmd = msg.get("cmd", "")
            params = {k: v for k, v in msg.items() if k != "cmd"}
            cid = perf.next_cmd_id()
            perf.log("cmd_receive", cmd=cmd, cmd_id=cid)
            if cmd in PerfLog.INTERACTIVE_CMDS:
                perf.last_interactive_input_ts = time.monotonic()
                # mousemove is passive hover tracking — it should not
                # extend the input-priority window or it would starve
                # frame capture for the entire duration of pointer movement.
                if cmd != "mousemove":
                    input_priority_until = time.monotonic() + input_priority_window_s
                    perf.log("input_priority_start", cmd=cmd,
                             window_ms=round(input_priority_window_s * 1000, 1))
                if mode != "interactive":
                    old = mode
                    mode = "interactive"
                    perf.log("mode_change", old_mode=old, new_mode="interactive")
            t0 = time.monotonic()
            try:
                resp = await asyncio.wait_for(handle(cmd, params), timeout=35)
            except asyncio.TimeoutError:
                resp = {"error": f"command timed out: {cmd}"}
            except Exception as e:
                resp = {"error": str(e)}
            if resp is None:
                should_exit = True
                break
            emit(resp)
            latency_ms = round((time.monotonic() - t0) * 1000, 2)
            perf.log("cmd_ack", cmd=cmd, cmd_id=cid, latency_ms=latency_ms)
        if should_exit:
            break


if __name__ == "__main__":
    asyncio.run(main())
