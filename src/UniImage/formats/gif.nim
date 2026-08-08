# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## GIF decoder. Reimplemented from the GIF89a spec — not vendored. Decodes the
## first image frame at its own width/height; canvas offset/compositing and
## animation are unsupported. Supports local and global color tables,
## LZW-compressed image data (variable code size, clear/end codes), interlaced
## rows (4-pass), and transparency via the Graphics Control Extension. Output is
## csRgba; the transparent color index (if any) gets alpha 0.
import UniImage/core
import util

proc readSubBlocks(data: openArray[byte]; pos: var int): seq[byte] =
  ## Concatenate length-prefixed sub-blocks (1..255 bytes each) until a 0 block.
  result = @[]
  while pos < data.len:
    let n = int(data[pos]); inc pos
    if n == 0: break
    if pos + n > data.len:
      raise UniImageException(code: uiTruncated,
          msg: "gif: sub-block truncated")
    for k in 0 ..< n: result.add(data[pos + k])
    pos += n

type
  GifBits = object
    buf: uint32
    cnt: int
    src: int

proc readCode(data: openArray[byte]; b: var GifBits; codeSize: int): int =
  ## Read `codeSize` LSB-first bits from `data`. Raises `uiTruncated` past the
  ## end. Module-level (not a closure) so it can take an `openArray`.
  while b.cnt < codeSize:
    if b.src >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "gif: LZW stream truncated")
    b.buf = b.buf or (uint32(data[b.src]) shl b.cnt)
    inc b.src
    b.cnt += 8
  result = int(b.buf and ((uint32(1) shl codeSize) - 1))
  b.buf = b.buf shr codeSize
  b.cnt -= codeSize

proc lzwDecode(minCodeSize: int; data: openArray[byte]; maxOut: int): seq[uint8] =
  ## GIF LZW decode of a concatenated sub-block stream. Raises on malformed
  ## codes.
  if minCodeSize < 2 or minCodeSize > 8:
    raise UniImageException(code: uiInvalidArg,
        msg: "gif: bad LZW min code size")
  let clearCode = 1 shl minCodeSize
  let endCode = clearCode + 1
  var codeSize = minCodeSize + 1
  var dict: seq[seq[uint8]] = @[]
  for i in 0 ..< clearCode: dict.add(@[uint8(i)])
  dict.add(@[]) # clear code placeholder
  dict.add(@[]) # end code placeholder
  var nextCode = endCode + 1
  var b = GifBits(src: 0)
  var prev: seq[uint8] = @[]
  result = @[]
  while true:
    let code = readCode(data, b, codeSize)
    if code == clearCode:
      dict.setLen(endCode + 1)
      nextCode = endCode + 1
      codeSize = minCodeSize + 1
      prev = @[]
      continue
    if code == endCode: break
    var entry: seq[uint8]
    if code < nextCode:
      entry = dict[code]
    elif code == nextCode and prev.len > 0:
      entry = prev & @[prev[0]]
    else:
      raise UniImageException(code: uiInvalidArg, msg: "gif: bad LZW code")
    if entry.len > maxOut - result.len:
      raise UniImageException(code: uiInvalidArg,
          msg: "gif: LZW output exceeds the frame size")
    result.add(entry)
    if prev.len > 0 and nextCode < 4096:
      dict.add(prev & @[entry[0]])
      inc nextCode
      if nextCode == (1 shl codeSize) and codeSize < 12: inc codeSize
    prev = entry

proc deinterlace(src: seq[uint8]; width, height: int): seq[uint8] =
  ## Reorder rows from GIF 4-pass interlace order into top-to-bottom.
  result = newSeq[uint8](src.len)
  let starts = [0, 4, 2, 1]
  let steps = [8, 8, 4, 2]
  var s = 0
  for pass in 0 ..< 4:
    var y = starts[pass]
    while y < height:
      let srcRow = s * width
      let dstRow = y * width
      for x in 0 ..< width: result[dstRow + x] = src[srcRow + x]
      inc s
      y += steps[pass]

proc decodeGif*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory GIF into an 8-bit `Image` (csRgba). Raises
  ## `UniImageException`. Only the first image frame is decoded.
  requireLen(data, 13, "gif: header truncated")
  if data[0] != byte('G') or data[1] != byte('I') or data[2] != byte('F'):
    raise UniImageException(code: uiUnsupported, msg: "gif: bad signature")
  if data[3] != byte('8') or (data[4] != byte('7') and data[4] != byte('9')) or
      data[5] != byte('a'):
    raise UniImageException(code: uiUnsupported,
        msg: "gif: unsupported version")
  let width = int(readU16le(data, 6))
  let height = int(readU16le(data, 8))
  let packed = data[10]
  if width == 0 or height == 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "gif: bad dimensions")
  if width * height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "gif: too many pixels")
  let gctFlag = (packed and 0x80) != 0
  let gctSize = 1 shl ((int(packed) and 0x07) + 1)
  var pos = 13
  var gct: seq[(uint8, uint8, uint8)]
  if gctFlag:
    if pos + gctSize * 3 > data.len:
      raise UniImageException(code: uiTruncated,
          msg: "gif: global color table truncated")
    gct = newSeq[(uint8, uint8, uint8)](gctSize)
    for k in 0 ..< gctSize:
      gct[k] = (data[pos + k * 3], data[pos + k * 3 + 1], data[pos + k * 3 + 2])
    pos += gctSize * 3

  var transparentIdx = -1
  while pos < data.len:
    let marker = data[pos]; inc pos
    if marker == 0x3B: # trailer
      raise UniImageException(code: uiInvalidArg, msg: "gif: no image data")
    elif marker == 0x21: # extension
      if pos >= data.len:
        raise UniImageException(code: uiTruncated,
            msg: "gif: extension truncated")
      let label = data[pos]; inc pos
      if label == 0xF9: # Graphics Control Extension
        if pos + 6 > data.len:
          raise UniImageException(code: uiTruncated, msg: "gif: GCE truncated")
        let gcePacked = data[pos + 1]
        if (gcePacked and 0x01) != 0:
          transparentIdx = int(data[pos + 4])
        pos += 6 # block size (4) + terminator (0)
      else:
        discard readSubBlocks(data, pos) # skip extension sub-blocks
    elif marker == 0x2C: # image descriptor
      if pos + 9 > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "gif: image descriptor truncated")
      let imgW = int(readU16le(data, pos + 4))
      let imgH = int(readU16le(data, pos + 6))
      let imgPacked = data[pos + 8]
      pos += 9
      if imgW == 0 or imgH == 0 or imgW > MaxCodecDim or imgH > MaxCodecDim:
        raise UniImageException(code: uiInvalidArg,
            msg: "gif: bad image dimensions")
      if int64(imgW) * int64(imgH) > int64(MaxCodecDim):
        raise UniImageException(code: uiInvalidArg,
            msg: "gif: image has too many pixels")
      let lctFlag = (imgPacked and 0x80) != 0
      let interlaced = (imgPacked and 0x40) != 0
      let lctSize = 1 shl ((int(imgPacked) and 0x07) + 1)
      var pal = gct
      if lctFlag:
        if pos + lctSize * 3 > data.len:
          raise UniImageException(code: uiTruncated,
              msg: "gif: local color table truncated")
        pal = newSeq[(uint8, uint8, uint8)](lctSize)
        for k in 0 ..< lctSize:
          pal[k] = (data[pos + k * 3], data[pos + k * 3 + 1], data[pos + k * 3 + 2])
        pos += lctSize * 3
      if pos >= data.len:
        raise UniImageException(code: uiTruncated,
            msg: "gif: missing LZW min code size")
      let minCodeSize = int(data[pos]); inc pos
      let lzwStream = readSubBlocks(data, pos)
      let indices = lzwDecode(minCodeSize, lzwStream, imgW * imgH)
      if indices.len < imgW * imgH:
        raise UniImageException(code: uiTruncated,
            msg: "gif: LZW output too short")
      let ordered = if interlaced: deinterlace(indices, imgW,
          imgH) else: indices
      result = newImage[uint8](imgW, imgH, csRgba)
      for y in 0 ..< imgH:
        for x in 0 ..< imgW:
          let idx = int(ordered[y * imgW + x])
          if idx >= pal.len:
            raise UniImageException(code: uiInvalidArg,
                msg: "gif: palette index out of range")
          let o = (y * imgW + x) * 4
          result.data[o] = pal[idx][0]
          result.data[o + 1] = pal[idx][1]
          result.data[o + 2] = pal[idx][2]
          result.data[o + 3] = if idx == transparentIdx: 0'u8 else: 255'u8
      return
    else:
      raise UniImageException(code: uiInvalidArg,
          msg: "gif: unknown block marker")
  raise UniImageException(code: uiTruncated, msg: "gif: no image descriptor")
