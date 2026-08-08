# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## TGA (Targa) decoder. Reimplemented from the TGA 2.0 spec — not vendored.
## Supports uncompressed (types 1/2/3) and RLE (types 9/10/11): color-mapped,
## truecolor, and grayscale. Pixel depth 8/24/32; 16-bit raises uiUnsupported
## (rare, and its 1-bit alpha is ambiguous). Top-down (descriptor bit 5) and
## bottom-up are both handled. Output: grayscale -> csGray, 24-bit truecolor
## and 24-bit palettes -> csRgb, 32-bit and 32-bit palettes -> csRgba.
import UniImage/core
import util

type
  Pixel = tuple[r, g, b, a: uint8]
  TgaKind = enum tkIndexed, tkColor, tkGray

proc tgaPixel(data: openArray[byte]; pos: int; kind: TgaKind; depth: int;
    pal: seq[Pixel]; cmapStart: int): (Pixel, int) =
  ## Read one source pixel at `pos`; return (pixel, bytesConsumed).
  case kind
  of tkColor:
    if depth == 24:
      requireLen(data, pos + 3, "tga: pixel truncated")
      return ((data[pos + 2], data[pos + 1], data[pos], 255'u8), 3)
    elif depth == 32:
      requireLen(data, pos + 4, "tga: pixel truncated")
      return ((data[pos + 2], data[pos + 1], data[pos], data[pos + 3]), 4)
    else:
      raise UniImageException(code: uiUnsupported,
          msg: "tga: 16-bit truecolor unsupported")
  of tkGray:
    requireLen(data, pos + 1, "tga: pixel truncated")
    return ((data[pos], data[pos], data[pos], 255'u8), 1)
  of tkIndexed:
    requireLen(data, pos + 1, "tga: index truncated")
    let j = int(data[pos]) - cmapStart
    if j < 0 or j >= pal.len:
      raise UniImageException(code: uiInvalidArg,
          msg: "tga: palette index out of range")
    return (pal[j], 1)

proc store(img: var Image[uint8]; idx, outCh: int; px: Pixel) {.inline.} =
  let base = idx * outCh
  img.data[base] = px.r
  if outCh >= 2: img.data[base + 1] = px.g
  if outCh >= 3: img.data[base + 2] = px.b
  if outCh == 4: img.data[base + 3] = px.a

proc decodeTga*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory TGA into an 8-bit `Image`. Raises `UniImageException`.
  requireLen(data, 18, "tga: header truncated")
  let idLen = int(data[0])
  let cmapType = data[1]
  let imgType = data[2]
  let cmapStart = int(readU16le(data, 3))
  let cmapLen = int(readU16le(data, 5))
  let cmapBpp = int(data[7])
  let width = int(readU16le(data, 12))
  let height = int(readU16le(data, 14))
  let depth = int(data[16])
  let descriptor = data[17]
  let topDown = (descriptor and 0x20) != 0
  if imgType notin {1, 2, 3, 9, 10, 11}:
    raise UniImageException(code: uiUnsupported,
        msg: "tga: unsupported image type")
  if width == 0 or height == 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "tga: bad dimensions")
  let total = width * height
  if total > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "tga: too many pixels")
  let rle = imgType in {9, 10, 11}
  let kind = if imgType in {1, 9}: tkIndexed
             elif imgType in {3, 11}: tkGray
             else: tkColor

  var pos = 18 + idLen
  var pal: seq[Pixel]
  if cmapType == 1:
    if kind != tkIndexed:
      raise UniImageException(code: uiInvalidArg,
        msg: "tga: color map present but image is not color-mapped")
    let entryBytes = cmapBpp div 8
    if entryBytes notin {3, 4}:
      raise UniImageException(code: uiUnsupported,
          msg: "tga: palette must be 24/32-bit")
    requireLen(data, pos + cmapLen * entryBytes, "tga: color map truncated")
    pal = newSeq[Pixel](cmapLen)
    for k in 0 ..< cmapLen:
      let p = pos + k * entryBytes
      pal[k] = if entryBytes == 3: (data[p + 2], data[p + 1], data[p], 255'u8)
               else: (data[p + 2], data[p + 1], data[p], data[p + 3])
    pos += cmapLen * entryBytes
  elif kind == tkIndexed:
    raise UniImageException(code: uiInvalidArg,
      msg: "tga: color-mapped image has no color map")

  if kind == tkIndexed and depth != 8:
    raise UniImageException(code: uiUnsupported,
        msg: "tga: index depth must be 8")
  if kind == tkGray and depth != 8:
    raise UniImageException(code: uiUnsupported,
        msg: "tga: grayscale depth must be 8")

  let outCh = if kind == tkGray: 1
              elif depth == 32 or (kind == tkIndexed and cmapBpp == 32): 4
              else: 3
  let cs = if outCh == 1: csGray elif outCh == 4: csRgba else: csRgb
  result = newImage[uint8](width, height, cs)

  var written = 0
  while written < total:
    if rle:
      if pos >= data.len:
        raise UniImageException(code: uiTruncated,
            msg: "tga: RLE stream truncated")
      let hdr = data[pos]; inc pos
      let count = int(hdr and 0x7F) + 1
      if (hdr and 0x80) != 0: # RLE packet: one pixel, repeated `count` times
        let (px, n) = tgaPixel(data, pos, kind, depth, pal, cmapStart)
        pos += n
        for _ in 0 ..< count:
          if written >= total:
            raise UniImageException(code: uiInvalidArg,
                msg: "tga: RLE exceeds image")
          store(result, written, outCh, px); inc written
      else: # raw packet: `count` distinct pixels
        for _ in 0 ..< count:
          if written >= total:
            raise UniImageException(code: uiInvalidArg,
                msg: "tga: RLE exceeds image")
          let (px, n) = tgaPixel(data, pos, kind, depth, pal, cmapStart)
          pos += n
          store(result, written, outCh, px); inc written
    else:
      let (px, n) = tgaPixel(data, pos, kind, depth, pal, cmapStart)
      pos += n
      store(result, written, outCh, px); inc written
  # Bottom-up rows (the default) need flipping to match the image orientation.
  if not topDown:
    for dy in 0 ..< height div 2:
      let other = height - 1 - dy
      for dx in 0 ..< width:
        let a = (dy * width + dx) * outCh
        let b = (other * width + dx) * outCh
        for c in 0 ..< outCh:
          swap result.data[a + c], result.data[b + c]

proc encodeTga*(img: Image[uint8]): seq[byte] =
  ## Encode an 8-bit `Image` as an uncompressed TGA (type 2 for truecolor, type
  ## 3 for grayscale). Supports csRgb (24-bit BGR), csRgba (32-bit BGRA), csGray
  ## (8-bit). Bottom-up, origin bottom-left. Reimplemented from the TGA spec.
  let (imageType, bpp) =
    case img.colorspace
    of csRgb: (2'u8, 24'u8)
    of csRgba: (2'u8, 32'u8)
    of csGray: (3'u8, 8'u8)
    else:
      raise UniImageException(code: uiUnsupported,
          msg: "tga: encode needs csRgb, csRgba, or csGray")
  if img.width > int(high(uint16)) or img.height > int(high(uint16)):
    raise UniImageException(code: uiInvalidArg,
        msg: "tga: dimensions exceed the 16-bit header fields")
  let ch = img.channels
  let rowBytes = img.width * (int(bpp) div 8)
  result = newSeq[byte](18 + rowBytes * img.height)
  result[0] = 0 # id length
  result[1] = 0 # no color map
  result[2] = imageType
  # color map spec (5 bytes) = 0
  putU16le(result, 8, 0) # x origin
  putU16le(result, 10, 0) # y origin
  putU16le(result, 12, uint16(img.width))
  putU16le(result, 14, uint16(img.height))
  result[16] = bpp
  result[17] = 0 # descriptor: bottom-up, 0 alpha bits
  # Pixel data: bottom-up, BGR(A).
  for y in 0 ..< img.height:
    let srcRow = img.height - 1 - y
    let rowOff = 18 + y * rowBytes
    for x in 0 ..< img.width:
      let s = (srcRow * img.width + x) * ch
      let d = rowOff + x * (int(bpp) div 8)
      if bpp == 8:
        result[d] = img.data[s]
      else:
        result[d] = img.data[s + 2] # B
        result[d + 1] = img.data[s + 1] # G
        result[d + 2] = img.data[s] # R
        if bpp == 32: result[d + 3] = img.data[s + 3] # A
