/* embr-canvas.c -- Emacs dynamic module for canvas frame blitting.
 *
 * Decodes JPEG data via libjpeg-turbo and writes pixels directly
 * into an Emacs canvas buffer, bypassing the Elisp image pipeline.
 *
 * Requires: Emacs 31+ with canvas patch, libjpeg-turbo.
 *
 * Build:  make -C native
 * Load:   (module-load "native/embr-canvas.so")
 */

#include <emacs-module.h>
#include <setjmp.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>

int plugin_is_GPL_compatible;

/* True if the running Emacs has canvas_pixel/canvas_refresh. */
static int canvas_api_available = 0;

#define EMBR_MAX_DIMENSION 32768
#define EMBR_MAX_JPEG_BYTES (64u * 1024u * 1024u)

/* Custom libjpeg error manager that longjmps instead of exit(). */
struct embr_jpeg_error_mgr {
  struct jpeg_error_mgr pub;
  jmp_buf escape;
};

static void
embr_jpeg_error_exit (j_common_ptr cinfo)
{
  struct embr_jpeg_error_mgr *mgr =
    (struct embr_jpeg_error_mgr *) cinfo->err;
  longjmp (mgr->escape, 1);
}

static int
embr_mul_overflow_size (size_t a, size_t b, size_t *out)
{
  if (a != 0 && b > SIZE_MAX / a)
    return 1;
  *out = a * b;
  return 0;
}

static int
embr_extract_dimension (emacs_env *env, emacs_value arg, int *out)
{
  intmax_t raw = env->extract_integer (env, arg);
  if (raw <= 0 || raw > EMBR_MAX_DIMENSION)
    return 0;
  *out = (int) raw;
  return 1;
}

/* ── embr-canvas-supported-p ─────────────────────────────────── */

static emacs_value
Fembr_canvas_supported_p (emacs_env *env, ptrdiff_t nargs,
                          emacs_value *args, void *data)
{
  (void)nargs; (void)args; (void)data;
  return env->intern (env, canvas_api_available ? "t" : "nil");
}

/* ── embr-canvas-blit-jpeg ───────────────────────────────────── */
/* Args: CANVAS  JPEG-DATA  WIDTH  HEIGHT  SEQ                   */

static emacs_value
Fembr_canvas_blit_jpeg (emacs_env *env, ptrdiff_t nargs,
                        emacs_value *args, void *data)
{
  (void)nargs; (void)data;
  if (!canvas_api_available)
    return env->intern (env, "nil");

  /* 1. Get canvas pixel buffer. */
  uint32_t *pixel = env->canvas_pixel (env, args[0]);
  if (!pixel)
    return env->intern (env, "nil");

  /* 2. Extract JPEG bytes from unibyte string. */
  ptrdiff_t buf_len = 0;
  if (!env->copy_string_contents (env, args[1], NULL, &buf_len)
      || buf_len <= 1
      || (size_t) (buf_len - 1) > EMBR_MAX_JPEG_BYTES)
    return env->intern (env, "nil");

  unsigned char *jpeg_buf = malloc ((size_t) buf_len);
  if (!jpeg_buf)
    return env->intern (env, "nil");
  if (!env->copy_string_contents (env, args[1], (char *) jpeg_buf, &buf_len))
    {
      free (jpeg_buf);
      return env->intern (env, "nil");
    }
  /* buf_len includes trailing NUL added by copy_string_contents. */
  size_t jpeg_len = (size_t) (buf_len - 1);

  int canvas_w = 0;
  int canvas_h = 0;
  if (!embr_extract_dimension (env, args[2], &canvas_w)
      || !embr_extract_dimension (env, args[3], &canvas_h))
    {
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  size_t canvas_pixels = 0;
  if (embr_mul_overflow_size ((size_t) canvas_w, (size_t) canvas_h,
                              &canvas_pixels))
    {
      free (jpeg_buf);
      return env->intern (env, "nil");
    }
  /* args[4] is seq (used by Elisp for stale detection, ignored here). */

  /* 3. Set up libjpeg with custom error handler (longjmp, not exit). */
  struct jpeg_decompress_struct cinfo;
  struct embr_jpeg_error_mgr jerr;
  cinfo.err = jpeg_std_error (&jerr.pub);
  jerr.pub.error_exit = embr_jpeg_error_exit;

  unsigned char *row = NULL;
  emacs_value result = env->intern (env, "nil");

  if (setjmp (jerr.escape))
    {
      /* libjpeg hit a fatal error.  Clean up and return nil. */
      jpeg_destroy_decompress (&cinfo);
      free (row);
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  jpeg_create_decompress (&cinfo);
  jpeg_mem_src (&cinfo, jpeg_buf, (unsigned long) jpeg_len);

  if (jpeg_read_header (&cinfo, TRUE) != JPEG_HEADER_OK)
    {
      jpeg_destroy_decompress (&cinfo);
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  cinfo.out_color_space = JCS_RGB;
  jpeg_start_decompress (&cinfo);

  int img_w = (int) cinfo.output_width;
  int img_h = (int) cinfo.output_height;
  if (img_w <= 0 || img_h <= 0
      || img_w > EMBR_MAX_DIMENSION
      || img_h > EMBR_MAX_DIMENSION
      || cinfo.output_components < 3)
    {
      jpeg_finish_decompress (&cinfo);
      jpeg_destroy_decompress (&cinfo);
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  size_t row_stride = 0;
  if (embr_mul_overflow_size ((size_t) img_w,
                              (size_t) cinfo.output_components,
                              &row_stride)
      || row_stride == 0
      || row_stride > EMBR_MAX_JPEG_BYTES)
    {
      jpeg_finish_decompress (&cinfo);
      jpeg_destroy_decompress (&cinfo);
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  int copy_w = img_w < canvas_w ? img_w : canvas_w;
  int copy_h = img_h < canvas_h ? img_h : canvas_h;

  row = malloc (row_stride);
  if (!row)
    {
      jpeg_destroy_decompress (&cinfo);
      free (jpeg_buf);
      return env->intern (env, "nil");
    }

  /* 4. Write decoded RGB -> ARGB32 into canvas pixel buffer. */
  int y = 0;
  while (cinfo.output_scanline < cinfo.output_height)
    {
      unsigned char *rp = row;
      jpeg_read_scanlines (&cinfo, &rp, 1);
      if (y < copy_h)
        {
          uint32_t *dst = pixel + (size_t) y * (size_t) canvas_w;
          for (int x = 0; x < copy_w; x++)
            {
              uint32_t r = rp[x * 3];
              uint32_t g = rp[x * 3 + 1];
              uint32_t b = rp[x * 3 + 2];
              dst[x] = 0xFF000000u | (r << 16) | (g << 8) | b;
            }
        }
      y++;
    }

  jpeg_finish_decompress (&cinfo);
  jpeg_destroy_decompress (&cinfo);
  free (row);
  free (jpeg_buf);

  if (canvas_pixels == 0)
    return env->intern (env, "nil");

  /* 5. Tell Emacs the canvas changed. */
  env->canvas_refresh (env, args[0]);
  result = env->intern (env, "t");
  return result;
}

/* ── embr-canvas-clear ───────────────────────────────────────── */
/* Args: CANVAS  WIDTH  HEIGHT                                  */

static emacs_value
Fembr_canvas_clear (emacs_env *env, ptrdiff_t nargs,
                    emacs_value *args, void *data)
{
  (void)nargs; (void)data;
  if (!canvas_api_available)
    return env->intern (env, "nil");

  uint32_t *pixel = env->canvas_pixel (env, args[0]);
  if (!pixel)
    return env->intern (env, "nil");

  int canvas_w = 0;
  int canvas_h = 0;
  if (!embr_extract_dimension (env, args[1], &canvas_w)
      || !embr_extract_dimension (env, args[2], &canvas_h))
    return env->intern (env, "nil");

  size_t pixels = 0;
  size_t bytes = 0;
  if (embr_mul_overflow_size ((size_t) canvas_w, (size_t) canvas_h, &pixels)
      || embr_mul_overflow_size (pixels, sizeof (*pixel), &bytes))
    return env->intern (env, "nil");

  memset (pixel, 0, bytes);
  env->canvas_refresh (env, args[0]);
  return env->intern (env, "t");
}

/* ── embr-canvas-version ─────────────────────────────────────── */

static emacs_value
Fembr_canvas_version (emacs_env *env, ptrdiff_t nargs,
                      emacs_value *args, void *data)
{
  (void)nargs; (void)args; (void)data;
  return env->make_string (env, "1.1.0", 5);
}

/* ── Module init ─────────────────────────────────────────────── */

int
emacs_module_init (struct emacs_runtime *ert)
{
  if (ert->size < (ptrdiff_t) sizeof (*ert))
    return 1;
  emacs_env *env = ert->get_environment (ert);

  /* Detect canvas API by checking env struct size. */
  canvas_api_available = (env->size >= (ptrdiff_t) sizeof (*env));

  emacs_value defalias = env->intern (env, "defalias");
  emacs_value func;
  emacs_value sym;

  func = env->make_function (env, 0, 0, Fembr_canvas_supported_p,
    "Return t if canvas pixel API is available.", NULL);
  sym = env->intern (env, "embr-canvas-supported-p");
  env->funcall (env, defalias, 2, (emacs_value[]){sym, func});

  func = env->make_function (env, 5, 5, Fembr_canvas_blit_jpeg,
    "Decode JPEG-DATA and blit to CANVAS at WIDTH x HEIGHT.\n"
    "SEQ is the frame sequence number (used by caller for ordering).", NULL);
  sym = env->intern (env, "embr-canvas-blit-jpeg");
  env->funcall (env, defalias, 2, (emacs_value[]){sym, func});

  func = env->make_function (env, 3, 3, Fembr_canvas_clear,
    "Clear CANVAS to transparent black at WIDTH x HEIGHT.", NULL);
  sym = env->intern (env, "embr-canvas-clear");
  env->funcall (env, defalias, 2, (emacs_value[]){sym, func});

  func = env->make_function (env, 0, 0, Fembr_canvas_version,
    "Return embr-canvas module version string.", NULL);
  sym = env->intern (env, "embr-canvas-version");
  env->funcall (env, defalias, 2, (emacs_value[]){sym, func});

  env->funcall (env, env->intern (env, "provide"),
    1, (emacs_value[]){env->intern (env, "embr-canvas")});

  return 0;
}
