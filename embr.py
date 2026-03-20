#!/usr/bin/env python3
"""embr daemon: headless Firefox controlled via JSON over stdin/stdout."""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

FRAME_PATH = os.path.join(tempfile.gettempdir(), "embr-frame.jpg")
SCRIPT_DIR = Path(__file__).resolve().parent
BLOCKLIST_PATH = SCRIPT_DIR / "blocklist.txt"


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
    from camoufox.async_api import AsyncNewBrowser
    from browserforge.fingerprints import Screen
    pw = await async_playwright().start()
    context = None
    page = None
    loop_task = None
    running = True
    target_fps = 30
    jpeg_quality = 80
    cached_title = ""
    frame_count = 0

    user_data_dir = Path.home() / ".local" / "share" / "embr" / "firefox-profile"
    user_data_dir.mkdir(parents=True, exist_ok=True)

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    async def write_frame():
        """Take a JPEG screenshot, write atomically to disk, notify Emacs."""
        nonlocal cached_title, frame_count
        jpg_bytes = await page.screenshot(type="jpeg", quality=jpeg_quality)
        tmp = FRAME_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(jpg_bytes)
        os.rename(tmp, FRAME_PATH)
        frame_count += 1
        if frame_count % 15 == 0:
            cached_title = await page.title()
        emit({"frame": True, "title": cached_title, "url": page.url})

    async def screenshot_loop():
        """Continuously capture frames at target FPS."""
        while running:
            if page is not None:
                start = asyncio.get_event_loop().time()
                try:
                    await write_frame()
                except Exception as e:
                    print(f"embr: screenshot error: {e}", file=sys.stderr)
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

        if cmd == "init":
            width = params.get("width", 1280)
            height = params.get("height", 720)
            sw = params.get("screen_width", 1920)
            sh = params.get("screen_height", 1080)
            browser_opts = dict(
                persistent_context=True,
                user_data_dir=str(user_data_dir),
                headless=True,
                enable_cache=True,
                window=(width, height),
                screen=Screen(min_width=sw, max_width=sw,
                              min_height=sh, max_height=sh),
                os="linux",
                accept_downloads=False,
            )
            color_scheme = params.get("color_scheme")
            if color_scheme:
                browser_opts["color_scheme"] = color_scheme
                # Reinforce via Firefox prefs in case Playwright's context-level
                # setting is overridden by Camoufox's fingerprint.
                prefs = {"layout.css.prefers-color-scheme.content-override":
                         1 if color_scheme == "light" else 0,
                         "ui.systemUsesDarkTheme":
                         0 if color_scheme == "light" else 1}
                browser_opts["firefox_user_prefs"] = prefs
            context = await AsyncNewBrowser(pw, **browser_opts)
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
            target_fps = params.get("fps", 60)
            jpeg_quality = params.get("jpeg_quality", 80)
            page = context.pages[0] if context.pages else await context.new_page()
            # Force our exact viewport size (camoufox may derive a different one from its fingerprint).
            await page.set_viewport_size({"width": width, "height": height})
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
        if should_exit:
            break


if __name__ == "__main__":
    asyncio.run(main())
