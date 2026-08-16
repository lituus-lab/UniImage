/* SPDX-License-Identifier: Apache-2.0 */
/*
 * test_uniimage.c — self-contained C ABI smoke test (no external fixture).
 * Exercises ui_exif read_buffer, to_json, strip_buffer/buffer_free, edit
 * round-trip, and NULL-safety. Build/run via `nimble ctest`.
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "UniImage.h"

int main(void) {
  ui_exif_init();

  /* NULL-safety: these must not crash and must return benign values. */
  ui_exif_meta_free(NULL);
  ui_exif_buffer_free(NULL);
  assert(ui_exif_is_valid(NULL) == 0);
  assert(ui_exif_get_tag(NULL, "Model") == NULL);
  assert(ui_exif_to_json(NULL) == NULL);
  assert(ui_exif_get_orientation(NULL) == 0);
  assert(ui_exif_is_valid((ui_exif_meta)1) == 0);
  assert(ui_exif_get_tag((ui_exif_meta)1, "Model") == NULL);
  ui_exif_meta_free((ui_exif_meta)1);

  /* Bad arguments. */
  ui_exif_meta bad = (ui_exif_meta)1;
  assert(ui_exif_read_buffer(NULL, 0, &bad) == UI_EXIF_ERR_FORMAT);

  /* A minimal JPEG (SOI + EOI), no metadata. */
  const unsigned char jpg[] = {0xFF, 0xD8, 0xFF, 0xD9};

  ui_exif_meta m = NULL;
  assert(ui_exif_read_buffer(jpg, sizeof jpg, &m) == UI_EXIF_OK);
  assert(m != NULL);
  assert(ui_exif_is_valid(m) == 0);              /* no embedded metadata */

  const char* j = ui_exif_to_json(m);
  assert(j != NULL);
  assert(strstr(j, "\"isValid\"") != NULL);
  /* Cached: a second call returns the same stable pointer. */
  assert(ui_exif_to_json(m) == j);
  assert(ui_exif_get_tag(m, NULL) == NULL);
  ui_exif_meta_free(m);
  ui_exif_meta_free(m);  /* stale handles and double-free are benign */

  /* strip_buffer round-trip. */
  unsigned char* out = NULL;
  size_t out_len = 0;
  int rc = ui_exif_strip_buffer(jpg, sizeof jpg, &out, &out_len);
  assert(rc == UI_EXIF_OK);
  assert(out != NULL);
  assert(out_len >= 2);
  assert(out[0] == 0xFF && out[1] == 0xD8);      /* still a JPEG */
  ui_exif_buffer_free(out);

  /* strip of a non-image returns UNSUP, leaves out-params cleared. */
  const unsigned char junk[] = {0x00, 0x01, 0x02, 0x03};
  out = NULL; out_len = 0;
  rc = ui_exif_strip_buffer(junk, sizeof junk, &out, &out_len);
  assert(rc == UI_EXIF_ERR_UNSUP);
  assert(out == NULL && out_len == 0);

  /* in-memory edit round-trip: open_buffer -> set -> write_buffer -> read back. */
  ui_exif_edit e = NULL;
  assert(ui_exif_edit_open_buffer(jpg, sizeof jpg, &e) == UI_EXIF_OK);
  assert(e != NULL);
  ui_exif_set_artist(e, "Jane Doe");
  ui_exif_set_software(e, "UniImage");
  /* generic typed write + unknown-tag rejection */
  assert(ui_exif_edit_set_tag(e, "ImageDescription", "C ABI test") == UI_EXIF_OK);
  assert(ui_exif_edit_set_tag(e, "ISO", "400") == UI_EXIF_OK);
  assert(ui_exif_edit_set_tag(e, "NoSuchTag", "x") == UI_EXIF_ERR_UNSUP);
  unsigned char* edited = NULL;
  size_t edited_len = 0;
  assert(ui_exif_edit_write_buffer(e, &edited, &edited_len) == UI_EXIF_OK);
  assert(edited != NULL && edited_len > sizeof jpg);   /* APP1 was inserted */
  assert(edited[0] == 0xFF && edited[1] == 0xD8);      /* still a JPEG */
  ui_exif_edit_free(e);

  ui_exif_meta rm = NULL;
  assert(ui_exif_read_buffer(edited, edited_len, &rm) == UI_EXIF_OK);
  const char* artist = ui_exif_get_tag(rm, "Artist");
  assert(artist != NULL && strcmp(artist, "Jane Doe") == 0);
  const char* desc = ui_exif_get_tag(rm, "ImageDescription");
  assert(desc != NULL && strcmp(desc, "C ABI test") == 0);
  const char* iso = ui_exif_get_tag(rm, "ISO");
  assert(iso != NULL && strcmp(iso, "400") == 0);
  ui_exif_meta_free(rm);
  ui_exif_buffer_free(edited);

  /* NULL handle is rejected and clears the out-params. */
  unsigned char* nope = (unsigned char*)1;
  size_t nope_len = 1;
  assert(ui_exif_edit_write_buffer(NULL, &nope, &nope_len) == UI_EXIF_ERR_FORMAT);
  assert(nope == NULL && nope_len == 0);

  /* ---- ui_image_* codec + process surface ------------------------------- */
  /* In its own block so the local names (bad/junk/...) do not collide with the
   * exif section's. */
  {
  /* NULL-safety: benign returns, no crash. */
  ui_image bad = (ui_image)1;
  assert(ui_image_decode_buffer(NULL, 0, UI_IMAGE_FMT_AUTO, &bad) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_decode_buffer((const unsigned char*)"x", 1, 99, &bad) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_width(NULL) == 0);
  assert(ui_image_height(NULL) == 0);
  assert(ui_image_channels(NULL) == 0);
  assert(ui_image_width((ui_image)1) == 0);
  ui_image_free((ui_image)1);
  unsigned char* np = (unsigned char*)1;
  size_t npl = 1;
  assert(ui_image_encode(NULL, UI_IMAGE_FMT_PNG, 90, &np, &npl) ==
         UI_IMAGE_ERR_FORMAT);
  assert(np == NULL && npl == 0);
  ui_image_free(NULL);
  ui_image_buffer_free(NULL, 0);

  /* A 2x2 RGB P6 PPM: red, green, blue, white. Sniffed by AUTO. */
  static const unsigned char ppm[] = {
    'P', '6', '\n', '2', ' ', '2', '\n', '2', '5', '5', '\n',
    0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00,
    0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF
  };
  ui_image img = NULL;
  assert(ui_image_decode_buffer(ppm, sizeof ppm, UI_IMAGE_FMT_AUTO, &img) ==
         UI_IMAGE_OK);
  assert(img != NULL);
  assert(ui_image_width(img) == 2);
  assert(ui_image_height(img) == 2);
  assert(ui_image_channels(img) == 3);
  assert(ui_image_get_colorspace(img) == UI_IMAGE_CS_RGB);

  ui_image made = NULL;
  assert(ui_image_from_pixels(2, 2, UI_IMAGE_CS_RGB, ppm + 11, 12, &made) ==
         UI_IMAGE_OK);
  assert(ui_image_width(made) == 2 && ui_image_channels(made) == 3);
  assert(ui_image_from_pixels(2, 2, UI_IMAGE_CS_RGB, ppm + 11, 11, &bad) ==
         UI_IMAGE_ERR_FORMAT);

  /* Straight-alpha compositing mutates an owned RGBA handle in place. */
  static const unsigned char dst_rgba[] = {0x00, 0x00, 0xFF, 0xFF};
  static const unsigned char src_rgba[] = {0xFF, 0x00, 0x00, 0x80};
  ui_image composite_dst = NULL;
  ui_image composite_src = NULL;
  assert(ui_image_from_pixels(1, 1, UI_IMAGE_CS_RGBA, dst_rgba,
                              sizeof dst_rgba, &composite_dst) == UI_IMAGE_OK);
  assert(ui_image_from_pixels(1, 1, UI_IMAGE_CS_RGBA, src_rgba,
                              sizeof src_rgba, &composite_src) == UI_IMAGE_OK);
  assert(composite_dst != NULL && composite_src != NULL);
  unsigned char* composite_before = NULL;
  size_t composite_before_len = 0;
  assert(ui_image_pixels(composite_dst, &composite_before,
                         &composite_before_len) == UI_IMAGE_OK);
  assert(ui_image_composite_over(composite_dst, composite_src, 0, 0, 255) ==
         UI_IMAGE_OK);
  unsigned char* composite_px = NULL;
  size_t composite_len = 0;
  assert(ui_image_pixels(composite_dst, &composite_px, &composite_len) ==
         UI_IMAGE_OK);
  assert(composite_len == 4 && composite_px[0] == 128 &&
         composite_px[1] == 0 && composite_px[2] == 127 &&
         composite_px[3] == 255);
  assert(composite_px == composite_before && composite_len == composite_before_len);
  assert(ui_image_composite_over(composite_dst, composite_dst, 0, 0, 255) ==
         UI_IMAGE_OK);
  assert(ui_image_pixels(composite_dst, &composite_px, &composite_len) ==
         UI_IMAGE_OK && composite_px == composite_before);
  assert(ui_image_composite_over(NULL, composite_src, 0, 0, 255) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_composite_over(composite_dst, NULL, 0, 0, 255) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_composite_over(composite_dst, composite_src, 0, 0, 256) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_composite_over(composite_dst, composite_src, 0, 0, -1) ==
         UI_IMAGE_ERR_FORMAT);
  assert(ui_image_composite_over(made, composite_src, 0, 0, 255) ==
         UI_IMAGE_ERR_FORMAT);

  static const unsigned char transparent_rgba[] = {0, 0, 0, 0};
  static const unsigned char gray_pixel[] = {80};
  ui_image clipped_dst = NULL;
  ui_image gray_src = NULL;
  assert(ui_image_from_pixels(1, 1, UI_IMAGE_CS_RGBA, transparent_rgba, 4,
                              &clipped_dst) == UI_IMAGE_OK);
  assert(ui_image_composite_over(clipped_dst, img, -2, -2, 255) ==
         UI_IMAGE_OK);
  unsigned char* clipped_px = NULL;
  size_t clipped_len = 0;
  assert(ui_image_pixels(clipped_dst, &clipped_px, &clipped_len) == UI_IMAGE_OK);
  assert(clipped_len == 4 && clipped_px[0] == 0 && clipped_px[3] == 0);
  assert(ui_image_composite_over(clipped_dst, img, -1, -1, 255) ==
         UI_IMAGE_OK);
  assert(clipped_px[0] == 255 && clipped_px[1] == 255 &&
         clipped_px[2] == 255 && clipped_px[3] == 255);
  assert(ui_image_composite_over(clipped_dst, img, 0, 0, 255) == UI_IMAGE_OK);
  assert(clipped_px[0] == 255 && clipped_px[1] == 0 &&
         clipped_px[2] == 0 && clipped_px[3] == 255);
  assert(ui_image_from_pixels(1, 1, UI_IMAGE_CS_GRAY, gray_pixel, 1,
                              &gray_src) == UI_IMAGE_OK);
  assert(gray_src != NULL);
  assert(ui_image_from_pixels(1, 1, UI_IMAGE_CS_RGBA, transparent_rgba, 4,
                              &bad) == UI_IMAGE_OK);
  assert(ui_image_composite_over(bad, gray_src, 0, 0, 128) == UI_IMAGE_OK);
  unsigned char* gray_px = NULL;
  size_t gray_len = 0;
  assert(ui_image_pixels(bad, &gray_px, &gray_len) == UI_IMAGE_OK);
  assert(gray_len == 4 && gray_px[0] == 80 && gray_px[1] == 80 &&
         gray_px[2] == 80 && gray_px[3] == 128);

  /* All historical quantizers are delegated to UniColor and exposed through
   * an immutable palette handle. */
  const char* quantizers[] = {
    "wu", "kmeans", "kmeansPP", "medianCut", "octree", "neuquant"
  };
  for (size_t qi = 0; qi < sizeof quantizers / sizeof quantizers[0]; ++qi) {
    ui_quantize_options qopts = {7, 20, 0, 0, 0};
    ui_palette palette = NULL;
    assert(ui_image_extract_palette(img, 3, quantizers[qi], 0, &qopts,
                                    &palette) == UI_IMAGE_OK);
    assert(palette != NULL);
    assert(ui_palette_len(palette) > 0 && ui_palette_len(palette) <= 3);
    assert(ui_palette_seed(palette) == 7);
    ui_color color;
    assert(ui_palette_color_at(palette, 0, &color) == UI_IMAGE_OK);
    assert(color.tag == 15); /* UniColor's ABI-stable OKLab tag. */
    assert(ui_palette_color_at(palette, ui_palette_len(palette), &color) ==
           UI_IMAGE_ERR_FORMAT);
    ui_palette_free(palette);
    ui_palette_free(palette);
  }
  ui_palette bad_palette = (ui_palette)1;
  assert(ui_image_extract_palette(img, 0, NULL, 0, NULL, &bad_palette) ==
         UI_IMAGE_ERR_FORMAT);
  assert(bad_palette == NULL);
  assert(ui_palette_len((ui_palette)1) == 0);
  ui_palette_free((ui_palette)1);

  /* EXIF orientation is a first-class process operation in every facade. */
  ui_image oriented = NULL;
  assert(ui_image_apply_orientation(img, 6, &oriented) == UI_IMAGE_OK);
  assert(ui_image_width(oriented) == 2 && ui_image_height(oriented) == 2);
  unsigned char* opx = NULL;
  size_t oplen = 0;
  assert(ui_image_pixels(oriented, &opx, &oplen) == UI_IMAGE_OK);
  assert(oplen == sizeof ppm - 11);
  assert(opx[0] == 0x00 && opx[1] == 0x00 && opx[2] == 0xFF); /* blue */
  ui_image invalid_orientation = (ui_image)1;
  assert(ui_image_apply_orientation(img, 0, &invalid_orientation) ==
         UI_IMAGE_ERR_FORMAT);
  assert(invalid_orientation == NULL);

  /* Borrowed pixels: no copy, valid until free. */
  unsigned char* px = NULL;
  size_t pxlen = 0;
  assert(ui_image_pixels(img, &px, &pxlen) == UI_IMAGE_OK);
  assert(pxlen == 2 * 2 * 3);
  assert(px[0] == 0xFF && px[1] == 0x00 && px[2] == 0x00);   /* red */
  assert(px[9] == 0xFF && px[10] == 0xFF && px[11] == 0xFF);  /* white */

  /* resize 2x2 -> 4x4 bilinear, then crop the centre 2x2. */
  ui_image big = NULL;
  assert(ui_image_resize(img, 4, 4, UI_IMAGE_FILTER_BILINEAR, &big) ==
         UI_IMAGE_OK);
  assert(ui_image_width(big) == 4 && ui_image_height(big) == 4);
  ui_image cell = NULL;
  assert(ui_image_crop(big, 1, 1, 2, 2, &cell) == UI_IMAGE_OK);
  assert(ui_image_width(cell) == 2 && ui_image_height(cell) == 2);

  /* rot90 of a 2x2 stays 2x2; then encode PNG and decode it back. */
  ui_image rot = NULL;
  assert(ui_image_rotate(cell, UI_IMAGE_ROT_90, &rot) == UI_IMAGE_OK);
  assert(ui_image_width(rot) == 2 && ui_image_height(rot) == 2);
  unsigned char* png = NULL;
  size_t pnglen = 0;
  assert(ui_image_encode(rot, UI_IMAGE_FMT_PNG, 90, &png, &pnglen) ==
         UI_IMAGE_OK);
  assert(pnglen >= 8);
  assert(png[0] == 0x89 && png[1] == 0x50 && png[2] == 0x4E &&
         png[3] == 0x47); /* PNG signature */
  ui_image back = NULL;
  assert(ui_image_decode_buffer(png, pnglen, UI_IMAGE_FMT_AUTO, &back) ==
         UI_IMAGE_OK);
  assert(ui_image_width(back) == 2 && ui_image_height(back) == 2);
  assert(ui_image_channels(back) == 3);

  /* TGA hint path: encode TGA, decode via the explicit hint (no magic). */
  unsigned char* tga = NULL;
  size_t tgalen = 0;
  assert(ui_image_encode(rot, UI_IMAGE_FMT_TGA, 90, &tga, &tgalen) ==
         UI_IMAGE_OK);
  ui_image tback = NULL;
  assert(ui_image_decode_buffer(tga, tgalen, UI_IMAGE_FMT_TGA, &tback) ==
         UI_IMAGE_OK);
  assert(ui_image_width(tback) == 2 && ui_image_height(tback) == 2);

  /* Bad args to process ops. */
  ui_image junk = NULL;
  assert(ui_image_resize(img, 0, 2, UI_IMAGE_FILTER_BILINEAR, &junk) ==
         UI_IMAGE_ERR_FORMAT);
  assert(junk == NULL);
  assert(ui_image_crop(img, 0, 0, 9, 9, &junk) == UI_IMAGE_ERR_FORMAT);
  assert(junk == NULL);
  assert(ui_image_encode(img, UI_IMAGE_FMT_GIF, 90, &np, &npl) ==
         UI_IMAGE_ERR_UNSUP); /* GIF has no encoder */

  /* ABI drift check. */
  assert(ui_image_abi_version() == UNIIMAGE_IMAGE_ABI_VERSION);

  ui_image_free(img);
  ui_image_free(img);  /* stale handles and double-free are benign */
  ui_image_free(big);
  ui_image_free(cell);
  ui_image_free(rot);
  ui_image_free(back);
  ui_image_free(tback);
  ui_image_free(oriented);
  ui_image_free(made);
  ui_image_free(composite_dst);
  ui_image_free(composite_src);
  ui_image_free(clipped_dst);
  ui_image_free(gray_src);
  ui_image_free(bad);
  ui_image_buffer_free(png, pnglen);
  ui_image_buffer_free(tga, tgalen);

  /* --- WebP/TIFF decode hints + EXIF thumbnail ------------------ */
  static const unsigned char wp_arr[] = {0x52,0x49,0x46,0x46,0x32,0x00,0x00,0x00,0x57,0x45,0x42,0x50,0x56,0x50,0x38,0x4c,0x26,0x00,0x00,0x00,0x2f,0x01,0x40,0x00,0x00,0x1f,0x20,0x10,0x20,0x78,0xf5,0xbf,0x60,0x43,0x20,0x90,0xe4,0x6f,0x36,0xd5,0x02,0x01,0x82,0x25,0xff,0x6f,0xe6,0x3f,0xf0,0xc9,0x51,0xc1,0x0d,0x18,0x22,0xfa,0x1f,0x02};
  ui_image wp = NULL;
  assert(ui_image_decode_buffer(wp_arr, sizeof wp_arr, UI_IMAGE_FMT_AUTO, &wp) ==
         UI_IMAGE_OK);
  assert(ui_image_width(wp) == 2 && ui_image_height(wp) == 2 &&
         ui_image_channels(wp) == 3);
  ui_image wp2 = NULL;
  assert(ui_image_decode_buffer(wp_arr, sizeof wp_arr, UI_IMAGE_FMT_WEBP, &wp2) ==
         UI_IMAGE_OK);
  assert(ui_image_width(wp2) == 2 && ui_image_channels(wp2) == 3);
  ui_image_free(wp); ui_image_free(wp2);

  static const unsigned char tf_arr[] = {0x4d,0x4d,0x00,0x2a,0x00,0x00,0x00,0x08,0x00,0x09,0x01,0x00,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x02,0x00,0x00,0x01,0x01,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x01,0x02,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x08,0x00,0x00,0x01,0x03,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x01,0x06,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x01,0x11,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x7a,0x00,0x00,0x01,0x15,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x01,0x16,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x01,0x17,0x00,0x03,0x00,0x00,0x00,0x01,0x00,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0xab,0xcd};
  ui_image tf = NULL;
  assert(ui_image_decode_buffer(tf_arr, sizeof tf_arr, UI_IMAGE_FMT_AUTO, &tf) ==
         UI_IMAGE_OK);
  assert(ui_image_width(tf) == 2 && ui_image_height(tf) == 1 &&
         ui_image_channels(tf) == 1);
  unsigned char* tpix = NULL; size_t tplen = 0;
  assert(ui_image_pixels(tf, &tpix, &tplen) == UI_IMAGE_OK);
  assert(tpix[0] == 0xAB && tpix[1] == 0xCD);
  ui_image tf2 = NULL;
  assert(ui_image_decode_buffer(tf_arr, sizeof tf_arr, UI_IMAGE_FMT_TIFF, &tf2) ==
         UI_IMAGE_OK);
  assert(ui_image_width(tf2) == 2);
  ui_image_free(tf); ui_image_free(tf2);

  static const unsigned char th_arr[] = {0xff,0xd8,0xff,0xe1,0xc8,0x02,0x45,0x78,0x69,0x66,0x00,0x00,0x49,0x49,0x2a,0x00,0x08,0x00,0x00,0x00,0x00,0x00,0x0e,0x00,0x00,0x00,0x02,0x00,0x01,0x02,0x04,0x00,0x01,0x00,0x00,0x00,0x2c,0x00,0x00,0x00,0x02,0x02,0x04,0x00,0x01,0x00,0x00,0x00,0x94,0x02,0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0xff,0xdb,0x00,0x43,0x00,0x06,0x04,0x05,0x06,0x05,0x04,0x06,0x06,0x05,0x06,0x07,0x07,0x06,0x08,0x0a,0x10,0x0a,0x0a,0x09,0x09,0x0a,0x14,0x0e,0x0f,0x0c,0x10,0x17,0x14,0x18,0x18,0x17,0x14,0x16,0x16,0x1a,0x1d,0x25,0x1f,0x1a,0x1b,0x23,0x1c,0x16,0x16,0x20,0x2c,0x20,0x23,0x26,0x27,0x29,0x2a,0x29,0x19,0x1f,0x2d,0x30,0x2d,0x28,0x30,0x25,0x28,0x29,0x28,0xff,0xdb,0x00,0x43,0x01,0x07,0x07,0x07,0x0a,0x08,0x0a,0x13,0x0a,0x0a,0x13,0x28,0x1a,0x16,0x1a,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0xff,0xc0,0x00,0x11,0x08,0x00,0x02,0x00,0x02,0x03,0x01,0x22,0x00,0x02,0x11,0x01,0x03,0x11,0x01,0xff,0xc4,0x00,0x1f,0x00,0x00,0x01,0x05,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0xff,0xc4,0x00,0xb5,0x10,0x00,0x02,0x01,0x03,0x03,0x02,0x04,0x03,0x05,0x05,0x04,0x04,0x00,0x00,0x01,0x7d,0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa,0xff,0xc4,0x00,0x1f,0x01,0x00,0x03,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0xff,0xc4,0x00,0xb5,0x11,0x00,0x02,0x01,0x02,0x04,0x04,0x03,0x04,0x07,0x05,0x04,0x04,0x00,0x01,0x02,0x77,0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa,0xff,0xda,0x00,0x0c,0x03,0x01,0x00,0x02,0x11,0x03,0x11,0x00,0x3f,0x00,0xcf,0xf0,0xfd,0xc4,0xc7,0x41,0xd3,0x49,0x9a,0x42,0x4d,0xb4,0x5f,0xc4,0x7f,0xb8,0x28,0xa2,0x8a,0xfc,0xfb,0x15,0xfc,0x79,0xfa,0xbf,0xcc,0xf1,0xb1,0x1f,0xc5,0x97,0xab,0xfc,0xcf,0xff,0xd9,0xff,0xd9};
  ui_image th = NULL;
  assert(ui_image_thumbnail(th_arr, sizeof th_arr, &th) == UI_IMAGE_OK);
  assert(ui_image_width(th) == 2 && ui_image_height(th) == 2 &&
         ui_image_channels(th) == 3);
  ui_image_free(th);
  static const unsigned char noex[] = {0xff, 0xd8, 0xff, 0xd9};
  ui_image nth = NULL;
  assert(ui_image_thumbnail(noex, sizeof noex, &nth) == UI_IMAGE_ERR_UNSUP);
  assert(nth == NULL);
  } /* end ui_image block */

  printf("capi test OK (EXIF ABI v%d, image ABI v%d, %s)\n",
         ui_exif_abi_version(), ui_image_abi_version(), ui_version());
  return 0;
}
