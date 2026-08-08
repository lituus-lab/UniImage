# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Raster format codecs implemented from public specifications (see NOTICE).
import std/strutils
import UniImage/core
import ./formats/bmp
import ./formats/qoi
import ./formats/pnm
import ./formats/tga
import ./formats/pcx
import ./formats/hdr
import ./formats/png
import ./formats/gif
import ./formats/jpeg
import ./formats/webp
import ./formats/tiff

export core
export bmp
export qoi
export pnm
export tga
export pcx
export hdr
export png
export gif
export jpeg
export webp
export tiff

proc decodeImage*(data: openArray[byte]): Image[uint8] =
  ## Sniff the magic bytes and decode an LDR image (8-bit components). Raises
  ## `UniImageException` — `uiUnsupported` for an unrecognized container,
  ## `uiTruncated`/`uiInvalidArg` for malformed input. TGA has no reliable
  ## header magic (only an optional v2 footer), so it is not dispatched here —
  ## call `decodeTga` directly. HDR (Radiance .hdr) returns float components,
  ## so it is not part of this LDR dispatcher — call `decodeHdr` directly.
  if data.len < 2:
    raise UniImageException(code: uiTruncated,
        msg: "decodeImage: input too short")
  if data[0] == 0x42 and data[1] == 0x4D: # BMP "BM"
    return decodeBmp(data)
  if data.len >= 4 and data[0] == 0x71 and data[1] == 0x6F and
      data[2] == 0x69 and data[3] == 0x66: # QOI "qoif"
    return decodeQoi(data)
  if data[0] == byte('P') and data[1] >= byte('1') and data[1] <= byte('6'):
    return decodePnm(data)
  if data.len >= 8 and data[0] == 0x89 and data[1] == 0x50 and
      data[2] == 0x4E and data[3] == 0x47: # PNG signature
    return decodePng(data)
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8: # JPEG SOI
    return decodeJpeg(data)
  if data.len >= 6 and data[0] == byte('G') and data[1] == byte('I') and
      data[2] == byte('F') and data[3] == byte('8') and
      (data[4] == byte('7') or data[4] == byte('9')) and data[5] == byte('a'):
    return decodeGif(data)
  if data.len >= 12 and data[0] == byte('R') and data[1] == byte('I') and
      data[2] == byte('F') and data[3] == byte('F') and
      data[8] == byte('W') and data[9] == byte('E') and
      data[10] == byte('B') and data[11] == byte('P'): # WebP (RIFF/WEBP)
    return decodeWebp(data)
  if data.len >= 4 and ((data[0] == byte('I') and data[1] == byte('I') and
      data[2] == 0x2A and data[3] == 0x00) or
      (data[0] == byte('M') and data[1] == byte('M') and
      data[2] == 0x00 and data[3] == 0x2A)): # TIFF (II/MM + magic 42)
    return decodeTiff(data)
  if data.len >= 3 and data[0] == 0x0A and data[1] in {0'u8, 2, 3, 4, 5} and
      data[2] in {0'u8, 1}: # PCX: ZSoft manufacturer + valid version/encoding
    return decodePcx(data)
  raise UniImageException(code: uiUnsupported,
      msg: "decodeImage: unrecognized format")

# ---- encode dispatcher ----------------------------------------------------
# The inverse of `decodeImage`: pick an encoder by output format. The caller
# knows the target format (it has the output path), so dispatch is by an
# explicit `EncodeFormat` rather than by sniffing bytes. PNM/PAM, BMP, QOI and
# TGA are lossless; PNG is lossless and the default; JPEG is the only lossy
# codec and takes an optional `quality` (1..100, default 90).

type
  EncodeFormat* = enum
    efPng, efJpeg, efBmp, efQoi, efPnm, efTga

proc encodeImage*(img: Image[uint8]; fmt: EncodeFormat;
    quality = 90): seq[byte] =
  ## Encode an 8-bit `Image` as `fmt`. Raises `UniImageException(uiUnsupported)`
  ## for color spaces the chosen codec cannot represent (each encoder checks
  ## its own subset). JPEG is the only lossy target; `quality` is ignored for
  ## the rest.
  case fmt
  of efPng: encodePng(img)
  of efJpeg: encodeJpeg(img, quality)
  of efBmp: encodeBmp(img)
  of efQoi: encodeQoi(img)
  of efPnm: encodePnm(img)
  of efTga: encodeTga(img)

proc encodeFormatFromExt*(ext: string): EncodeFormat =
  ## Map a file extension (case-insensitive, with leading dot) to an encoder.
  ## Raises `UniImageException(uiUnsupported)` for an unknown extension.
  case ext.toLowerAscii()
  of ".png": efPng
  of ".jpg", ".jpeg": efJpeg
  of ".bmp": efBmp
  of ".qoi": efQoi
  of ".pnm", ".ppm", ".pgm", ".pam": efPnm
  of ".tga", ".targa": efTga
  else:
    raise UniImageException(code: uiUnsupported,
        msg: "encodeImage: unknown extension " & ext)
