# canvasmacs

Emacs 31 (PGTK/Wayland) with the [canvas image patch](https://github.com/minad/emacs-canvas-patch) baked in.

## Using canvas with embr

Set `embr-render-backend` to `'canvas` to enable the native canvas render path. embr decodes JPEG frames directly into the canvas pixel buffer via a native C module, skipping the per-frame disk round-trip. Works without canvas too -- `'default` is the safe fallback for any Emacs build.

This is a minimal fork of the official Arch Linux `emacs-wayland` PKGBUILD.

## Build and install

```sh
cd canvasmacs
makepkg -si
```

`-s` installs missing dependencies (via pacman), `-i` installs the built package when done.

## Uninstall

```sh
sudo pacman -R emacs-canvas-wayland
```

## What the patch adds

New image type `:type canvas` with pixel buffer access via dynamic modules (`canvas_pixel`, `canvas_refresh`). See the [upstream bug](https://debbugs.gnu.org/cgi/bugreport.cgi?bug=80281) for details.

## embr benchmark: canvas vs default

Canvas decodes JPEG and writes pixels directly into the canvas buffer via a native C module, bypassing Emacs' `create-image` + `erase-buffer` + `insert-image` cycle.

| Metric | Canvas | Default |
|--------|--------|---------|
| Input-to-frame p50 | **10.0ms** | 14.4ms |
| Input-to-frame p95 | **28.4ms** | 44.8ms |
| Frame interval p50 | **28.9ms** | 29.5ms |
| Effective FPS | **34.6** | 33.9 |
| FPS 30+ bucket | **78.0%** | 79.5% |
| Drop ratio | **0.304** | 0.336 |
| Render skips | **0** | 20 |
| Freezes | 1 (1485ms) | 1 (2250ms) |
| Severe freezes | **0** | 1 |

Canvas wins on input latency (30-35% lower at p50/p95), zero render skips again, lower drop ratio, and no severe freezes. Both use screencast transport.

##### Why only ~30 effective FPS?

The bottleneck is 100% Chromium. The embr pipeline (Python + Emacs) adds 0.01ms per frame. All the time is spent waiting for Chromium to produce the next frame after we ack the previous one.

| Where | Time |
|-------|------|
| embr pipeline (emit to ack) | 0.01ms |
| Chromium (ack to next frame) | 28.9ms |

Frame interval distribution from the canvas benchmark:

| Interval | Count | % |
|----------|-------|---|
| <10ms | 0 | 0.0% |
| 10-17ms (60fps zone) | 83 | 10.0% |
| 17-25ms | 292 | 35.3% |
| 25-33ms (30fps zone) | 237 | 28.6% |
| 33-50ms | 162 | 19.6% |
| 50-100ms | 34 | 4.1% |
| 100ms+ | 20 | 2.4% |

CDP screencast is capped around 30-35 FPS by Chromium's compositor. Only 10% of frames land in the 60fps zone. To get 60fps you would need to bypass CDP screencast entirely with a different capture API.
