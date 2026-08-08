# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## ZSoft PCX decoder. Reimplemented from the PCX spec — not vendored. Supports
## the layouts that occur in real files: 24-bit truecolor (3 planes x 8-bit),
## 8-bit indexed (256-color palette at end of file), 8-bit grayscale
## (paletteInfo = 2), and 1-bit monochrome. RLE (encoding = 1) and uncompressed
## (encoding = 0) scans are both handled; each scanline is decoded independently
## since PCX RLE runs do not cross scanlines. Rare layouts (2/4-bit indexed,
## 4-plane x 1-bit) raise `uiUnsupported`.
import UniImage/core
import util

proc decodePcx*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory PCX into an 8-bit `Image`. Raises `UniImageException`.
  requireLen(data, 128, "pcx: header truncated")
  if data[0] != 0x0A:
    raise UniImageException(code: uiUnsupported, msg: "pcx: not a ZSoft PCX")
  let version = data[1]
  let encoding = data[2]
  let bpp = int(data[3])
  let xmin = int(readU16le(data, 4))
  let ymin = int(readU16le(data, 6))
  let xmax = int(readU16le(data, 8))
  let ymax = int(readU16le(data, 10))
  let nplanes = int(data[65])
  let bpl = int(readU16le(data, 66))
  let paletteInfo = int(readU16le(data, 68))
  if version > 5:
    raise UniImageException(code: uiUnsupported,
        msg: "pcx: unsupported version")
  if encoding > 1:
    raise UniImageException(code: uiUnsupported,
        msg: "pcx: unsupported encoding")
  let width = xmax - xmin + 1
  let height = ymax - ymin + 1
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pcx: bad dimensions")
  let total = width * height
  if total > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pcx: too many pixels")
  let truecolor = nplanes == 3 and bpp == 8
  let indexed8 = nplanes == 1 and bpp == 8
  let mono = nplanes == 1 and bpp == 1
  if not (truecolor or indexed8 or mono):
    raise UniImageException(code: uiUnsupported,
        msg: "pcx: unsupported pixel layout")
  if bpl < (width + 7) div 8 and mono:
    raise UniImageException(code: uiInvalidArg,
        msg: "pcx: bpl too small for mono")
  if bpl < width and not mono:
    raise UniImageException(code: uiInvalidArg,
        msg: "pcx: bpl smaller than width")
  let requiredBpl = if mono: (width + 7) div 8 else: width
  if bpl > requiredBpl + 1:
    raise UniImageException(code: uiInvalidArg,
        msg: "pcx: bpl too large for width")

  # RLE-decode each scanline into `nplanes * bpl` bytes. Runs do not cross
  # scanlines, so a run that overshoots the stride is malformed.
  let stride = nplanes * bpl
  var raw = newSeq[byte](stride * height)
  var src = 128
  for line in 0 ..< height:
    var dst = 0
    while dst < stride:
      if src >= data.len:
        raise UniImageException(code: uiTruncated,
            msg: "pcx: pixel data truncated")
      let b = data[src]; inc src
      if encoding == 1 and (b and 0xC0) == 0xC0:
        let count = int(b and 0x3F)
        if src >= data.len:
          raise UniImageException(code: uiTruncated,
              msg: "pcx: RLE value truncated")
        let v = data[src]; inc src
        for _ in 0 ..< count:
          if dst >= stride:
            raise UniImageException(code: uiInvalidArg,
                msg: "pcx: RLE overruns scanline")
          raw[line * stride + dst] = v; inc dst
      else:
        raw[line * stride + dst] = b; inc dst

  if truecolor:
    result = newImage[uint8](width, height, csRgb)
    for dy in 0 ..< height:
      let rowBase = dy * stride
      for dx in 0 ..< width:
        let o = (dy * width + dx) * 3
        result.data[o] = raw[rowBase + dx] # R plane
        result.data[o + 1] = raw[rowBase + bpl + dx] # G plane
        result.data[o + 2] = raw[rowBase + 2 * bpl + dx] # B plane
  elif indexed8:
    if paletteInfo == 2: # grayscale: the index is the gray level
      result = newImage[uint8](width, height, csGray)
      for dy in 0 ..< height:
        for dx in 0 ..< width:
          result.data[dy * width + dx] = raw[dy * stride + dx]
    else:
      # 256-color palette: last 769 bytes, 0x0C marker then 768 RGB bytes.
      if data.len < 769 or data[data.len - 769] != 0x0C:
        raise UniImageException(code: uiInvalidArg,
            msg: "pcx: missing 256-color palette")
      let palBase = data.len - 768
      result = newImage[uint8](width, height, csRgba)
      for dy in 0 ..< height:
        for dx in 0 ..< width:
          let idx = int(raw[dy * stride + dx])
          let p = palBase + idx * 3
          if p + 2 >= data.len:
            raise UniImageException(code: uiInvalidArg,
                msg: "pcx: palette index out of range")
          let o = (dy * width + dx) * 4
          result.data[o] = data[p]
          result.data[o + 1] = data[p + 1]
          result.data[o + 2] = data[p + 2]
          result.data[o + 3] = 255
  else: # mono: bit set = black (0), clear = white (255), MSB first (PBM-style)
    result = newImage[uint8](width, height, csGray)
    for dy in 0 ..< height:
      let rowBase = dy * bpl
      for dx in 0 ..< width:
        let bit = byte(0x80) shr (dx and 7)
        result.data[dy * width + dx] = if (raw[rowBase + dx shr 3] and bit) != 0: 0'u8
                                       else: 255'u8
