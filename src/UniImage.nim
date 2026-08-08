# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Pure-Nim raster image engine with metadata, codecs, and pixel processing.
import UniImage/core
export core
import UniImage/exif
export exif
import UniImage/formats
export formats
import UniImage/process
export process

proc loadThumbnail*(data: openArray[byte]): Image[uint8] =
  ## Decode the embedded EXIF JPEG thumbnail (IFD1, tags 513/514) from any
  ## supported container — JPEG, TIFF/RAW (NEF/CR2/DNG/ARW), HEIC/AVIF/MP4/MOV,
  ## PNG, WebP — into an 8-bit `Image`. Raises `UniImageException`:
  ## `uiUnsupported` when the container has no EXIF segment or no embedded
  ## thumbnail; `uiTruncated`/`uiInvalidArg` if the embedded JPEG is malformed.
  ## Bridges the metadata layer (`exifTiffBase` + `extractExifThumbnailAt`) and
  ## the JPEG codec (`decodeJpeg`); exif never imports the format codecs, so
  ## this helper lives at the engine façade where both are in scope.
  let base = exifTiffBase(data)
  if base < 0:
    raise UniImageException(code: uiUnsupported,
        msg: "loadThumbnail: no EXIF segment")
  let jpg = extractExifThumbnailAt(data, base)
  if jpg.len == 0:
    raise UniImageException(code: uiUnsupported,
        msg: "loadThumbnail: no embedded EXIF thumbnail")
  decodeJpeg(jpg)

const UniImageVersion* = "1.0.0"
