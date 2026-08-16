# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
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
## Alpha-correct resizing

Nearest-neighbour resizing preserves every byte. Bilinear and box filters
instead interpolate RGBA in premultiplied-alpha space and return straight
alpha. Colours stored behind fully transparent pixels therefore cannot create
halos around a visible edge.
"""

nbCode:
  var alphaEdge = newImage[uint8](2, 1, csRgba)
  alphaEdge.data = @[255'u8, 0, 0, 0, 0, 0, 255, 255]
  let enlargedEdge = alphaEdge.resize(240, 80, rfBilinear)
  doAssert enlargedEdge.data[0 .. 3] == @[0'u8, 0, 0, 0]
  doAssert enlargedEdge.data[^4 .. ^1] == @[0'u8, 0, 255, 255]

nbRawHtml: """
<figure><img alt="Alpha-correct blue edge resized over transparency"
style="max-width:100%;image-rendering:pixelated" src="data:image/png;base64,""" &
  base64.encode(enlargedEdge.encodeImage(efPng)) & """">
<figcaption>The hidden red transparent pixel contributes no red fringe.</figcaption>
</figure>
"""

nbText: """
## Straight-alpha compositing

`compositeOver` places Gray, RGB, or straight-alpha RGBA pixels over an RGBA
destination. Coordinates are integer pixels and clip at every edge. Opacity is
an exact 0–255 multiplier. Channel divisions use round-to-nearest with halves
rounded upward, so the same bytes are produced by Nim, C, and Python. Aliased
source and destination buffers are snapshotted before writes.
"""

nbCode:
  var canvas = newImage[uint8](240, 120, csRgba)
  for pixel in 0 ..< canvas.width * canvas.height:
    canvas.data[pixel * 4] = 32
    canvas.data[pixel * 4 + 1] = 48
    canvas.data[pixel * 4 + 2] = 80
    canvas.data[pixel * 4 + 3] = 255
  var overlay = newImage[uint8](120, 80, csRgba)
  for row in 0 ..< overlay.height:
    for column in 0 ..< overlay.width:
      let offset = (row * overlay.width + column) * 4
      overlay.data[offset] = 240
      overlay.data[offset + 1] = uint8(40 + column)
      overlay.data[offset + 2] = 72
      overlay.data[offset + 3] = uint8(64 + row * 2)
  canvas.compositeOver(overlay, 60, 20, 224)
  doAssert canvas.data.len == 240 * 120 * 4

nbRawHtml: """
<figure><img alt="UniImage straight-alpha compositing demonstration"
style="max-width:100%;image-rendering:pixelated" src="data:image/png;base64,""" &
  base64.encode(canvas.encodeImage(efPng)) & """">
<figcaption>Executable RGBA source-over output embedded directly in this HTML.</figcaption>
</figure>
"""

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

Raster compositing is additive ABI-v1 surface. It mutates only the owned
destination handle and accepts the same 0–255 opacity as the Nim API:

```c
int ui_image_composite_over(ui_image destination, ui_image source,
                            int x, int y, int opacity);
```

```c
void        ui_exif_init(void);
int         ui_exif_read_buffer(const unsigned char* data, size_t length,
                                ui_exif_meta* out_handle);
const char* ui_exif_to_json(ui_exif_meta h);
```

The C ABI **never raises**. Every entry point validates its arguments and
traps both `CatchableError` and `Defect`, mapping them to a `ui_exif_status`
or `ui_image_status` code. Built
`--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` —
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

destination = uniimage.image_from_pixels(
    24, 16, bytes(24 * 16 * 4), uniimage.CS_RGBA
)
source = uniimage.image_from_pixels(
    4, 4, bytes(4 * 4 * 4), uniimage.CS_RGBA
)
destination.composite_over(source, x=12, y=8, opacity=192)
```

## References

- CIPA, *Exchangeable image file format for digital still cameras: Exif*.
- W3C, *Portable Network Graphics (PNG) Specification*.
- ITU-T T.81, *Digital compression and coding of continuous-tone still
  images* (JPEG).
- Google, *QOI — The Quite OK Image Format*.
"""

nbSave
