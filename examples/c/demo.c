// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
// Minimal C consumer of the UniImage EXIF C ABI: init, read, inspect, strip,
// free. Links libUniImage.a (plus -lz for the zlibutil FFI until 1b).
#include <stdio.h>
#include <stdlib.h>
#include "UniImage.h"

int main(void) {
  ui_exif_init();
  printf("UniImage %s, EXIF ABI v%d\n", ui_version(), ui_exif_abi_version());

  /* A minimal JPEG: SOI + EOI, no metadata. */
  unsigned char jpg[] = {0xFF, 0xD8, 0xFF, 0xD9};
  size_t n = sizeof(jpg);

  ui_exif_meta h = NULL;
  int rc = ui_exif_read_buffer(jpg, n, &h);
  if (rc != UI_EXIF_OK) {
    printf("read_buffer failed: %s\n", ui_exif_strerror(rc));
    return 1;
  }
  printf("valid=%d tags=%zu orientation=%d\n",
         ui_exif_is_valid(h),
         ui_exif_tag_count(h),
         ui_exif_get_orientation(h));
  ui_exif_meta_free(h);

  /* Strip is a no-op on a bare JPEG: the stripped buffer equals the input. */
  unsigned char* out = NULL;
  size_t out_len = 0;
  rc = ui_exif_strip_buffer(jpg, n, &out, &out_len);
  if (rc != UI_EXIF_OK) {
    printf("strip_buffer failed: %s\n", ui_exif_strerror(rc));
    return 1;
  }
  printf("stripped %zu bytes\n", out_len);
  ui_exif_buffer_free(out);
  return 0;
}
