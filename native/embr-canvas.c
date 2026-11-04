/* embr-canvas.c -- Emacs dynamic module for canvas frame blitting.
 *
 * Decodes JPEG data via libjpeg-turbo and writes pixels directly
 * into an Emacs canvas pixel buffer, bypassing the Elisp image
 * pipeline.  The canvas image type and the `canvas_data' module
 * function are part of Emacs 32; Emacs redraws the canvas when the
 * Lisp function `canvas-refresh' is called.
 *
 * Requires: Emacs 32+ built with a window system, libjpeg-turbo
 * (plain IJG libjpeg also works, through a slower conversion path).
 *
 * Build:  make -C native [EMACS_INCLUDE=/path/to/include]
 * Load:   (module-load "native/embr-canvas.so")
 *
 * Built against an older emacs-module.h the module still compiles,
 * but `embr-canvas-supported-p' returns nil.
 */

#include <emacs-module.h>
#include <limits.h>
#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>             /* jpeglib.h uses FILE without including it */
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>

int plugin_is_GPL_compatible;

/* The canvas_data environment function appeared in Emacs 32. */
#if defined EMACS_MAJOR_VERSION && EMACS_MAJOR_VERSION >= 32
# define EMBR_HAVE_CANVAS_API 1
#else
# define EMBR_HAVE_CANVAS_API 0
#endif

#if BITS_IN_JSAMPLE != 8
# error "embr-canvas needs a libjpeg built for 8-bit samples"
#endif

/* Emacs stores canvas pixels as native-endian ARGB32 words, which in
   memory is B,G,R,A on little-endian machines and A,R,G,B on
   big-endian ones.  libjpeg-turbo can produce either layout directly
   (with SIMD color conversion), so the decoded rows can go straight
   into the canvas without a per-pixel conversion loop.  */
#ifdef JCS_EXTENSIONS
# if defined __BYTE_ORDER__ && defined __ORDER_BIG_ENDIAN__ \
     && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#  define EMBR_JCS_CANVAS JCS_EXT_ARGB
# else
#  define EMBR_JCS_CANVAS JCS_EXT_BGRA
# endif
#endif

/* True if the running Emacs provides canvas_data. */
static int canvas_api_available = 0;

#define EMBR_MODULE_VERSION "2.1.0"
#define EMBR_MAX_DIMENSION 32768
#define EMBR_MAX_JPEG_BYTES (64u * 1024u * 1024u)
#define EMBR_OPAQUE_BLACK 0xFF000000u

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

/* libjpeg prints warnings about truncated or slightly damaged data to
   stderr by default.  A screencast frame cut short still decodes, and
   is not worth a line in Emacs's stderr.  */
static void
embr_jpeg_output_message (j_common_ptr cinfo)
{
  (void) cinfo;
}

static emacs_value
embr_nil (emacs_env *env)
{
  return env->intern (env, "nil");
}

static emacs_value
embr_t (emacs_env *env)
{
  return env->intern (env, "t");
}

/* True if ENV has a pending non-local exit (error or throw), which
   Emacs raises when the module function returns.  */
static int
embr_pending_exit (emacs_env *env)
{
  return env->non_local_exit_check (env) != emacs_funcall_exit_return;
}

/* Return the ARGB32 pixel buffer of CANVAS, or NULL.  Emacs sizes
   (and resizes) the buffer to the :data-width x :data-height of the
   spec on this call.  On an invalid spec Emacs leaves a pending error
   that is raised when the module function returns.  */
static uint32_t *
embr_canvas_data (emacs_env *env, emacs_value canvas)
{
#if EMBR_HAVE_CANVAS_API
  if (canvas_api_available)
    return env->canvas_data (env, canvas);
#else
  (void) env; (void) canvas;
#endif
  return NULL;
}

/* Store the :data-width and :data-height of canvas image spec CANVAS,
   the dimensions Emacs sized its pixel buffer by, in *W and *H.
   Return 0 if they are missing or out of range (a non-local exit is
   pending if a Lisp call failed).  Taking the dimensions from the spec
   itself, rather than from caller arguments, means a mismatch cannot
   write past the end of the buffer.  */
static int
embr_canvas_size (emacs_env *env, emacs_value canvas, int *w, int *h)
{
  static const char *const keys[2] = { ":data-width", ":data-height" };
  int *const out[2] = { w, h };
  emacs_value plist = env->funcall (env, env->intern (env, "cdr"),
                                    1, &canvas);
  if (embr_pending_exit (env))
    return 0;
  for (int i = 0; i < 2; i++)
    {
      emacs_value args[2] = { plist, env->intern (env, keys[i]) };
      emacs_value val = env->funcall (env, env->intern (env, "plist-get"),
                                      2, args);
      if (embr_pending_exit (env) || !env->is_not_nil (env, val))
        return 0;
      intmax_t raw = env->extract_integer (env, val);
      if (embr_pending_exit (env) || raw <= 0 || raw > EMBR_MAX_DIMENSION)
        return 0;
      *out[i] = (int) raw;
    }
  /* Emacs rejects specs whose buffer would exceed INT_MAX bytes;
     check the same bound so the size arithmetic below cannot wrap.  */
  if ((intmax_t) *w * *h > INT_MAX / 4)
    return 0;
  return 1;
}

/* Ask Emacs to redraw CANVAS after its pixel buffer changed.  Return
   t, or nil if the call failed (a non-local exit is then pending).  */
static emacs_value
embr_canvas_refresh (emacs_env *env, emacs_value canvas)
{
  emacs_value args[2] = { canvas, embr_nil (env) };
  env->funcall (env, env->intern (env, "canvas-refresh"), 2, args);
  return embr_pending_exit (env) ? embr_nil (env) : embr_t (env);
}

/* Fill N pixels at DST with opaque black.  */
static void
embr_fill_black (uint32_t *dst, size_t n)
{
  for (size_t i = 0; i < n; i++)
    dst[i] = EMBR_OPAQUE_BLACK;
}

/* ── embr-canvas-supported-p ─────────────────────────────────── */

static emacs_value
Fembr_canvas_supported_p (emacs_env *env, ptrdiff_t nargs,
                          emacs_value *args, void *data)
{
  (void)nargs; (void)args; (void)data;
  return canvas_api_available ? embr_t (env) : embr_nil (env);
}

/* ── embr-canvas-blit-jpeg ───────────────────────────────────── */
/* Args: CANVAS  JPEG-DATA                                       */

static emacs_value
Fembr_canvas_blit_jpeg (emacs_env *env, ptrdiff_t nargs,
                        emacs_value *args, void *data)
{
  (void)nargs; (void)data;
  if (!canvas_api_available)
    return embr_nil (env);

  /* 1. Get the canvas pixel buffer and its dimensions.  */
  uint32_t *pixel = embr_canvas_data (env, args[0]);
  if (!pixel)
    return embr_nil (env);
  int canvas_w = 0;
  int canvas_h = 0;
  if (!embr_canvas_size (env, args[0], &canvas_w, &canvas_h))
    return embr_nil (env);

  /* 2. Copy the JPEG bytes out of the unibyte string.  */
  ptrdiff_t buf_len = 0;
  if (!env->copy_string_contents (env, args[1], NULL, &buf_len)
      || buf_len <= 1
      || (size_t) (buf_len - 1) > EMBR_MAX_JPEG_BYTES)
    return embr_nil (env);

  unsigned char *jpeg_buf = malloc ((size_t) buf_len);
  if (!jpeg_buf)
    return embr_nil (env);
  if (!env->copy_string_contents (env, args[1], (char *) jpeg_buf, &buf_len))
    {
      free (jpeg_buf);
      return embr_nil (env);
    }
  /* buf_len includes the trailing NUL added by copy_string_contents. */
  size_t jpeg_len = (size_t) (buf_len - 1);

  /* 3. Decode.  libjpeg reports fatal errors through error_exit,
     which longjmps back to the setjmp below.  ROW is assigned after
     setjmp and read in the handler, so it must be volatile for its
     value to be reliable there.  */
  struct jpeg_decompress_struct cinfo;
  struct embr_jpeg_error_mgr jerr;
  unsigned char *volatile row = NULL;

  cinfo.err = jpeg_std_error (&jerr.pub);
  jerr.pub.error_exit = embr_jpeg_error_exit;
  jerr.pub.output_message = embr_jpeg_output_message;

  if (setjmp (jerr.escape))
    goto fail;

  jpeg_create_decompress (&cinfo);
  jpeg_mem_src (&cinfo, jpeg_buf, (unsigned long) jpeg_len);

  if (jpeg_read_header (&cinfo, TRUE) != JPEG_HEADER_OK)
    goto fail;

#ifdef EMBR_JCS_CANVAS
  cinfo.out_color_space = EMBR_JCS_CANVAS;
#else
  cinfo.out_color_space = JCS_RGB;
#endif
  jpeg_start_decompress (&cinfo);

  int img_w = (int) cinfo.output_width;
  int img_h = (int) cinfo.output_height;
  int comps = cinfo.output_components;
  if (img_w <= 0 || img_h <= 0
      || img_w > EMBR_MAX_DIMENSION
      || img_h > EMBR_MAX_DIMENSION
#ifdef EMBR_JCS_CANVAS
      || comps != 4
#else
      || comps != 3
#endif
      )
    goto fail;

  /* The frame is anchored at the top-left corner and clipped to the
     canvas; canvas area the frame does not cover is painted black, so
     a frame of the wrong size (during a resize) shows no stale
     pixels.  Dimensions are bounded, so this cannot overflow.  */
  int copy_w = img_w < canvas_w ? img_w : canvas_w;
  int copy_h = img_h < canvas_h ? img_h : canvas_h;
  size_t row_stride = (size_t) img_w * (size_t) comps;

#ifdef EMBR_JCS_CANVAS
  /* libjpeg-turbo writes canvas pixels straight into the canvas rows
     when the widths match; otherwise it decodes into a row buffer
     whose left part is copied.  */
  if (img_w != canvas_w)
    {
      row = malloc (row_stride);
      if (!row)
        goto fail;
    }
  for (int y = 0; y < copy_h; y++)
    {
      uint32_t *dst = pixel + (size_t) y * (size_t) canvas_w;
      JSAMPROW rp = row ? (JSAMPROW) row : (JSAMPROW) dst;
      if (jpeg_read_scanlines (&cinfo, &rp, 1) != 1)
        goto fail;
      if (row)
        memcpy (dst, row, (size_t) copy_w * sizeof *dst);
      embr_fill_black (dst + copy_w, (size_t) (canvas_w - copy_w));
    }
#else
  /* Plain libjpeg: decode RGB rows and convert to ARGB32 by hand.  */
  row = malloc (row_stride);
  if (!row)
    goto fail;
  for (int y = 0; y < copy_h; y++)
    {
      uint32_t *dst = pixel + (size_t) y * (size_t) canvas_w;
      JSAMPROW rp = (JSAMPROW) row;
      if (jpeg_read_scanlines (&cinfo, &rp, 1) != 1)
        goto fail;
      for (int x = 0; x < copy_w; x++)
        dst[x] = EMBR_OPAQUE_BLACK
                 | ((uint32_t) row[x * 3] << 16)
                 | ((uint32_t) row[x * 3 + 1] << 8)
                 | (uint32_t) row[x * 3 + 2];
      embr_fill_black (dst + copy_w, (size_t) (canvas_w - copy_w));
    }
#endif
  embr_fill_black (pixel + (size_t) copy_h * (size_t) canvas_w,
                   (size_t) (canvas_h - copy_h) * (size_t) canvas_w);

  /* A frame taller than the canvas has rows nobody will see; stop
     decoding instead of reading them.  */
  if (cinfo.output_scanline < cinfo.output_height)
    jpeg_abort_decompress (&cinfo);
  else
    jpeg_finish_decompress (&cinfo);
  jpeg_destroy_decompress (&cinfo);
  free (row);
  free (jpeg_buf);

  /* 4. Tell Emacs the canvas changed. */
  return embr_canvas_refresh (env, args[0]);

 fail:
  /* Reached from the libjpeg error handler and from validation
     failures after jpeg_create_decompress; the canvas may hold a
     partial frame, which the next blit overwrites.  */
  jpeg_destroy_decompress (&cinfo);
  free (row);
  free (jpeg_buf);
  return embr_nil (env);
}

/* ── embr-canvas-clear ───────────────────────────────────────── */
/* Args: CANVAS                                                  */

static emacs_value
Fembr_canvas_clear (emacs_env *env, ptrdiff_t nargs,
                    emacs_value *args, void *data)
{
  (void)nargs; (void)data;
  if (!canvas_api_available)
    return embr_nil (env);

  uint32_t *pixel = embr_canvas_data (env, args[0]);
  if (!pixel)
    return embr_nil (env);
  int canvas_w = 0;
  int canvas_h = 0;
  if (!embr_canvas_size (env, args[0], &canvas_w, &canvas_h))
    return embr_nil (env);

  memset (pixel, 0, (size_t) canvas_w * (size_t) canvas_h * sizeof *pixel);
  return embr_canvas_refresh (env, args[0]);
}

/* ── embr-canvas-version ─────────────────────────────────────── */

static emacs_value
Fembr_canvas_version (emacs_env *env, ptrdiff_t nargs,
                      emacs_value *args, void *data)
{
  (void)nargs; (void)args; (void)data;
  return env->make_string (env, EMBR_MODULE_VERSION,
                           sizeof EMBR_MODULE_VERSION - 1);
}

/* ── Module init ─────────────────────────────────────────────── */

static void
embr_defun (emacs_env *env, const char *name, ptrdiff_t min_arity,
            ptrdiff_t max_arity, emacs_value (*fn) (emacs_env *, ptrdiff_t,
                                                     emacs_value *, void *),
            const char *doc)
{
  emacs_value args[2] = {
    env->intern (env, name),
    env->make_function (env, min_arity, max_arity, fn, doc, NULL)
  };
  env->funcall (env, env->intern (env, "defalias"), 2, args);
}

int
emacs_module_init (struct emacs_runtime *ert)
{
  if (ert->size < (ptrdiff_t) sizeof (*ert))
    return 1;
  emacs_env *env = ert->get_environment (ert);
  if (env->size < (ptrdiff_t) sizeof (struct emacs_env_25))
    return 2;

  /* The running Emacs provides canvas_data if its environment
     struct extends past that slot.  */
#if EMBR_HAVE_CANVAS_API
  canvas_api_available
    = (env->size > (ptrdiff_t) offsetof (emacs_env, canvas_data));
#else
  canvas_api_available = 0;
#endif

  embr_defun (env, "embr-canvas-supported-p", 0, 0, Fembr_canvas_supported_p,
              "Return t if the Emacs 32 canvas pixel API is available.");
  embr_defun (env, "embr-canvas-blit-jpeg", 2, 2, Fembr_canvas_blit_jpeg,
              "Decode JPEG-DATA into CANVAS and redraw it.\n"
              "CANVAS is a canvas image spec; its :data-width and\n"
              ":data-height give the size of the pixel buffer.  The frame\n"
              "is clipped to the canvas, and canvas area it does not\n"
              "cover is painted black.  Return t, or nil if JPEG-DATA\n"
              "could not be decoded.");
  embr_defun (env, "embr-canvas-clear", 1, 1, Fembr_canvas_clear,
              "Clear CANVAS to transparent black and redraw it.\n"
              "Return t, or nil if the canvas API is unavailable.");
  embr_defun (env, "embr-canvas-version", 0, 0, Fembr_canvas_version,
              "Return the embr-canvas module version string.");

  emacs_value feature = env->intern (env, "embr-canvas");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
