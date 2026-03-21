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

## embr benchmark: canvas vs legacy

Canvas decodes JPEG and writes pixels directly into the canvas buffer via a native C module, bypassing Emacs' `create-image` + `erase-buffer` + `insert-image` cycle.

| Metric | Canvas | Legacy |
|--------|--------|--------|
| Input-to-frame p50 | 13.5ms | 13.8ms |
| Input-to-frame p95 | **30.7ms** | 32.3ms |
| Frame interval p50 | 31.0ms | 29.6ms |
| Effective FPS | 32.3 | 33.8 |
| FPS 30+ bucket | 77.7% | 83.9% |
| Drop ratio | **26.4%** | 33.4% |
| Render skips | **0** | 21 |
| Freezes | 3 | 4 |

Canvas eliminates render skips (every frame that reaches Emacs gets displayed) and drops fewer frames overall. Input responsiveness is comparable. Both use screencast transport.
