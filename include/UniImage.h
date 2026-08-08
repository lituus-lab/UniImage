/* SPDX-License-Identifier: Apache-2.0 */
/*
 * UniImage.h — C ABI for UniImage (sub-phase 1a: EXIF/XMP/IPTC surface)
 *
 * A pure-Nim image engine exposed to C: the EXIF/XMP/IPTC surface (migrated
 * from nim-exif's ABI v1) and the ui_image_* codec + process surface (1d).
 *
 * Lifecycle:
 *   - Call ui_exif_init() exactly once per process before any other function.
 *   - Handles are opaque. The library owns them; release with the matching
 *     *_free function. const char* returned by getters point into the owning
 *     handle and remain valid only until that handle is freed.
 *
 * Thread-safety:
 *   - ui_exif_init() is required once before use. A single handle must not be
 *     used concurrently from multiple threads without external synchronisation.
 *
 * Error model:
 *   - Functions returning int return a ui_exif_status. No exception or fault
 *     from the Nim core crosses this boundary.
 *
 * ABI stability:
 *   - UNIIMAGE_EXIF_ABI_VERSION is bumped on incompatible changes; check it at
 *     runtime with ui_exif_abi_version().
 */
#ifndef UNIIMAGE_H
#define UNIIMAGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UNIIMAGE_EXIF_ABI_VERSION 1

typedef enum {
  UI_EXIF_OK          = 0, /* success */
  UI_EXIF_ERR_IO      = 1, /* file could not be read/written, or parse trapped */
  UI_EXIF_ERR_FORMAT  = 2, /* bad argument / unrecognized format / no metadata */
  UI_EXIF_ERR_UNSUP   = 4  /* operation unsupported for this container */
} ui_exif_status;

/* Opaque handles. */
typedef void* ui_exif_meta;   /* read-only metadata view */
typedef void* ui_exif_edit;   /* mutable EXIF for editing  */

/* --- lifecycle --- */
void        ui_exif_init(void);
int         ui_exif_abi_version(void);
const char* ui_exif_strerror(int code);
const char* ui_version(void);

/* --- read --- */
/* On success stores a handle in *out_handle (free with ui_exif_meta_free).
 * Returns UI_EXIF_OK even when no metadata is present (check ui_exif_is_valid). */
int    ui_exif_read_file(const char* path, ui_exif_meta* out_handle);
/* Same as ui_exif_read_file but from an in-memory buffer (not copied; it need
 * only outlive this call). */
int    ui_exif_read_buffer(const unsigned char* data, size_t length,
                           ui_exif_meta* out_handle);
int    ui_exif_is_valid(ui_exif_meta h);
size_t ui_exif_tag_count(ui_exif_meta h);
/* Name/value of the i-th tag (sorted). Pointers owned by h. */
int    ui_exif_tag_at(ui_exif_meta h, size_t i,
                      const char** out_name, const char** out_value);
/* Value of a named tag, or NULL if absent. Pointer owned by h. */
const char* ui_exif_get_tag(ui_exif_meta h, const char* name);
/* Returns 1 and fills the non-NULL out-params if GPS is present, else 0. */
int    ui_exif_get_gps(ui_exif_meta h, double* lat, double* lon, double* alt);
/* Raw EXIF Orientation (1..8), or 0 if absent. */
int    ui_exif_get_orientation(ui_exif_meta h);
/* Pretty-printed JSON view of the metadata. Pointer owned by h. */
const char* ui_exif_to_json(ui_exif_meta h);
void   ui_exif_meta_free(ui_exif_meta h);

/* --- strip --- */
int    ui_exif_strip_file(const char* in_path, const char* out_path);
/* Strip in memory. On success allocates *out_data (free with ui_exif_buffer_free)
 * and sets *out_len. Input buffer is not modified. */
int    ui_exif_strip_buffer(const unsigned char* data, size_t length,
                            unsigned char** out_data, size_t* out_len);
void   ui_exif_buffer_free(unsigned char* buffer);

/* --- edit / write --- */
int    ui_exif_edit_open(const char* path, ui_exif_edit* out_handle);
/* Open an editable model from an in-memory buffer (bytes are copied into the
 * handle; the input need only outlive this call). Serialize the result with
 * ui_exif_edit_write_buffer. */
int    ui_exif_edit_open_buffer(const unsigned char* data, size_t length,
                                ui_exif_edit* out_handle);
void   ui_exif_set_artist(ui_exif_edit h, const char* value);
void   ui_exif_set_software(ui_exif_edit h, const char* value);
void   ui_exif_set_datetime(ui_exif_edit h, const char* value); /* "YYYY:MM:DD HH:MM:SS" */
void   ui_exif_set_gps(ui_exif_edit h, double lat, double lon, double alt);
/* Generic write: set EXIF tag `name` (e.g. "ImageDescription", "ISO",
 * "ExposureTime") to `value`, parsed into the tag's natural type. Returns
 * UI_EXIF_OK, or UI_EXIF_ERR_UNSUP for an unknown tag / malformed value. */
int    ui_exif_edit_set_tag(ui_exif_edit h, const char* name, const char* value);
void   ui_exif_strip_all(ui_exif_edit h);
/* Write to out_path; if out_path is NULL/empty, writes in place.
 * Only file-backed handles (ui_exif_edit_open) may write to disk;
 * buffer-backed handles must use ui_exif_edit_write_buffer. */
int    ui_exif_edit_write(ui_exif_edit h, const char* out_path);
/* Serialize an edit opened with ui_exif_edit_open_buffer back into a new image
 * buffer. On success allocates *out_data (free with ui_exif_buffer_free) and sets
 * *out_len. Returns UI_EXIF_ERR_FORMAT if the handle was opened from a path. */
int    ui_exif_edit_write_buffer(ui_exif_edit h, unsigned char** out_data,
                                 size_t* out_len);
void   ui_exif_edit_free(ui_exif_edit h);

/* ==========================================================================
 * ui_image_* — codec + process surface (sub-phase 1d)
 *
 * Opaque ui_image handles wrap an 8-bit image the library owns; release with
 * ui_image_free. ui_image_pixels borrows the pixel buffer (no copy) and stays
 * valid only until the handle is freed. ui_image_encode allocates a buffer
 * the caller frees with ui_image_buffer_free. No exception or fault from the
 * Nim core crosses this boundary; every entry returns a ui_image_status.
 *
 * UNIIMAGE_IMAGE_ABI_VERSION is bumped on incompatible changes; check it at
 * runtime with ui_image_abi_version().
 * ========================================================================== */

#define UNIIMAGE_IMAGE_ABI_VERSION 1

typedef enum {
  UI_IMAGE_OK         = 0, /* success */
  UI_IMAGE_ERR_FORMAT = 2, /* bad arg / unrecognized / truncated / bad handle */
  UI_IMAGE_ERR_UNSUP  = 4, /* unsupported format/colorspace/op */
  UI_IMAGE_ERR_MEM    = 8  /* allocation failed */
} ui_image_status;

/* Decode hint (ui_image_decode_buffer) and encode target (ui_image_encode).
 * AUTO is decode-only and sniffs the magic; GIF/PCX/WebP/TIFF are decode-only. */
typedef enum {
  UI_IMAGE_FMT_AUTO = 0, /* decode: sniff PNG/JPEG/BMP/QOI/PNM/GIF/PCX/WebP/TIFF */
  UI_IMAGE_FMT_PNG   = 1,
  UI_IMAGE_FMT_JPEG  = 2,
  UI_IMAGE_FMT_BMP   = 3,
  UI_IMAGE_FMT_QOI   = 4,
  UI_IMAGE_FMT_PNM   = 5,
  UI_IMAGE_FMT_GIF   = 6,  /* decode only */
  UI_IMAGE_FMT_PCX   = 7,  /* decode only */
  UI_IMAGE_FMT_TGA   = 8,  /* decode needs the hint (TGA has no magic) */
  UI_IMAGE_FMT_WEBP  = 9,  /* decode only (no encoder yet) */
  UI_IMAGE_FMT_TIFF  = 10  /* decode only (no encoder yet) */
} ui_image_format;

typedef enum {
  UI_IMAGE_FILTER_NEAREST  = 0,
  UI_IMAGE_FILTER_BILINEAR = 1,
  UI_IMAGE_FILTER_BOX      = 2
} ui_image_filter;

typedef enum {
  UI_IMAGE_ROT_90  = 0, /* clockwise */
  UI_IMAGE_ROT_180 = 1,
  UI_IMAGE_ROT_270 = 2, /* counter-clockwise */
  UI_IMAGE_FLIP_H  = 3, /* mirror left-right */
  UI_IMAGE_FLIP_V  = 4  /* mirror top-bottom */
} ui_image_rotate_op;

/* Order matches the Nim Colorspace enum; ui_image_colorspace returns these. */
typedef enum {
  UI_IMAGE_CS_GRAY    = 0,
  UI_IMAGE_CS_RGB     = 1,
  UI_IMAGE_CS_RGBA    = 2,
  UI_IMAGE_CS_CMYK    = 3,
  UI_IMAGE_CS_YUV     = 4,
  UI_IMAGE_CS_INDEXED = 5
} ui_image_colorspace;

/* Opaque 8-bit image handle. */
typedef void* ui_image;

/* Quantized colors use UniColor's ABI-stable space tags. The four components
 * are three chromatic values plus straight alpha. */
typedef struct ui_color {
  float comps[4];
  int32_t tag;
} ui_color;

typedef struct ui_quantize_options {
  int64_t seed;
  int max_iter;
  int weighting;
  int parallel;
  int threads;
} ui_quantize_options;

/* Immutable palette returned by ui_image_extract_palette. */
typedef void* ui_palette;

/* --- lifecycle --- */
int         ui_image_abi_version(void);
const char* ui_image_strerror(int code);
/* Copy packed 8-bit pixels into a new owned image handle. length must equal
 * width * height * the selected colorspace's channel count. */
int    ui_image_from_pixels(int width, int height, int colorspace,
                            const unsigned char* data, size_t length,
                            ui_image* out_handle);
/* Decode an in-memory image. fmt=UI_IMAGE_FMT_AUTO sniffs the magic;
 * UI_IMAGE_FMT_TGA/WEBP/TIFF decode those formats directly (TGA has no magic,
 * the others skip sniffing). On success stores a handle in *out_handle
 * (free with ui_image_free). */
int    ui_image_decode_buffer(const unsigned char* data, size_t length,
                              int fmt, ui_image* out_handle);
/* Decode the embedded EXIF JPEG thumbnail (IFD1) from any supported container
 * (JPEG, TIFF/RAW, HEIC/AVIF, PNG, WebP) without a full container decode. On
 * success stores a handle in *out_handle (free with ui_image_free). Returns
 * UI_IMAGE_ERR_UNSUP when there is no EXIF segment or no embedded thumbnail. */
int    ui_image_thumbnail(const unsigned char* data, size_t length,
                          ui_image* out_handle);
/* Encode as fmt (PNG/JPEG/BMP/QOI/PNM/TGA). quality (1..100) is JPEG-only.
 * On success allocates *out_data (free with ui_image_buffer_free) and sets
 * *out_len. AUTO/GIF/PCX/WebP/TIFF are not encodable (UI_IMAGE_ERR_UNSUP). */
int    ui_image_encode(ui_image h, int fmt, int quality,
                       unsigned char** out_data, size_t* out_len);
int    ui_image_width(ui_image h);
int    ui_image_height(ui_image h);
int    ui_image_channels(ui_image h);
int    ui_image_get_colorspace(ui_image h);
/* Borrow the pixel buffer (no copy). *out_ptr is valid until h is freed. */
int    ui_image_pixels(ui_image h, unsigned char** out_ptr, size_t* out_len);
/* Process ops produce a new handle (free with ui_image_free). */
int    ui_image_resize(ui_image h, int w, int height, int filter,
                       ui_image* out_handle);
int    ui_image_crop(ui_image h, int x, int y, int w, int height,
                     ui_image* out_handle);
int    ui_image_rotate(ui_image h, int op, ui_image* out_handle);
/* Apply EXIF Orientation (1..8) and return a new image handle. */
int    ui_image_apply_orientation(ui_image h, int orientation,
                                  ui_image* out_handle);
/* Extract at most n colors through UniColor. algo is one of "wu", "kmeans",
 * "kmeansPP", "medianCut", "octree" or "neuquant". NULL selects "wu".
 * space_tag 0 selects OKLab (tag 15). NULL options select deterministic
 * defaults. The returned palette must be freed with ui_palette_free. */
int    ui_image_extract_palette(ui_image h, int n, const char* algo,
                                int32_t space_tag,
                                const ui_quantize_options* options,
                                ui_palette* out_handle);
size_t ui_palette_len(ui_palette p);
int    ui_palette_color_at(ui_palette p, size_t i, ui_color* out_color);
int    ui_palette_tag(ui_palette p);
int    ui_palette_intent(ui_palette p);
int64_t ui_palette_seed(ui_palette p);
void   ui_palette_free(ui_palette p);
void   ui_image_free(ui_image h);
void   ui_image_buffer_free(unsigned char* buffer, size_t len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* UNIIMAGE_H */
