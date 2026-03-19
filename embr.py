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

    pw = await async_playwright().start()
    context = None
    page = None
    loop_task = None
    running = True
    target_fps = 30

    user_data_dir = Path.home() / ".local" / "share" / "embr" / "firefox-profile"
    user_data_dir.mkdir(parents=True, exist_ok=True)

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()

    async def write_frame():
        """Take a JPEG screenshot, write atomically to disk, notify Emacs."""
        jpg_bytes = await page.screenshot(type="jpeg", quality=80)
        tmp = FRAME_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(jpg_bytes)
        os.rename(tmp, FRAME_PATH)
        emit({"frame": True, "title": await page.title(), "url": page.url})

    async def screenshot_loop():
        """Continuously capture frames at ~30 FPS."""
        while running:
            if page is not None:
                start = asyncio.get_event_loop().time()
                try:
                    await write_frame()
                except Exception:
                    pass
                elapsed = asyncio.get_event_loop().time() - start
                await asyncio.sleep(max(0, (1 / target_fps) - elapsed))
            else:
                await asyncio.sleep(0.05)

    async def handle(cmd, params):
        nonlocal context, page, running, loop_task, target_fps

        if cmd == "init":
            width = params.get("width", 1280)
            height = params.get("height", 720)
            context = await pw.firefox.launch_persistent_context(
                str(user_data_dir),
                headless=True,
                viewport={"width": width, "height": height},
                screen={"width": params.get("screen_width", 1920),
                        "height": params.get("screen_height", 1080)},
                accept_downloads=False,
            )
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
            target_fps = params.get("fps", 30)
            fullscreen_hack = params.get("fullscreen_hack", False)
            page = context.pages[0] if context.pages else await context.new_page()
            if fullscreen_hack:
                await context.add_init_script("""
                    (function() {
                        let fsEl = null;
                        const saved = new Map();
                        function enterFs(el) {
                            fsEl = el;
                            saved.set(el, el.getAttribute('style') || '');
                            el.style.setProperty('position', 'fixed', 'important');
                            el.style.setProperty('top', '0', 'important');
                            el.style.setProperty('left', '0', 'important');
                            el.style.setProperty('width', '100vw', 'important');
                            el.style.setProperty('height', '100vh', 'important');
                            el.style.setProperty('z-index', '2147483647', 'important');
                            el.style.setProperty('background', '#000', 'important');
                            const vid = el.querySelector('video');
                            if (vid) {
                                saved.set(vid, vid.getAttribute('style') || '');
                                vid.style.setProperty('width', '100%', 'important');
                                vid.style.setProperty('height', '100%', 'important');
                                vid.style.setProperty('object-fit', 'contain', 'important');
                            }
                            const getFsEl = () => fsEl;
                            Object.defineProperty(document, 'fullscreenElement', {
                                get: getFsEl, configurable: true
                            });
                            Object.defineProperty(document, 'mozFullScreenElement', {
                                get: getFsEl, configurable: true
                            });
                            Object.defineProperty(document, 'webkitFullscreenElement', {
                                get: getFsEl, configurable: true
                            });
                            el.dispatchEvent(new Event('fullscreenchange', {bubbles: true}));
                            document.dispatchEvent(new Event('fullscreenchange'));
                            document.dispatchEvent(new Event('mozfullscreenchange'));
                            document.dispatchEvent(new Event('webkitfullscreenchange'));
                            return Promise.resolve();
                        }
                        function exitFs() {
                            if (fsEl) {
                                const origStyle = saved.get(fsEl);
                                if (origStyle !== undefined) fsEl.setAttribute('style', origStyle);
                                else fsEl.removeAttribute('style');
                                const vid = fsEl.querySelector('video');
                                if (vid) {
                                    const vs = saved.get(vid);
                                    if (vs !== undefined) vid.setAttribute('style', vs);
                                    else vid.removeAttribute('style');
                                }
                                fsEl = null;
                                const getNull = () => null;
                                Object.defineProperty(document, 'fullscreenElement', {
                                    get: getNull, configurable: true
                                });
                                Object.defineProperty(document, 'mozFullScreenElement', {
                                    get: getNull, configurable: true
                                });
                                Object.defineProperty(document, 'webkitFullscreenElement', {
                                    get: getNull, configurable: true
                                });
                                document.dispatchEvent(new Event('fullscreenchange'));
                                document.dispatchEvent(new Event('mozfullscreenchange'));
                                document.dispatchEvent(new Event('webkitfullscreenchange'));
                            }
                            return Promise.resolve();
                        }
                        // Standard
                        Element.prototype.requestFullscreen = function() { return enterFs(this); };
                        document.exitFullscreen = exitFs;
                        // Mozilla
                        Element.prototype.mozRequestFullScreen = function() { return enterFs(this); };
                        document.mozCancelFullScreen = exitFs;
                        // WebKit
                        Element.prototype.webkitRequestFullscreen = function() { return enterFs(this); };
                        Element.prototype.webkitRequestFullScreen = function() { return enterFs(this); };
                        document.webkitExitFullscreen = exitFs;
                        // Fullscreen enabled
                        Object.defineProperty(document, 'fullscreenEnabled', {
                            get: () => true, configurable: true
                        });
                        Object.defineProperty(document, 'mozFullScreenEnabled', {
                            get: () => true, configurable: true
                        });
                        Object.defineProperty(document, 'webkitFullscreenEnabled', {
                            get: () => true, configurable: true
                        });
                    })();
                """)
            loop_task = asyncio.create_task(screenshot_loop())
            return {"ok": True, "frame_path": FRAME_PATH}

        if context is None or page is None:
            return {"error": "not initialized — send init first"}

        if cmd == "navigate":
            url = params["url"]
            if not url.startswith(("http://", "https://", "file://")):
                url = "https://" + url
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            return {"ok": True}

        if cmd == "click":
            await page.mouse.click(params["x"], params["y"])
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=5000)
            except Exception:
                pass
            return {"ok": True}

        if cmd == "mousedown":
            await page.mouse.move(params["x"], params["y"])
            await page.mouse.down()
            return {"ok": True}

        if cmd == "mouseup":
            await page.mouse.move(params["x"], params["y"])
            await page.mouse.up()
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=5000)
            except Exception:
                pass
            return {"ok": True}


        if cmd == "mousemove":
            await page.mouse.move(params["x"], params["y"])
            return {"ok": True}

        if cmd == "type":
            await page.keyboard.type(params["text"])
            return {"ok": True}

        if cmd == "key":
            await page.keyboard.press(params["key"])
            try:
                await page.wait_for_load_state("domcontentloaded", timeout=2000)
            except Exception:
                pass
            return {"ok": True}

        if cmd == "scroll":
            delta_x = params.get("delta_x", 0)
            delta_y = params.get("delta_y", 0)
            behavior = params.get("behavior", "instant")
            await page.evaluate(
                f"window.scrollBy({{left: {delta_x}, top: {delta_y}, behavior: '{behavior}'}})"
            )
            return {"ok": True}

        if cmd == "back":
            await page.go_back(wait_until="domcontentloaded", timeout=5000)
            return {"ok": True}

        if cmd == "forward":
            await page.go_forward(wait_until="domcontentloaded", timeout=5000)
            return {"ok": True}

        if cmd == "refresh":
            await page.reload(wait_until="domcontentloaded", timeout=10000)
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
                return {"ok": True}
            return {"error": f"tab index out of range: {idx}"}

        if cmd == "resize":
            w, h = params["width"], params["height"]
            await page.set_viewport_size({"width": w, "height": h})
            return {"ok": True}

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
        line = line.decode("utf-8").strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            emit({"error": f"invalid JSON: {e}"})
            continue

        cmd = msg.get("cmd", "")
        params = {k: v for k, v in msg.items() if k != "cmd"}

        try:
            resp = await handle(cmd, params)
        except Exception as e:
            resp = {"error": str(e)}

        if resp is None:
            break

        emit(resp)


if __name__ == "__main__":
    asyncio.run(main())
