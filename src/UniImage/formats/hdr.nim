# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Radiance HDR (RGBE) decoder. Reimplemented from the Radiance file spec —
## not vendored. Returns an `Image[float32]` (HDR components), so it is not part
## of the `decodeImage` LDR dispatcher — call `decodeHdr` directly. Supports the
## two encodings that occur in real files: new RLE (per-channel runs, width >= 8)
## and flat uncompressed scanlines. Old per-pixel RLE is rare and rejected.
## Orientation "-Y H +X W" (top-down) and "+Y" (bottom-up, flipped) are handled.
import std/[math, strutils]
import UniImage/core
import util

proc nextNewline(data: openArray[byte]; i: int): int =
  ## Index of the next '\n' at or after `i`, or `data.len` if none.
  result = i
  while result < data.len and data[result] != byte('\n'): inc result

proc parseRes(data: openArray[byte]; a, b: int; width, height: var int;
    flipY: var bool) =
  ## Parse the "-Y H +X W" resolution line spanning [a, b).
  var tokens: seq[string]
  var field = ""
  for k in a ..< b:
    let c = char(data[k])
    if c == ' ' or c == '\t':
      if field.len > 0: tokens.add(field); field = ""
    else:
      field.add(c)
  if field.len > 0: tokens.add(field)
  if tokens.len != 4:
    raise UniImageException(code: uiInvalidArg, msg: "hdr: bad resolution line")
  if tokens[0] == "-Y": flipY = false
  elif tokens[0] == "+Y": flipY = true
  else: raise UniImageException(code: uiUnsupported,
      msg: "hdr: unsupported Y axis")
  if tokens[2] != "+X":
    # -X (right-to-left scan order) is valid HDR but needs a horizontal flip,
    # which is not implemented; reject it rather than emit a mirrored image.
    raise UniImageException(code: uiUnsupported, msg: "hdr: unsupported X axis")
  try:
    height = parseInt(tokens[1])
    width = parseInt(tokens[3])
  except ValueError:
    raise UniImageException(code: uiInvalidArg,
        msg: "hdr: non-numeric dimensions")
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "hdr: bad dimensions")
  if width * height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "hdr: too many pixels")

proc decodeRleChannel(data: openArray[byte]; pos: var int; scan: var seq[byte];
    c, width: int) =
  ## Decode one RLE-compressed channel into `scan[*, c]`.
  var x = 0
  while x < width:
    if pos >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "hdr: RLE control truncated")
    let b = data[pos]; inc pos
    if b > 128: # run: (b and 0x7F) repeats of the next byte
      let n = int(b and 0x7F)
      if x + n > width:
        raise UniImageException(code: uiInvalidArg,
            msg: "hdr: RLE overruns scanline")
      if pos >= data.len:
        raise UniImageException(code: uiTruncated,
            msg: "hdr: RLE value truncated")
      let v = data[pos]; inc pos
      for k in 0 ..< n: scan[(x + k) * 4 + c] = v
      x += n
    elif b < 128: # raw: `b` literal bytes
      let n = int(b)
      if x + n > width or pos + n > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "hdr: raw run truncated")
      for k in 0 ..< n: scan[(x + k) * 4 + c] = data[pos + k]
      pos += n
      x += n
    else:
      raise UniImageException(code: uiInvalidArg,
          msg: "hdr: invalid RLE code 128")

proc decodeHdr*(data: openArray[byte]): Image[float32] =
  ## Decode an in-memory Radiance HDR into an `Image[float32]` (csRgb). Raises
  ## `UniImageException`.
  var i = 0
  var firstLine = true
  var sawRadiance = false
  while i < data.len:
    let j = nextNewline(data, i)
    if j == i: # empty line terminates the header
      i = j + 1
      break
    if firstLine:
      if j - i < 2 or data[i] != byte('#') or data[i + 1] != byte('?'):
        raise UniImageException(code: uiUnsupported,
            msg: "hdr: missing #? magic")
      sawRadiance = true
      firstLine = false
    i = j + 1
  if not sawRadiance:
    raise UniImageException(code: uiUnsupported,
        msg: "hdr: not a Radiance file")
  # Resolution line.
  let r1 = nextNewline(data, i)
  var width, height: int
  var flipY: bool
  parseRes(data, i, r1, width, height, flipY)
  i = r1 + 1

  if int64(data.len - i) < int64(height) * 4:
    raise UniImageException(code: uiTruncated,
        msg: "hdr: scanline data truncated")

  result = newImage[float32](width, height, csRgb)
  var scan = newSeq[byte](width * 4)
  for dy in 0 ..< height:
    # New RLE marker: [2, 2, W_lo, W_hi] with the high bit of W_hi clear.
    if width >= 8 and i + 4 <= data.len and data[i] == 2 and data[i + 1] ==
        2 and (data[i + 3] and 0x80) == 0:
      let wRle = int(data[i + 2]) or (int(data[i + 3]) shl 8)
      if wRle != width:
        raise UniImageException(code: uiInvalidArg,
            msg: "hdr: RLE width mismatch")
      i += 4
      for c in 0 ..< 4: decodeRleChannel(data, i, scan, c, width)
    else: # flat uncompressed scanline
      requireLen(data, i + width * 4, "hdr: scanline truncated")
      for px in 0 ..< width:
        scan[px * 4] = data[i + px * 4]
        scan[px * 4 + 1] = data[i + px * 4 + 1]
        scan[px * 4 + 2] = data[i + px * 4 + 2]
        scan[px * 4 + 3] = data[i + px * 4 + 3]
      i += width * 4
    let outRow = if flipY: height - 1 - dy else: dy
    for dx in 0 ..< width:
      let r = scan[dx * 4]
      let g = scan[dx * 4 + 1]
      let b = scan[dx * 4 + 2]
      let e = scan[dx * 4 + 3]
      let o = (outRow * width + dx) * 3
      if e == 0:
        result.data[o] = 0'f32; result.data[o + 1] = 0'f32; result.data[o + 2] = 0'f32
      else:
        let f = pow(2.0'f32, float32(int(e) - (128 + 8)))
        result.data[o] = (float32(r) + 0.5'f32) * f
        result.data[o + 1] = (float32(g) + 0.5'f32) * f
        result.data[o + 2] = (float32(b) + 0.5'f32) * f
