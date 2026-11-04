#!/usr/bin/env python3
"""embr daemon: headless Chromium controlled via JSON over stdin/stdout."""

import asyncio
import base64
import json
import os
import shutil
import signal
import struct
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

_INCOGNITO = os.environ.get("EMBR_INCOGNITO") == "1"
_ENGINE = os.environ.get("EMBR_ENGINE", "cloakbrowser")
if _ENGINE not in ("cloakbrowser", "chromium"):
    print(f"embr: unknown EMBR_ENGINE={_ENGINE!r}, falling back to cloakbrowser",
          file=sys.stderr)
    _ENGINE = "cloakbrowser"
# Private per-daemon runtime directory (mode 0700) for the frame file and
# the canvas socket.  A fixed world-readable path in /tmp would expose page
# frames to other local users, let two daemons clobber each other, and be
# open to symlink attacks; Emacs learns the actual paths from the init
# response.  Removed again by shutdown().
RUNTIME_DIR = tempfile.mkdtemp(
    prefix="embr-incognito-" if _INCOGNITO else "embr-")
FRAME_PATH = os.path.join(RUNTIME_DIR, "frame.jpg")
FRAME_TMP_PATH = FRAME_PATH + ".tmp"
PERF_LOG_PATH = os.path.join(
    tempfile.gettempdir(),
    "embr-incognito-perf.jsonl" if _INCOGNITO else "embr-perf.jsonl")
SCRIPT_DIR = Path(__file__).resolve().parent
# Same location setup.sh and embr.el use ($XDG_DATA_HOME/embr).
DATA_DIR = Path(
    os.environ.get("XDG_DATA_HOME")
    or (Path.home() / ".local" / "share")) / "embr"
BLOCKLIST_PATH = DATA_DIR / "blocklist.txt"
# Drop canvas frames once this much data is queued on the socket: Emacs
# has fallen behind and only the latest frame matters.
FRAME_SOCKET_MAX_BUFFER = 4 * 1024 * 1024
# URL schemes accepted verbatim; anything else gets https:// prepended.
URL_SCHEMES = ("http://", "https://", "file://", "about:", "chrome://",
               "chrome-extension://", "data:", "view-source:", "blob:")
# Per-command timeouts (seconds).  First launch may download or compile.
CMD_TIMEOUT_S = 35
INIT_TIMEOUT_S = 120


class PerfLog:
    """Lightweight JSONL performance logger.  No-op when disabled."""

    SCHEMA_VERSION = 2
    INTERACTIVE_CMDS = {
        "mousemove", "click", "mousedown", "mouseup", "key", "type", "scroll",
    }

    def __init__(self):
        self.enabled = False
        self.cmd_id = 0
        self.frame_id = 0
        self.last_frame_emit_ts = None
        self.last_interactive_input_ts = None
        self.source = "unknown"
        self._file = None

    def enable(self):
        try:
            # O_NOFOLLOW: never write through a symlink planted at the
            # well-known path in the shared temp directory.
            fd = os.open(PERF_LOG_PATH,
                         os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                         0o600)
            self._file = os.fdopen(fd, "w", buffering=1)
        except OSError as e:
            print(f"embr: perf log disabled ({e})", file=sys.stderr)
            return
        self.enabled = True

    def log(self, event, **fields):
        if not self.enabled:
            return
        fields["event"] = event
        fields["schema_version"] = self.SCHEMA_VERSION
        fields["event_version"] = 1
        fields["frame_source"] = self.source
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


def _generate_pac(rules):
    """Generate a PAC script from a list of proxy routing rules."""
    lines = ["function FindProxyForURL(url, host) {"]
    catch_all = None
    for r in rules:
        suffix = r["suffix"]
        ptype = r["type"].upper()
        if ptype == "HTTP":
            ptype = "PROXY"
        addr = r["address"]
        if suffix == "*":
            catch_all = f"{ptype} {addr}"
            continue
        lines.append(
            f'  if (dnsDomainIs(host, "{suffix}")) return "{ptype} {addr}";')
    if catch_all:
        lines.append(f'  return "{catch_all}";')
    else:
        lines.append('  return "DIRECT";')
    lines.append("}")
    return "\n".join(lines)


def _install_proxy_extension(rules, data_dir):
    """Generate a Chrome proxy extension from routing rules.

    Uses chrome.proxy API instead of --proxy-pac-url so that SOCKS5
    proxies handle DNS resolution (required for .onion, .i2p)."""
    import json as _json
    ext_dir = Path(data_dir) / "extensions" / "embr-proxy"
    ext_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "manifest_version": 3,
        "name": "embr-proxy",
        "version": "1.0",
        "permissions": ["proxy"],
        "background": {"service_worker": "background.js"},
    }
    pac_script = _generate_pac(rules)
    background_js = (
        "chrome.proxy.settings.set({\n"
        "  value: {\n"
        "    mode: 'pac_script',\n"
        f"    pacScript: {{ data: {_json.dumps(pac_script)} }}\n"
        "  },\n"
        "  scope: 'regular'\n"
        "});\n"
    )
    (ext_dir / "manifest.json").write_text(_json.dumps(manifest, indent=2))
    (ext_dir / "background.js").write_text(background_js)


def _normalize_url(url):
    """Return URL with a scheme, defaulting to https:// for bare hosts."""
    if not isinstance(url, str):
        raise ValueError(f"url must be a string, got {type(url).__name__}")
    url = url.strip()
    if not url:
        return "about:blank"
    if not url.startswith(URL_SCHEMES):
        url = "https://" + url
    return url


def _write_frame_file(jpg_bytes):
    """Write JPEG bytes to FRAME_PATH atomically (write tmp, then rename)."""
    with open(FRAME_TMP_PATH, "wb") as f:
        f.write(jpg_bytes)
    os.replace(FRAME_TMP_PATH, FRAME_PATH)


async def main():
    from playwright.async_api import async_playwright
    if _ENGINE == "cloakbrowser":
        from cloakbrowser.download import ensure_binary
        from cloakbrowser.config import IGNORE_DEFAULT_ARGS, get_default_stealth_args
    pw = await async_playwright().start()
    perf = PerfLog()
    context = None
    page = None
    loop_task = None
    metadata_task = None
    running = True
    shutdown_done = False
    stdout_closed = False      # set when Emacs closed our stdout
    download_expected = False  # True only during C-c d flow
    target_fps = 30
    jpeg_quality = 80
    cached_title = ""
    _last_nav_url = None
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

    # Screencast state.
    frame_source = "screencast"
    cdp_session = None
    screencast_active = False
    screencast_errors = 0
    SCREENCAST_MAX_ERRORS = 5
    title_refresh_task = None
    _last_screencast_frame_ts = 0.0
    _pending_frame_data = None
    _ack_ok_count = 0
    _ack_ok_logged = 0

    # Canvas stream state.
    render_backend = "default"
    frame_socket_path = None
    frame_socket_server = None
    frame_socket_writer = None
    frame_seq = 0
    stream_id = 0

    data_dir = DATA_DIR
    _incognito_tmpdir = None
    if _INCOGNITO:
        _incognito_tmpdir = tempfile.mkdtemp(prefix="embr-incognito-")
        user_data_dir = Path(_incognito_tmpdir)
        print(f"embr: incognito profile at {user_data_dir}", file=sys.stderr)
    elif _ENGINE == "chromium":
        user_data_dir = data_dir / "playwright-profile"
    else:
        user_data_dir = data_dir / "chromium-profile"
    user_data_dir.mkdir(parents=True, exist_ok=True)

    # Extensions (downloaded by setup.sh --ublock / --darkreader).
    _ext_dirs = []
    ublock_dir = data_dir / "extensions" / "ublock" / "uBlock0.chromium"
    if ublock_dir.is_dir():
        _ext_dirs.append(str(ublock_dir))
        print(f"embr: uBlock Origin loaded from {ublock_dir}", file=sys.stderr)
    darkreader_dir = data_dir / "extensions" / "darkreader"
    if darkreader_dir.is_dir():
        _ext_dirs.append(str(darkreader_dir))
        print(f"embr: Dark Reader loaded from {darkreader_dir}", file=sys.stderr)
    _ext_args = [f"--load-extension={','.join(_ext_dirs)}"] if _ext_dirs else []

    # Display mode: headless (default), headed (real display),
    # headed-offscreen (virtual display via xvfb-run).
    _display_mode = os.environ.get("EMBR_DISPLAY", "headless")
    _use_headless = _display_mode == "headless"
    if _display_mode == "headed-offscreen":
        os.environ.pop("WAYLAND_DISPLAY", None)
        os.environ["GDK_BACKEND"] = "x11"
    print(f"embr: engine={_ENGINE} display={_display_mode}", file=sys.stderr)

    def emit(obj):
        """Write one JSON line to Emacs.

        A broken pipe means Emacs is gone; remember that so the main
        loop shuts the browser down instead of dying with a traceback.
        """
        nonlocal stdout_closed
        if stdout_closed:
            return
        try:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError, ValueError):
            stdout_closed = True

    emit_frame = emit

    async def write_frame():
        """Take a JPEG screenshot, write atomically to disk, notify Emacs."""
        nonlocal frame_count, capture_ema
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
        if render_backend == "canvas":
            send_frame_to_socket(
                jpg_bytes,
                page.viewport_size["width"],
                page.viewport_size["height"])
        else:
            _write_frame_file(jpg_bytes)
        frame_count += 1
        capture_done_mono_ms = round(t_capture_done * 1000, 2)
        emit_frame({"frame": True, "url": page.url,
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
        nonlocal mode, stable_frames, adapt_cooldown
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

                start = time.monotonic()
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

                elapsed = time.monotonic() - start
                await asyncio.sleep(max(0, (1 / target_fps) - elapsed))
            else:
                await asyncio.sleep(0.05)

    # ── Canvas frame socket ─────────────────────────────────────────

    async def start_frame_socket():
        """Create a UNIX socket server for canvas frame delivery."""
        nonlocal frame_socket_path, frame_socket_server
        frame_socket_path = os.path.join(RUNTIME_DIR, "canvas.sock")
        try:
            os.unlink(frame_socket_path)
        except OSError:
            pass

        async def on_connect(reader, writer):
            nonlocal frame_socket_writer
            old = frame_socket_writer
            frame_socket_writer = writer
            if old is not None and old is not writer:
                try:
                    old.close()
                except Exception:
                    pass
            print("embr: canvas socket connected", file=sys.stderr)

        frame_socket_server = await asyncio.start_unix_server(
            on_connect, path=frame_socket_path)
        print(f"embr: canvas socket at {frame_socket_path}", file=sys.stderr)

    def send_frame_to_socket(jpg_bytes, width, height):
        """Write a length-prefixed JPEG frame packet to the canvas socket."""
        nonlocal frame_seq
        if frame_socket_writer is None:
            return
        transport = frame_socket_writer.transport
        if transport.is_closing():
            return
        # Backpressure: when Emacs has fallen behind, drop this frame
        # instead of queueing it.  Latest wins, and an unbounded queue
        # would only grow memory and add latency.
        if transport.get_write_buffer_size() > FRAME_SOCKET_MAX_BUFFER:
            perf.log("frame_drop", reason="socket_backpressure",
                     frame_id=perf.frame_id + 1)
            return
        frame_seq = (frame_seq + 1) & 0xFFFFFFFF
        header = struct.pack('<IIIII', frame_seq, width, height,
                             len(jpg_bytes), stream_id)
        try:
            # The transport flushes on its own; no per-frame drain task.
            frame_socket_writer.write(header + jpg_bytes)
        except Exception as e:
            print(f"embr: canvas socket write error: {e}", file=sys.stderr)

    async def stop_frame_socket():
        """Close the canvas frame socket."""
        nonlocal frame_socket_server, frame_socket_writer, frame_socket_path
        if frame_socket_writer:
            try:
                frame_socket_writer.close()
            except Exception:
                pass
            frame_socket_writer = None
        if frame_socket_server:
            frame_socket_server.close()
            frame_socket_server = None
        if frame_socket_path:
            try:
                os.unlink(frame_socket_path)
            except OSError:
                pass
            frame_socket_path = None

    # ── Screencast transport ───────────────────────────────────────

    async def start_screencast():
        """Open a CDP session on the current page and start screencast."""
        nonlocal cdp_session, screencast_active, screencast_errors
        nonlocal _last_screencast_frame_ts
        nonlocal _pending_frame_data, _ack_ok_count, _ack_ok_logged
        nonlocal stream_id
        next_stream_id = stream_id + 1
        try:
            cdp_session = await page.context.new_cdp_session(page)
            await cdp_session.send("Page.enable")
            every_nth = max(1, round(60 / target_fps))
            cdp_session.on("Page.screencastFrame", on_screencast_frame)
            await cdp_session.send("Page.startScreencast", {
                "format": "jpeg",
                "quality": jpeg_quality,
                "maxWidth": page.viewport_size["width"],
                "maxHeight": page.viewport_size["height"],
                "everyNthFrame": every_nth,
            })
            screencast_active = True
            screencast_errors = 0
            _ack_ok_count = 0
            _ack_ok_logged = 0
            _pending_frame_data = None
            _last_screencast_frame_ts = time.monotonic()
            stream_id = next_stream_id
            start_title_refresh()
            print("embr: frame_source=screencast", file=sys.stderr)
        except Exception as e:
            screencast_active = False
            if cdp_session:
                try:
                    await cdp_session.detach()
                except Exception:
                    pass
            cdp_session = None
            raise RuntimeError(f"screencast start failed: {e}") from e

    def _check_screencast_threshold():
        """Log screencast errors.  No automatic fallback."""
        if screencast_errors >= SCREENCAST_MAX_ERRORS:
            print(f"embr: screencast errors: {screencast_errors}",
                  file=sys.stderr)

    def _on_ack_done(fut):
        """Done callback for screencast frame ack futures."""
        nonlocal screencast_errors, _ack_ok_count
        if fut.cancelled():
            return
        exc = fut.exception()
        if not exc:
            _ack_ok_count += 1
            return
        # Ignore ack failures from intentionally stopped sessions
        # (tab switch, quit, etc.) to avoid false threshold trips.
        if not screencast_active:
            return
        screencast_errors += 1
        perf.log("screencast_ack_error", error=str(exc),
                 error_count=screencast_errors)
        print(f"embr: screencast ack error: {exc}", file=sys.stderr)
        _check_screencast_threshold()

    def _flush_pending_frame(now):
        """Decode+write+emit the latest buffered screencast frame."""
        nonlocal _pending_frame_data
        if _pending_frame_data is None:
            return
        jpg_bytes = base64.b64decode(_pending_frame_data)
        _pending_frame_data = None
        if render_backend == "canvas":
            send_frame_to_socket(
                jpg_bytes,
                page.viewport_size["width"],
                page.viewport_size["height"])
        else:
            _write_frame_file(jpg_bytes)
        fid = perf.next_frame_id()
        capture_done_mono_ms = round(now * 1000, 2)
        emit_frame({"frame": True, "url": page.url,
                    # Pressure only while an input-priority window is
                    # open, not for the rest of the session (see
                    # on_screencast_frame for the mode reset).
                    "pressure": now < input_priority_until,
                    "frame_id": fid,
                    "capture_done_mono_ms": capture_done_mono_ms})
        # Perf logging (symmetric with write_frame).
        emit_fields = dict(frame_id=fid, mode="screencast",
                           jpeg_quality=jpeg_quality,
                           bytes=len(jpg_bytes),
                           ack_ok=_ack_ok_count,
                           ack_errors=screencast_errors)
        if perf.last_frame_emit_ts is not None:
            emit_fields["interval_ms"] = round(
                (now - perf.last_frame_emit_ts) * 1000, 2)
        if perf.last_interactive_input_ts is not None:
            emit_fields["input_to_frame_ms"] = round(
                (now - perf.last_interactive_input_ts) * 1000, 2)
            perf.last_interactive_input_ts = None
        perf.log("frame_emit", **emit_fields)
        perf.last_frame_emit_ts = now
        # Batched ack-ok event (one per flush cycle, not per ack).
        nonlocal _ack_ok_logged
        ok_since = _ack_ok_count - _ack_ok_logged
        if ok_since > 0:
            perf.log("screencast_ack_ok", count=ok_since)
            _ack_ok_logged = _ack_ok_count

    def on_screencast_frame(params):
        """Handle a pushed screencast frame from the browser.

        Acks CDP immediately.  Buffers raw frame data (queue depth 1,
        latest wins).  Only decodes+writes+emits at frame budget
        intervals; intermediate frames are discarded unprocessed.
        """
        nonlocal frame_count, screencast_errors, mode
        nonlocal _last_screencast_frame_ts, _pending_frame_data
        try:
            frame_count += 1
            _last_screencast_frame_ts = time.monotonic()
            # Ack immediately so CDP backpressure stays healthy.
            if cdp_session:
                fut = asyncio.ensure_future(
                    cdp_session.send("Page.screencastFrameAck",
                                     {"sessionId": params["sessionId"]}))
                fut.add_done_callback(_on_ack_done)
            # Buffer raw data (latest wins, previous discarded).
            _pending_frame_data = params["data"]
            now = time.monotonic()
            # The screenshot loop is what flips the scheduler back to
            # "watch"; without it the session would stay "interactive"
            # (and Emacs would keep its hover rate throttled) forever
            # after the first key press.
            if mode != "watch" and now >= input_priority_until:
                perf.log("mode_change", old_mode=mode, new_mode="watch")
                mode = "watch"
            # Throttle: only decode+write+emit at frame budget intervals.
            if perf.last_frame_emit_ts is not None:
                if (now - perf.last_frame_emit_ts) < (1.0 / target_fps):
                    perf.log("frame_drop", reason="screencast_throttle",
                             frame_id=perf.frame_id + 1)
                    return
            _flush_pending_frame(now)
        except Exception as e:
            screencast_errors += 1
            print(f"embr: screencast frame error: {e}", file=sys.stderr)
            _check_screencast_threshold()

    async def stop_screencast():
        """Stop screencast and detach CDP session.  Idempotent.

        Sets screencast_active = False immediately (before any awaits)
        so in-flight ack callbacks see the stopped state and skip error
        counting.
        """
        nonlocal cdp_session, screencast_active, title_refresh_task
        was_active = screencast_active
        screencast_active = False
        if title_refresh_task and not title_refresh_task.done():
            title_refresh_task.cancel()
            title_refresh_task = None
        if cdp_session:
            try:
                if was_active:
                    await cdp_session.send("Page.stopScreencast")
                await cdp_session.detach()
            except Exception:
                pass
            cdp_session = None

    def start_title_refresh():
        """Start async task to flush buffered frames periodically."""
        nonlocal title_refresh_task

        async def _refresh():
            while screencast_active:
                # Flush any buffered frame that hasn't been emitted.
                if _pending_frame_data is not None:
                    _flush_pending_frame(time.monotonic())
                await asyncio.sleep(0.5)

        title_refresh_task = asyncio.create_task(_refresh())

    async def _tab_list():
        """Build the tab list for inclusion in responses."""
        tabs = []
        for i, p in enumerate(context.pages):
            try:
                t = await p.title()
            except Exception:
                t = ""
            tabs.append({"index": i, "title": t, "url": p.url,
                         "active": p is page})
        return tabs

    def _on_page_crash(crashed_page=None):
        """Log a page crash and tell Emacs when it is the active tab."""
        if crashed_page is not None and crashed_page is not page:
            print("embr: background tab crashed (ignored)", file=sys.stderr)
            return
        print("embr: active page crashed", file=sys.stderr)
        emit({"notice": "page crashed; reload to recover"})

    def _on_page_close(closed_page=None):
        """Adopt another tab when the active page is closed by the site.

        Emacs-initiated close-tab reassigns `page' before closing, so
        this only fires for window.close(), finished popups and the like.
        """
        if closed_page is page and running:
            asyncio.ensure_future(_recover_active_page())

    def _on_page_load(loaded_page=None):
        """Re-apply per-session page state (zoom, mute) after a load.

        Both live on the document and would otherwise silently reset on
        every navigation while Emacs still shows them as active.
        """
        if loaded_page is not page:
            return
        js = []
        if zoom_level != 1.0:
            js.append(f"document.body.style.zoom = '{zoom_level}';")
        if muted:
            js.append("document.querySelectorAll('video,audio')"
                      ".forEach(e => e.muted = true);")
        if js:
            asyncio.ensure_future(
                _safe_evaluate(loaded_page, "() => {" + " ".join(js) + "}"))

    async def _safe_evaluate(p, expr):
        """Evaluate EXPR on page P, ignoring navigation/closed errors."""
        try:
            return await p.evaluate(expr)
        except Exception:
            return None

    def _attach_page_handlers(p):
        """Attach lifecycle handlers to page P (existing or future)."""
        p.on("crash", _on_page_crash)
        p.on("close", _on_page_close)
        p.on("domcontentloaded", _on_page_load)

    async def _recover_active_page():
        """Make some live tab active after the active one disappeared."""
        nonlocal page, cached_title
        if not running or context is None:
            return
        live = [p for p in context.pages if not p.is_closed()]
        if page in live:
            return
        if screencast_active:
            await stop_screencast()
        page = live[-1] if live else await context.new_page()
        try:
            await page.bring_to_front()
        except Exception:
            pass
        err = await _restart_screencast_after_tab_change()
        if err:
            print(f"embr: {err['error']}", file=sys.stderr)
        try:
            cached_title = await page.title()
        except Exception:
            cached_title = ""
        emit({"metadata": True, "url": page.url, "title": cached_title,
              "tabs": await _tab_list()})

    async def _restart_screencast_after_tab_change():
        """Restart screencast on new active page after tab operation.
        Return error dict in forced mode on failure, None otherwise."""
        if frame_source == "screenshot" or loop_task:
            return None
        try:
            await start_screencast()
            return None
        except Exception as e:
            return {"error": f"screencast restart failed: {e}"}

    # ── Mouse handling ──────────────────────────────────────────────
    # Clicks use page.evaluate() (Runtime domain) — never contends
    # with the screenshot loop's Page.captureScreenshot traffic.
    # Mousemove uses CDP page.mouse.move() for isTrusted=true (CSS
    # :hover), as fire-and-forget with cancel-and-replace so it can
    # never block anything.
    mouse_move_task = None
    zoom_level = 1.0
    muted = False

    _CLICK_JS = """([x, y]) => {
        const el = document.elementFromPoint(x, y);
        if (!el) return;
        const opts = {bubbles: true, cancelable: true, view: window,
                      clientX: x, clientY: y, button: 0};
        for (const t of ['pointerdown','mousedown','pointerup','mouseup','click'])
            el.dispatchEvent(new MouseEvent(t, opts));
        el.focus();
    }"""

    async def shutdown():
        """Stop capture, close the browser and remove runtime files.

        Idempotent.  Besides the quit command this also runs when Emacs
        disappears without sending quit (stdin EOF, broken stdout), so
        the profile is flushed to disk and the incognito profile and the
        runtime directory are wiped either way.
        """
        nonlocal running, loop_task, metadata_task, context, shutdown_done
        if shutdown_done:
            return
        shutdown_done = True
        running = False
        if screencast_active:
            await stop_screencast()
        for task in (loop_task, metadata_task):
            if task and not task.done():
                task.cancel()
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    pass
        loop_task = None
        metadata_task = None
        await stop_frame_socket()
        if context:
            try:
                await asyncio.wait_for(context.close(), timeout=15)
            except Exception as e:
                print(f"embr: browser close failed: {e}", file=sys.stderr)
            context = None
        try:
            await asyncio.wait_for(pw.stop(), timeout=15)
        except Exception as e:
            print(f"embr: playwright stop failed: {e}", file=sys.stderr)
        perf.close()
        shutil.rmtree(RUNTIME_DIR, ignore_errors=True)
        if _INCOGNITO and _incognito_tmpdir:
            shutil.rmtree(_incognito_tmpdir, ignore_errors=True)
            print("embr: incognito profile wiped", file=sys.stderr)

    async def handle(cmd, params):
        nonlocal context, page, loop_task, target_fps, jpeg_quality, cached_title
        nonlocal input_priority_window_s, frame_source, render_backend
        nonlocal adaptive_enabled, fps_min, fps_max, quality_min, quality_max
        nonlocal zoom_level, muted, mouse_move_task, download_expected
        nonlocal last_rendered_frame_id, metadata_task

        if cmd == "init":
            # Validate frame_source and render_backend before any heavy work.
            frame_source = params.get("frame_source", "screencast")
            if frame_source not in ("screenshot", "screencast"):
                return {"error": f"invalid frame_source: {frame_source!r}"}
            render_backend = params.get("render_backend", "default")
            if render_backend not in ("default", "canvas"):
                return {"error": f"invalid render_backend: {render_backend!r}"}
            if params.get("perf_log"):
                perf.enable()
            width = params.get("width", 1280)
            height = params.get("height", 720)
            sw = params.get("screen_width", 1920)
            sh = params.get("screen_height", 1080)
            if _ENGINE == "cloakbrowser":
                binary_path = ensure_binary()
                chrome_args = get_default_stealth_args() + _ext_args
                if _display_mode == "headed-offscreen":
                    chrome_args.append("--ozone-platform=x11")
                context_opts = dict(
                    user_data_dir=str(user_data_dir),
                    executable_path=binary_path,
                    headless=_use_headless,
                    args=chrome_args,
                    ignore_default_args=IGNORE_DEFAULT_ARGS + [
                        "--mute-audio", "--disable-extensions",
                    ],
                    viewport={"width": width, "height": height},
                    screen={"width": sw, "height": sh},
                    accept_downloads=True,
                )
            else:
                chrome_args = list(_ext_args)
                if _display_mode == "headed-offscreen":
                    chrome_args.append("--ozone-platform=x11")
                context_opts = dict(
                    user_data_dir=str(user_data_dir),
                    headless=_use_headless,
                    args=chrome_args,
                    ignore_default_args=[
                        "--mute-audio", "--disable-extensions",
                    ],
                    viewport={"width": width, "height": height},
                    screen={"width": sw, "height": sh},
                    accept_downloads=True,
                )
            color_scheme = params.get("color_scheme")
            if color_scheme:
                context_opts["color_scheme"] = color_scheme
            proxy_rules = params.get("proxy_rules")
            if proxy_rules:
                _install_proxy_extension(proxy_rules, data_dir)
                proxy_ext = str(data_dir / "extensions" / "embr-proxy")
                for i, arg in enumerate(chrome_args):
                    if arg.startswith("--load-extension="):
                        chrome_args[i] = f"{arg},{proxy_ext}"
                        break
                else:
                    chrome_args.append(f"--load-extension={proxy_ext}")
                print(f"embr: proxy extension ({len(proxy_rules)} rules)",
                      file=sys.stderr)
            context = await pw.chromium.launch_persistent_context(**context_opts)
            # Attach lifecycle handlers to every page (existing and future).
            for p in context.pages:
                _attach_page_handlers(p)
            context.on("page", _attach_page_handlers)

            # Cancel unsolicited downloads (only C-c d sets download_expected).
            async def _on_download(download):
                if not download_expected:
                    await download.cancel()
            context.on("download", _on_download)
            # Ad blocking via request interception.
            blocked = load_blocklist()
            if blocked:
                host_cache = {}

                def is_blocked(host):
                    """Check host and all parent domains against blocklist."""
                    hit = host_cache.get(host)
                    if hit is None:
                        parts = host.split(".")
                        hit = any(".".join(parts[i:]) in blocked
                                  for i in range(len(parts)))
                        if len(host_cache) > 4096:
                            host_cache.clear()
                        host_cache[host] = hit
                    return hit

                async def block_ads(route):
                    host = urlparse(route.request.url).hostname or ""
                    try:
                        if is_blocked(host):
                            await route.abort()
                        else:
                            await route.continue_()
                    except Exception:
                        pass  # Request already gone (navigation aborted).
                await context.route("**/*", block_ads)
                print(f"embr: blocklist loaded ({len(blocked)} domains)",
                      file=sys.stderr)
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

            href_preview = params.get("href_preview", False)
            _LINK_STATUS_BODY = """
if (window.__embr_link_status) return;
window.__embr_link_status = true;
function embrStartLinkStatus() {
    var bar = document.createElement('div');
    bar.id = '__embr_link_status';
    bar.style.cssText = 'position:fixed;z-index:2147483647;bottom:0;left:0;max-width:80%;padding:2px 8px;font:12px/16px monospace;color:#ccc;background:rgba(30,30,30,0.85);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;pointer-events:none;display:none;border-top-right-radius:3px;';
    document.body.appendChild(bar);
    document.addEventListener('mouseover', function(e) {
        var a = e.target.closest('a[href]');
        if (a) {
            bar.textContent = a.href;
            bar.style.display = 'block';
        } else {
            bar.style.display = 'none';
        }
    }, true);
}
if (document.body) embrStartLinkStatus();
else document.addEventListener('DOMContentLoaded', embrStartLinkStatus);
"""
            if href_preview:
                await context.add_init_script(_LINK_STATUS_BODY)

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
            if href_preview:
                try:
                    await page.evaluate("() => {" + _LINK_STATUS_BODY + "}")
                except Exception:
                    pass

            # Poll URL/title and push changes to Emacs.
            async def _metadata_loop():
                nonlocal cached_title, _last_nav_url
                tick = 0
                # Cache background tab signatures for change detection.
                _bg_sigs = {}  # id(page) -> (url, title)
                while running:
                    p = page
                    if p is None or p.is_closed():
                        # Between a tab being closed and its successor
                        # being picked; never exit the loop for it, or
                        # Emacs would stop getting URL/title updates for
                        # the rest of the session.
                        await asyncio.sleep(0.5)
                        continue
                    try:
                        url = p.url
                        title = await p.title()
                    except Exception:
                        await asyncio.sleep(1)
                        continue
                    if p is not page:
                        continue  # Tab switched while awaiting.
                    changed = False
                    if url != _last_nav_url:
                        _last_nav_url = url
                        changed = True
                    if title != cached_title:
                        # An empty title is a real change too (about:blank
                        # after a titled page), otherwise the old title
                        # would stick to the new page.
                        cached_title = title
                        changed = True
                    # Every 4th tick (~2s), poll all tab titles so inactive
                    # tabs stay fresh in the Emacs tab bar.
                    tabs_payload = None
                    tick += 1
                    if tick % 4 == 0 and len(context.pages) > 1:
                        bg_changed = False
                        entries = []
                        for i, p in enumerate(context.pages):
                            try:
                                t = await p.title()
                            except Exception:
                                t = ""
                            entries.append({"index": i, "title": t,
                                            "url": p.url,
                                            "active": p is page})
                            if p is not page:
                                sig = (p.url, t)
                                if _bg_sigs.get(id(p)) != sig:
                                    _bg_sigs[id(p)] = sig
                                    bg_changed = True
                        if bg_changed:
                            tabs_payload = entries
                    if changed or tabs_payload is not None:
                        msg = {"metadata": True, "url": url,
                               "title": cached_title}
                        if tabs_payload is not None:
                            msg["tabs"] = tabs_payload
                        emit(msg)
                    await asyncio.sleep(0.5)

            metadata_task = asyncio.ensure_future(_metadata_loop())

            # Start frame capture (frame_source validated at top of init).
            active_source = frame_source
            if frame_source == "screenshot":
                loop_task = asyncio.create_task(screenshot_loop())
                print("embr: frame_source=screenshot", file=sys.stderr)
            elif frame_source == "screencast":
                try:
                    await start_screencast()
                except Exception:
                    # Tear down browser to prevent zombie state.
                    await context.close()
                    context = None
                    page = None
                    raise
            # Start canvas frame socket if requested.
            if render_backend == "canvas":
                await start_frame_socket()
                print("embr: render_backend=canvas", file=sys.stderr)
            else:
                print("embr: render_backend=default", file=sys.stderr)
            perf.source = active_source
            resp = {"ok": True, "frame_path": FRAME_PATH,
                    "frame_source": active_source,
                    "render_backend": render_backend,
                    "stream_id": stream_id}
            if frame_socket_path:
                resp["frame_socket_path"] = frame_socket_path
            return resp

        if context is None or page is None:
            return {"error": "not initialized — send init first"}

        if cmd == "navigate":
            url = _normalize_url(params.get("url", ""))
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=10000)
            except Exception:
                pass  # Timeout or nav error — page state visible via screenshots.
            return {"ok": True, "url": page.url}

        # Mousemove: fire-and-forget CDP (isTrusted=true for CSS :hover).
        # Cancel-and-replace — each new move cancels the previous.
        if cmd == "mousemove":
            # Drop hover during input-priority window.
            if time.monotonic() < input_priority_until:
                return {"ok": True}
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
            try:
                await page.evaluate(_CLICK_JS, [params["x"], params["y"]])
            except Exception:
                pass
            try:
                url = await page.evaluate("() => window.location.href")
            except Exception:
                url = page.url
            return {"ok": True, "url": url}
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
            return {"ok": True, "url": page.url}

        if cmd == "forward":
            try:
                await page.go_forward(wait_until="domcontentloaded", timeout=5000)
            except Exception:
                pass
            return {"ok": True, "url": page.url}

        if cmd == "refresh":
            try:
                await page.reload(wait_until="domcontentloaded", timeout=10000)
            except Exception:
                pass
            return {"ok": True, "url": page.url}

        if cmd == "resize":
            new_w = max(200, int(params.get("width", 200)))
            new_h = max(200, int(params.get("height", 200)))
            # Resize all pages so tab switches don't produce frames
            # at the old viewport size (stride mismatch → corruption).
            for p in context.pages:
                try:
                    await p.set_viewport_size({"width": new_w, "height": new_h})
                except Exception:
                    pass
            if screencast_active:
                await stop_screencast()
                try:
                    await start_screencast()
                except Exception as e:
                    return {"error": f"screencast restart failed: {e}",
                            "width": new_w, "height": new_h,
                            "stream_id": stream_id}
            return {"ok": True, "width": new_w, "height": new_h,
                    "stream_id": stream_id}

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
                    var href = el.closest('a[href]') ? el.closest('a[href]').href : null;
                    results.push({tag: tag, x: r.left + r.width/2, y: r.top + r.height/2, text: (el.textContent || el.value || '').trim().slice(0, 60), href: href});
                });
                return results;
            }""")
            return {"ok": True, "hints": hints}

        if cmd == "hints-clear":
            await page.evaluate("() => document.querySelectorAll('.embr-hint').forEach(e => e.remove())")
            return {"ok": True}

        if cmd == "link-at-point":
            x, y = params["x"], params["y"]
            href = await page.evaluate("""([x, y]) => {
                var el = document.elementFromPoint(x, y);
                if (!el) return null;
                var a = el.closest('a[href]');
                return a ? a.href : null;
            }""", [x, y])
            return {"ok": True, "href": href}

        if cmd == "download":
            url = params["url"]
            directory = params["directory"]
            try:
                download_expected = True
                async with page.expect_download(timeout=30000) as dl_info:
                    await page.evaluate("""(url) => {
                        var a = document.createElement('a');
                        a.href = url;
                        a.download = '';
                        a.style.display = 'none';
                        document.body.appendChild(a);
                        a.click();
                        a.remove();
                    }""", url)
                download = await dl_info.value
                # The suggested name comes from the server; never let it
                # escape the download directory.
                filename = os.path.basename(
                    download.suggested_filename or "") or "download"
                save_path = os.path.join(directory, filename)
                # Deduplicate filename if it already exists.
                base, ext = os.path.splitext(save_path)
                counter = 1
                while os.path.exists(save_path):
                    save_path = f"{base}({counter}){ext}"
                    counter += 1
                await download.save_as(save_path)
                return {"ok": True, "path": save_path, "filename": filename}
            except Exception as e:
                return {"error": f"download failed: {e}"}
            finally:
                download_expected = False

        if cmd == "text":
            text = await page.inner_text("body")
            return {"ok": True, "text": text}

        if cmd == "source":
            html = await page.content()
            return {"ok": True, "html": html}

        if cmd == "type-text":
            await page.keyboard.type(params["value"])
            return {"ok": True}

        if cmd == "overlay":
            text = params.get("text", "")
            show = params.get("show", True)
            await page.evaluate("""([text, show]) => {
                let el = document.getElementById('__embr_overlay');
                if (!show) { if (el) el.remove(); return; }
                if (!el) {
                    el = document.createElement('div');
                    el.id = '__embr_overlay';
                    el.style.cssText = 'position:fixed;z-index:2147483647;top:0;left:0;right:0;padding:18px;font:bold 22px/28px sans-serif;color:#fff;background:rgba(0,0,0,0.8);text-align:center;pointer-events:none;';
                    document.body.appendChild(el);
                }
                el.textContent = text;
            }""", [text, show])
            return {"ok": True}

        if cmd == "fill":
            await page.fill(params["selector"], params["value"])
            return {"ok": True}

        if cmd == "select":
            await page.select_option(params["selector"], params["value"])
            return {"ok": True}

        if cmd == "new-tab":
            url = _normalize_url(params.get("url", "about:blank"))
            # wait=false (session restore) opens the tab without waiting
            # for the load, so restoring many tabs is not serialized on
            # slow sites.
            wait = params.get("wait", True) is not False
            if screencast_active:
                await stop_screencast()
            # Capture current viewport before page changes.
            vp = page.viewport_size
            new_page = await context.new_page()
            # Match new tab to the current (possibly resized) viewport.
            if vp:
                try:
                    await new_page.set_viewport_size(vp)
                except Exception:
                    pass
            # Make the new tab active before navigating, so a failed or
            # slow load (DNS error, timeout) cannot leave the screencast
            # stopped with the old page still selected.
            page = new_page
            if url != "about:blank":
                nav = new_page.goto(url, wait_until="domcontentloaded",
                                    timeout=15000)
                if wait:
                    try:
                        await nav
                    except Exception:
                        pass  # Nav error; page state visible via frames.
                else:
                    async def _bg_goto(coro):
                        try:
                            await coro
                        except Exception:
                            pass
                    asyncio.ensure_future(_bg_goto(nav))
            err = await _restart_screencast_after_tab_change()
            if err:
                return err
            try:
                cached_title = await page.title()
            except Exception:
                pass
            return {"ok": True, "tab_index": context.pages.index(page),
                    "url": page.url, "title": cached_title,
                    "stream_id": stream_id,
                    "tabs": await _tab_list()}

        if cmd == "close-tab":
            if len(context.pages) <= 1:
                return {"last_tab": True}
            target_idx = params.get("index")
            target = (context.pages[target_idx]
                      if isinstance(target_idx, int)
                      and 0 <= target_idx < len(context.pages)
                      else page)
            was_active = target is page
            if was_active:
                if screencast_active:
                    await stop_screencast()
                # Pick the successor before closing, so neither the
                # metadata loop nor the close handler ever sees a closed
                # active page.  Like a browser, activate the neighbour
                # that takes the closed tab's place (or the new last).
                remaining = [p for p in context.pages if p is not target]
                page = remaining[min(context.pages.index(target),
                                     len(remaining) - 1)]
            await target.close()
            if was_active:
                await page.bring_to_front()
                err = await _restart_screencast_after_tab_change()
                if err:
                    return err
            try:
                cached_title = await page.title()
            except Exception:
                pass
            return {"ok": True,
                    "tab_index": (context.pages.index(page)
                                  if page in context.pages else 0),
                    "url": page.url, "title": cached_title,
                    "stream_id": stream_id,
                    "tabs": await _tab_list()}

        if cmd == "list-tabs":
            return {"ok": True, "tabs": await _tab_list()}

        if cmd == "switch-tab":
            idx = params.get("index")
            if isinstance(idx, int) and 0 <= idx < len(context.pages):
                if screencast_active:
                    await stop_screencast()
                page = context.pages[idx]
                await page.bring_to_front()
                err = await _restart_screencast_after_tab_change()
                if err:
                    return err
                try:
                    cached_title = await page.title()
                except Exception:
                    pass
                return {"ok": True, "url": page.url, "title": cached_title,
                        "stream_id": stream_id,
                        "tabs": await _tab_list()}
            return {"error": f"tab index out of range: {idx}"}

        if cmd == "zoom-in":
            zoom_level = min(zoom_level + 0.1, 5.0)
            await page.evaluate(f"document.body.style.zoom = '{zoom_level}'")
            return {"ok": True, "zoom": round(zoom_level, 1)}

        if cmd == "zoom-out":
            zoom_level = max(zoom_level - 0.1, 0.3)
            await page.evaluate(f"document.body.style.zoom = '{zoom_level}'")
            return {"ok": True, "zoom": round(zoom_level, 1)}

        if cmd == "zoom-reset":
            zoom_level = 1.0
            await page.evaluate("document.body.style.zoom = '1'")
            return {"ok": True, "zoom": 1.0}

        if cmd == "print-pdf":
            if not _use_headless:
                return {"error": "print-pdf requires headless mode (page.pdf() is a headless-only API)"}
            directory = params.get("directory", str(Path.home()))
            try:
                title = await page.title() or "page"
                # Sanitize filename.
                safe = "".join(
                    c if c.isalnum() or c in " -_." else "_" for c in title
                ).strip()[:80] or "page"
                filename = f"{safe}.pdf"
                save_path = os.path.join(directory, filename)
                base, ext = os.path.splitext(save_path)
                counter = 1
                while os.path.exists(save_path):
                    save_path = f"{base}({counter}){ext}"
                    counter += 1
                pdf_bytes = await page.pdf()
                with open(save_path, "wb") as f:
                    f.write(pdf_bytes)
                return {"ok": True, "path": save_path}
            except Exception as e:
                return {"error": f"print-pdf failed: {e}"}

        if cmd == "screenshot":
            path = params.get("path", "")
            full_page = params.get("full_page", False)
            try:
                await page.screenshot(
                    path=path, type="png", full_page=full_page)
                return {"ok": True, "path": path}
            except Exception as e:
                return {"error": f"screenshot failed: {e}"}

        if cmd == "toggle-mute":
            muted = not muted
            js = (
                "document.querySelectorAll('video,audio')"
                f".forEach(e => e.muted = {'true' if muted else 'false'})"
            )
            await page.evaluate(js)
            return {"ok": True, "muted": muted}

        if cmd == "reader":
            try:
                data = await page.evaluate("""() => {
                    // Try <article>, then <main>, then largest text block.
                    function getContent() {
                        var article = document.querySelector('article');
                        if (article) return article;
                        var main = document.querySelector('main');
                        if (main) return main;
                        // Fallback: largest text-containing block.
                        var blocks = document.querySelectorAll('div, section');
                        var best = null, bestLen = 0;
                        blocks.forEach(function(b) {
                            var len = b.innerText ? b.innerText.length : 0;
                            if (len > bestLen) { bestLen = len; best = b; }
                        });
                        return best || document.body;
                    }
                    var content = getContent();
                    // Strip nav, header, footer, sidebar, ads.
                    var clone = content.cloneNode(true);
                    var remove = 'nav, header, footer, aside, [role="navigation"], [role="banner"], [role="contentinfo"], .sidebar, .ad, .ads, .advertisement';
                    clone.querySelectorAll(remove).forEach(function(e) { e.remove(); });
                    return {
                        title: document.title || '',
                        byline: (document.querySelector('meta[name="author"]') || {}).content || '',
                        excerpt: (document.querySelector('meta[name="description"]') || {}).content || (clone.innerText || '').substring(0, 200),
                        html: clone.innerHTML,
                        text: clone.innerText || ''
                    };
                }""")
                return {"ok": True, "reader": data}
            except Exception as e:
                return {"error": f"reader failed: {e}"}

        if cmd == "page-info":
            try:
                info = await page.evaluate("""() => {
                    return {
                        url: window.location.href,
                        title: document.title,
                        protocol: window.location.protocol,
                        domain: window.location.hostname,
                        page_height: document.documentElement.scrollHeight,
                        page_width: document.documentElement.scrollWidth,
                        scripts: document.querySelectorAll('script').length,
                        stylesheets: document.querySelectorAll('link[rel="stylesheet"]').length,
                        images: document.querySelectorAll('img').length,
                        iframes: document.querySelectorAll('iframe').length
                    };
                }""")
                # Add cookie count from context.
                cookies = await context.cookies()
                domain = info.get("domain", "")
                domain_cookies = [
                    c for c in cookies
                    if domain and c.get("domain", "").endswith(domain)]
                info["cookies"] = len(domain_cookies)
                # Content-Type via CDP resource tree.
                content_type = ""
                try:
                    cdp = await page.context.new_cdp_session(page)
                    tree = await cdp.send("Page.getResourceTree")
                    content_type = tree["frameTree"]["frame"].get(
                        "mimeType", "")
                    await cdp.detach()
                except Exception:
                    pass
                info["content_type"] = content_type
                return {"ok": True, "info": info}
            except Exception as e:
                return {"error": f"page-info failed: {e}"}

        if cmd == "query-url":
            try:
                url = await page.evaluate("() => window.location.href")
            except Exception:
                url = page.url
            try:
                cached_title = await page.title()
            except Exception:
                pass
            return {"ok": True, "url": url, "title": cached_title}

        if cmd == "quit":
            await shutdown()
            return None  # signals exit

        return {"error": f"unknown command: {cmd}"}

    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    loop = asyncio.get_running_loop()
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    # Emacs hangs up on its subprocesses when it exits, and a terminal
    # or service manager sends SIGTERM.  Treat both like end of input
    # so the browser is closed and runtime files removed instead of
    # dying mid-flight.
    for sig in (signal.SIGHUP, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, reader.feed_eof)
        except (NotImplementedError, RuntimeError, ValueError):
            pass

    while not stdout_closed:
        line = await reader.readline()
        if not line:
            break  # Emacs closed the pipe (killed, or quit without "quit").

        # Batch-read: collect this line plus any already buffered.
        pending = [line]
        while b'\n' in getattr(reader, "_buffer", b""):
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
            if not isinstance(msg, dict):
                emit({"error": "invalid command: expected a JSON object"})
                continue
            cmd = msg.get("cmd", "")
            # Optional request id, echoed in the response so Emacs can
            # match it to the right callback even when fire-and-forget
            # traffic (hover, resize, frame acks) is interleaved.
            rid = msg.get("id")
            params = {k: v for k, v in msg.items() if k not in ("cmd", "id")}
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
                resp = await asyncio.wait_for(
                    handle(cmd, params),
                    timeout=INIT_TIMEOUT_S if cmd == "init" else CMD_TIMEOUT_S)
            except asyncio.TimeoutError:
                resp = {"error": f"command timed out: {cmd}"}
            except Exception as e:
                resp = {"error": str(e)}
            if resp is None:
                should_exit = True
                break
            if rid is not None:
                resp["id"] = rid
            emit(resp)
            latency_ms = round((time.monotonic() - t0) * 1000, 2)
            perf.log("cmd_ack", cmd=cmd, cmd_id=cid, latency_ms=latency_ms)
        if should_exit:
            break

    # Reached after quit, on stdin EOF, or once stdout broke: close the
    # browser and remove runtime files whichever way we got here.
    await shutdown()


if __name__ == "__main__":
    asyncio.run(main())
