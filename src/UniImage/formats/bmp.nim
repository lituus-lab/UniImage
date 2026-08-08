# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## BMP decoder (BITMAPINFOHEADER and the larger V4/V5 headers, BI_RGB only).
## Reimplemented from the BMP spec — not vendored. Supports 1/4/8-bit indexed
## and 24/32-bit truecolor; RLE, 16-bit, and BI_BITFIELDS raise
## `uiUnsupported`. Output color space matches the source: 24-bit -> csRgb,
## 32-bit and indexed -> csRgba (alpha 255).
import UniImage/core
import ./util

proc decodeBmp*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory BMP into an 8-bit `Image`. Raises `UniImageException`.
  requireLen(data, 14 + 4, "bmp: header truncated")
  if data[0] != 0x42 or data[1] != 0x4D: # "BM"
    raise UniImageException(code: uiUnsupported, msg: "bmp: not a BM container")
  let pixOffset = int(readU32le(data, 10))
  let dibSize = int(readU32le(data, 14))
  if dibSize < 40:
    raise UniImageException(code: uiUnsupported,
      msg: "bmp: only BITMAPINFOHEADER-and-larger DIB headers are supported")
  # The first 40 bytes of every >=40-byte DIB header are the INFOHEADER fields.
  requireLen(data, 14 + 40, "bmp: DIB header truncated")
  let width = int(readI32le(data, 18))
  let heightRaw = int(readI32le(data, 22))
  if width <= 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "bmp: width must be positive")
  if heightRaw == 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "bmp: height must be non-zero")
  if width > MaxCodecDim or abs(heightRaw) > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg,
        msg: "bmp: dimensions too large")
  let topDown = heightRaw < 0
  let rowsH = abs(heightRaw)
  if int(readU16le(data, 26)) != 1:
    raise UniImageException(code: uiUnsupported, msg: "bmp: planes must be 1")
  let bpp = int(readU16le(data, 28))
  if int(readU32le(data, 30)) != 0:
    raise UniImageException(code: uiUnsupported,
      msg: "bmp: only BI_RGB (uncompressed) is supported")
  if bpp notin {1, 4, 8, 24, 32}:
    raise UniImageException(code: uiUnsupported, msg: "bmp: unsupported bpp")

  let palStart = 14 + dibSize
  var pal: seq[(uint8, uint8, uint8)]
  if bpp <= 8:
    let colorsUsed = int(readU32le(data, 46))
    let maxCol = 1 shl bpp
    let count = if colorsUsed > 0 and colorsUsed <=
        maxCol: colorsUsed else: maxCol
    requireLen(data, palStart + count * 4, "bmp: palette truncated")
    pal = newSeq[(uint8, uint8, uint8)](count)
    for k in 0 ..< count:
      let p = palStart + k * 4
      pal[k] = (data[p + 2], data[p + 1], data[p]) # BGR -> RGB

  # The pixel array must not overlap the header/palette.
  let minOffset = palStart + pal.len * 4
  if pixOffset < minOffset:
    raise UniImageException(code: uiInvalidArg,
      msg: "bmp: pixel offset overlaps header or palette")
  let rowStride = ((bpp * width + 31) div 32) * 4
  let need = int64(pixOffset) + int64(rowStride) * int64(rowsH)
  if need > int64(data.len):
    raise UniImageException(code: uiTruncated, msg: "bmp: pixel data truncated")

  let cs = if bpp == 24: csRgb else: csRgba
  result = newImage[uint8](width, rowsH, cs)
  let ch = result.channels
  for dy in 0 ..< rowsH:
    let srcRow = if topDown: dy else: rowsH - 1 - dy
    let rowBase = pixOffset + srcRow * rowStride
    for dx in 0 ..< width:
      let dst = (dy * width + dx) * ch
      case bpp
      of 24:
        let s = rowBase + dx * 3
        result.data[dst] = data[s + 2]
        result.data[dst + 1] = data[s + 1]
        result.data[dst + 2] = data[s]
      of 32:
        let s = rowBase + dx * 4
        result.data[dst] = data[s + 2]
        result.data[dst + 1] = data[s + 1]
        result.data[dst + 2] = data[s]
        result.data[dst + 3] = 255 # BI_RGB 32-bit padding byte is reserved.
      of 8:
        let idx = int(data[rowBase + dx])
        if idx >= pal.len:
          raise UniImageException(code: uiInvalidArg,
              msg: "bmp: palette index out of range")
        let (r, g, b) = pal[idx]
        result.data[dst] = r
        result.data[dst + 1] = g
        result.data[dst + 2] = b
        result.data[dst + 3] = 255
      of 4:
        let nibble = (data[rowBase + dx shr 1] shr
          (if (dx and 1) == 0: 4 else: 0)) and 0xF
        if int(nibble) >= pal.len:
          raise UniImageException(code: uiInvalidArg,
              msg: "bmp: palette index out of range")
        let (r, g, b) = pal[int(nibble)]
        result.data[dst] = r
        result.data[dst + 1] = g
        result.data[dst + 2] = b
        result.data[dst + 3] = 255
      of 1:
        let bit = (data[rowBase + dx shr 3] shr (7 - (dx and 7))) and 1
        if int(bit) >= pal.len:
          raise UniImageException(code: uiInvalidArg,
              msg: "bmp: palette index out of range")
        let (r, g, b) = pal[int(bit)]
        result.data[dst] = r
        result.data[dst + 1] = g
        result.data[dst + 2] = b
        result.data[dst + 3] = 255
      else: discard # bpp validated above

proc encodeBmp*(img: Image[uint8]): seq[byte] =
  ## Encode an 8-bit `Image` as a BMP. Supports csRgb (24-bit BGR) and csRgba
  ## (32-bit BGRA); both bottom-up, uncompressed (BI_RGB). Raises
  ## `UniImageException(uiUnsupported)` for other color spaces.
  let bpp = if img.colorspace == csRgba: 32
            elif img.colorspace == csRgb: 24
            else:
              raise UniImageException(code: uiUnsupported,
                  msg: "bmp: encode needs csRgb or csRgba")
  let rowSize64 = ((int64(img.width) * int64(bpp div 8) + 3) div 4) * 4
  let pixelBytes64 = rowSize64 * int64(img.height)
  let fileSize64 = 54'i64 + pixelBytes64
  if rowSize64 > int64(high(int)) or pixelBytes64 > int64(high(uint32)) or
      fileSize64 > int64(high(uint32)):
    raise UniImageException(code: uiEncoding,
        msg: "bmp: encoded size exceeds the 32-bit BMP fields")
  let rowSize = int(rowSize64)
  let pixelBytes = int(pixelBytes64)
  let fileSize = int(fileSize64)
  result = newSeq[byte](fileSize)
  # File header.
  result[0] = 0x42; result[1] = 0x4D # "BM"
  putU32le(result, 2, uint32(fileSize))
  # reserved words at 6,8 stay 0
  putU32le(result, 10, 54) # pixel data offset
  # BITMAPINFOHEADER.
  putU32le(result, 14, 40)
  putU32le(result, 18, uint32(img.width))
  putU32le(result, 22, uint32(img.height)) # positive -> bottom-up
  putU16le(result, 26, 1) # planes
  putU16le(result, 28, uint16(bpp))
  putU32le(result, 30, 0) # BI_RGB
  putU32le(result, 34, uint32(pixelBytes))
  putU32le(result, 38, 2835) # x ppm
  putU32le(result, 42, 2835) # y ppm
  putU32le(result, 46, 0) # colors used
  putU32le(result, 50, 0) # important colors
  # Pixel data: bottom-up, BGR(A), each row padded to 4 bytes.
  let ch = img.channels
  for y in 0 ..< img.height:
    let srcRow = img.height - 1 - y
    let rowOff = 54 + y * rowSize
    for x in 0 ..< img.width:
      let s = (srcRow * img.width + x) * ch
      let d = rowOff + x * (bpp div 8)
      result[d] = img.data[s + 2] # B
      result[d + 1] = img.data[s + 1] # G
      result[d + 2] = img.data[s] # R
      if bpp == 32: result[d + 3] = img.data[s + 3] # A
