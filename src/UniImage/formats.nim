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
# HEIF says what a picture is without decoding one; the coded bytes are HEVC
# or AV1 and belong to a backend the application registers.
import ./formats/heif
export heif
# The system decoder, when the build asked for it. Off by default, so the
# library links no framework and runs anywhere unless a caller opts in.
when defined(macosx) and defined(appleCodecs):
  import ./formats/heif_apple
  export heif_apple
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
  when defined(macosx) and defined(appleCodecs):
    # HEIF shares its magic with MP4, so the brand is what tells them apart.
    if isHeif(data):
      return decodeHeifApple(data)
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

type ScaledImage* = object
  ## A decode that was allowed to reduce, and the size it reduced from.
  image*: Image[uint8]
  sourceWidth*, sourceHeight*: int

proc jpegSize(data: openArray[byte]): tuple[width, height: int] =
  ## Width and height from the frame header, without decoding a single block.
  ## Returns (0, 0) when no SOF marker is found: the caller then decodes and
  ## lets the decoder raise on whatever is wrong with the file.
  var pos = 2
  while pos + 1 < data.len:
    # Walk markers the way `decodeJpeg` does, so the two agree on where every
    # segment starts; whatever it would reject ends this scan at (0, 0).
    if data[pos] != 0xFF: return (0, 0)
    inc pos
    while pos < data.len and data[pos] == 0xFF: inc pos # fill bytes
    if pos >= data.len: return (0, 0)
    let marker = data[pos]; inc pos
    if marker == 0xDA or marker == 0xD9: return (0, 0) # scan or end of image
    if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7): continue # standalone
    if pos + 1 >= data.len: return (0, 0)
    let segLen = (int(data[pos]) shl 8) or int(data[pos + 1])
    if segLen < 2 or pos + segLen > data.len: return (0, 0)
    # SOF0/1/2/3, 5/6/7, 9/10/11, 13/14/15 all carry the frame size here.
    if marker in {0xC0'u8, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                  0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
      if pos + 6 >= data.len: return (0, 0)
      let height = (int(data[pos + 3]) shl 8) or int(data[pos + 4])
      let width = (int(data[pos + 5]) shl 8) or int(data[pos + 6])
      return (width, height)
    pos += segLen
  (0, 0)

proc decodeImageScaled*(data: openArray[byte]; maxEdge: int): ScaledImage =
  ## Decode as cheaply as the format allows while keeping both edges at least
  ## `maxEdge`, and report the size before any reduction.
  ##
  ## Only JPEG can currently reduce, and only by eight; every other format
  ## decodes in full. A caller that reduces the image anyway — a perceptual
  ## hash, a thumbnail — asks for what it needs instead of paying for every
  ## pixel and throwing them away.
  if maxEdge < 1:
    raise UniImageException(code: uiInvalidArg,
        msg: "decodeImageScaled: maxEdge must be positive")
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8: # JPEG SOI
    let size = jpegSize(data)
    # Compare against what `jdEighth` would return -- one sample per block,
    # rounded up -- rather than scaling `maxEdge` up, which can overflow.
    if (size.width + 7) div 8 >= maxEdge and (size.height + 7) div 8 >= maxEdge:
      return ScaledImage(image: decodeJpeg(data, jdEighth),
        sourceWidth: size.width, sourceHeight: size.height)
  let full = decodeImage(data)
  ScaledImage(image: full, sourceWidth: full.width, sourceHeight: full.height)

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
