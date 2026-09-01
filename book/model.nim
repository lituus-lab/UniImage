# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "The image model"

nbText: """
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
"""

nbSave
