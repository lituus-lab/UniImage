# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import nimib

nbInit
nb.title = "UniImage"

nbText: """
# UniImage

Pure-Nim raster image engine with C and Python façades. Apache-2.0, DCO.

UniImage combines a generic **core image model** (`Image[P]`, color spaces,
error codes), raster codecs, pure-Nim Deflate, pixel processing, and an
**EXIF/XMP/IPTC metadata** package derived from nim-exif.

WebP support is deliberately lossless-only: VP8L and unfiltered raw or
lossless-compressed alpha are decoded exactly. Lossy, animated, filtered-alpha
and preprocessed-alpha inputs are rejected explicitly. TIFF similarly exposes
only its documented baseline chunky subset rather than approximating unsupported
layouts.

This page is a nimib book: every Nim block below is compiled and run when
the book is built. A change that breaks the API breaks the docs build, so
the two cannot drift apart.

## The core image model

The generic `Image[P]` carries a width, height, channel count, color space,
and a flat pixel buffer.
"""

nbCode:
  import UniImage

  var img = newImage[uint8](2, 3, csRgb)
  echo "version ", UniImageVersion
  echo "size ", img.width, "x", img.height, " channels=", img.channels
  echo "bytes=", img.sizeBytes()

nbText: """
The constructor is a NimContracts routine: `require` states the domain
(positive dimensions), `ensure` states the allocation invariant. Under
`-d:release` both compile away.

## EXIF/XMP/IPTC metadata

`readMetadataFromBytes` parses a still or video container's metadata without
decoding any pixels — JPEG, TIFF/RAW, PNG, WebP, and ISOBMFF (MP4/MOV/HEIC).
"""

nbCode:
  let jpg = [byte 0xFF, 0xD8, 0xFF, 0xD9] # SOI + EOI, no metadata
  let m = readMetadataFromBytes(jpg)
  echo "isValid=", m.isValid

nbText: """
## Display orientation

Decoded pixels retain their stored order. `applyExifOrientation` normalizes
that buffer for display using the EXIF Orientation value. It handles all eight
values, including mirrored camera output, without resampling.
"""

nbCode:
  var landscape = newImage[uint8](3, 2, csGray)
  landscape.data = @[1'u8, 2, 3, 4, 5, 6]
  let portrait = landscape.applyExifOrientation(6)
  doAssert (portrait.width, portrait.height) == (2, 3)
  doAssert portrait.data == @[4'u8, 1, 5, 2, 6, 3]

nbText: """
## Perceptual palette extraction

UniImage converts packed 8-bit pixels to UniColor's typed sRGB representation.
The actual Wu, k-means, k-means++, median-cut, octree, and NeuQuant algorithms
remain owned by UniColor; there is no duplicate implementation here.
"""

nbCode:
  var swatches = newImage[uint8](3, 1, csRgb)
  swatches.data = @[255'u8, 0, 0, 0, 255, 0, 0, 0, 255]
  let paletteResult = swatches.extractPalette(3, "wu")
  doAssert paletteResult.isOk
  doAssert paletteResult.get.len == 3

nbText: """
## The C ABI

The metadata surface is exposed as `ui_exif_*` (migrated from nim-exif's
ABI v1). The header is hand-written and kept in sync with
`src/UniImage/c_api.nim`; `tests/c` links one against the other on every CI
run, so a drift is caught rather than shipped.

Palette extraction uses an immutable `ui_palette` handle whose tagged colors
retain UniColor's working-space identity. The same handle is wrapped by the
Python `Palette` class.

```c
void        ui_exif_init(void);
int         ui_exif_read_buffer(const unsigned char* data, size_t length,
                                ui_exif_meta* out_handle);
const char* ui_exif_to_json(ui_exif_meta h);
```

The C ABI **never raises**. Every entry point validates its arguments and
traps both `CatchableError` and `Defect`, mapping them to a `ui_exif_status`
code. Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` —
`-d:release` (not `-d:danger`) keeps Nim's bounds checks as a backstop while
parsing untrusted image bytes.

## The Python surface

A Cython extension over the C ABI, shipped as a self-contained wheel: the
library travels inside the package, so installing it needs neither Nim nor a
compiler.

```python
import uniimage

m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
m.is_valid          # False
```

## References

- CIPA, *Exchangeable image file format for digital still cameras: Exif*.
- W3C, *Portable Network Graphics (PNG) Specification*.
- ITU-T T.81, *Digital compression and coding of continuous-tone still
  images* (JPEG).
- Google, *QOI — The Quite OK Image Format*.
"""

nbSave
