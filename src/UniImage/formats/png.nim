# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## PNG decoder. Reimplemented from the PNG spec (ITU-T T.71 / ISO 15948) — not
## vendored. Supports color types 0 (gray), 2 (RGB), 3 (indexed), 4 (gray+alpha),
## 6 (RGBA); bit depths 1/2/4/8/16 (subject to the spec's per-type allowed
## depths). 16-bit samples are downscaled to 8-bit by taking the high byte.
## Adam7 interlaced images raise `uiUnsupported`.
## Indexed tRNS alpha is applied; grayscale/RGB tRNS alpha expansion is not.
## Chunk CRCs are verified.
import UniImage/core
import UniImage/compress/zlib
import util

const PngSig = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
const
  cIHDR = [byte('I'), byte('H'), byte('D'), byte('R')]
  cPLTE = [byte('P'), byte('L'), byte('T'), byte('E')]
  cTRNS = [byte('t'), byte('R'), byte('N'), byte('S')]
  cIDAT = [byte('I'), byte('D'), byte('A'), byte('T')]
  cIEND = [byte('I'), byte('E'), byte('N'), byte('D')]

proc paeth(a, b, c: uint8): uint8 {.inline.} =
  let p = int(a) + int(b) - int(c)
  let pa = abs(p - int(a))
  let pb = abs(p - int(b))
  let pc = abs(p - int(c))
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc sampleBits(row: openArray[byte]; px, bitDepth: int): int {.inline.} =
  ## Extract the `px`-th sample from an MSB-first packed scanline (1/2/4-bit).
  case bitDepth
  of 1:
    let sh = 7 - (px and 7)
    return int(row[px shr 3]) shr sh and 1
  of 2:
    let sh = 6 - (px and 3) * 2
    return int(row[px shr 2]) shr sh and 3
  of 4:
    let sh = 4 - (px and 1) * 4
    return int(row[px shr 1]) shr sh and 0x0F
  else: # 8
    return int(row[px])

proc scaleSample(v, bitDepth: int): uint8 {.inline.} =
  ## Scale a `bitDepth`-wide sample to 8-bit (0..255).
  case bitDepth
  of 1: uint8(v * 255)
  of 2: uint8(v * 85)
  of 4: uint8(v * 17)
  else: uint8(v)

proc decodePng*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory PNG into an 8-bit `Image`. Raises `UniImageException`.
  requireLen(data, 8, "png: signature truncated")
  for i in 0 ..< 8:
    if data[i] != PngSig[i]:
      raise UniImageException(code: uiUnsupported, msg: "png: bad signature")

  var width, height, bitDepth, colorType: int
  var plte: seq[(uint8, uint8, uint8)]
  var trns: seq[uint8]
  var idat: seq[byte] = @[]
  var sawIhdr = false
  var sawIend = false
  var pos = 8
  while pos < data.len and not sawIend:
    if pos + 8 > data.len:
      raise UniImageException(code: uiTruncated,
          msg: "png: chunk header truncated")
    let rawLength = readU32be(data, pos)
    if rawLength > 0x7FFFFFFF'u32:
      raise UniImageException(code: uiInvalidArg,
          msg: "png: chunk length exceeds the 2^31-1 limit")
    let length = int(rawLength)
    let ctype = [data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]]
    pos += 8
    if pos + length + 4 > data.len:
      raise UniImageException(code: uiTruncated, msg: "png: chunk truncated")
    let bodyStart = pos
    # CRC covers the chunk type then the data; fold both spans without
    # allocating a per-chunk buffer.
    var crc = crc32Init()
    for b in ctype: crc = crc32Update(crc, b)
    for k in 0 ..< length: crc = crc32Update(crc, data[bodyStart + k])
    if crc32Final(crc) != readU32be(data, bodyStart + length):
      raise UniImageException(code: uiInvalidArg,
          msg: "png: chunk CRC mismatch")
    pos = bodyStart + length + 4

    if ctype == cIHDR:
      sawIhdr = true
      if length != 13:
        raise UniImageException(code: uiInvalidArg, msg: "png: bad IHDR length")
      width = int(readU32be(data, bodyStart))
      height = int(readU32be(data, bodyStart + 4))
      bitDepth = int(data[bodyStart + 8])
      colorType = int(data[bodyStart + 9])
      let compression = data[bodyStart + 10]
      let filterMethod = data[bodyStart + 11]
      let interlace = data[bodyStart + 12]
      if compression != 0:
        raise UniImageException(code: uiUnsupported,
            msg: "png: unsupported compression")
      if filterMethod != 0:
        raise UniImageException(code: uiUnsupported,
            msg: "png: unsupported filter")
      if interlace != 0:
        raise UniImageException(code: uiUnsupported,
            msg: "png: Adam7 interlace unsupported")
    elif ctype == cPLTE:
      if length mod 3 != 0 or length == 0:
        raise UniImageException(code: uiInvalidArg, msg: "png: bad PLTE")
      let n = length div 3
      plte = newSeq[(uint8, uint8, uint8)](n)
      for k in 0 ..< n:
        plte[k] = (data[bodyStart + k * 3], data[bodyStart + k * 3 + 1],
          data[bodyStart + k * 3 + 2])
    elif ctype == cTRNS:
      trns = newSeq[uint8](length)
      for k in 0 ..< length: trns[k] = data[bodyStart + k]
    elif ctype == cIDAT:
      for k in 0 ..< length: idat.add(data[bodyStart + k])
    elif ctype == cIEND:
      sawIend = true
    # Ancillary chunks are skipped.

  if not sawIhdr:
    raise UniImageException(code: uiInvalidArg, msg: "png: missing IHDR")
  if not sawIend:
    raise UniImageException(code: uiTruncated, msg: "png: missing IEND")
  if width == 0 or height == 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "png: bad dimensions")
  if width * height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "png: too many pixels")

  # Validate the color-type/bit-depth combinations the spec permits.
  let validDepth = case colorType
    of 0: bitDepth in {1, 2, 4, 8, 16}
    of 2, 4, 6: bitDepth in {8, 16}
    of 3: bitDepth in {1, 2, 4, 8}
    else: false
  if not validDepth:
    raise UniImageException(code: uiUnsupported,
        msg: "png: unsupported color type/depth")
  if colorType == 3 and plte.len == 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "png: indexed image missing PLTE")

  let channels = case colorType
    of 0, 3: 1
    of 2: 3
    of 4: 2
    of 6: 4
    else: 0
  let bitsPerPixel = channels * bitDepth
  let bpp = max(1, bitsPerPixel div 8) # bytes per pixel for filter prediction
  let scanlineLen = (width * bitsPerPixel + 7) div 8
  let rowStride = scanlineLen + 1 # +1 for the filter-type byte

  # Cap inflate at the exact filtered-data size so a hostile IDAT cannot
  # blow up memory before the length check below.
  let raw = zlibInflate(idat, rowStride * height)
  if raw.len < rowStride * height:
    raise UniImageException(code: uiTruncated,
        msg: "png: filtered data too short")

  # Unfilter into per-row reconstructed bytes.
  var recon = newSeq[byte](scanlineLen)
  var prev = newSeq[byte](scanlineLen)
  let outCh = case colorType
    of 0: 1
    of 2: 3
    of 3, 4, 6: 4
    else: 0
  let cs = if outCh == 1: csGray elif outCh == 3: csRgb else: csRgba
  result = newImage[uint8](width, height, cs)

  for y in 0 ..< height:
    let r0 = y * rowStride
    let filt = raw[r0]
    if filt > 4:
      raise UniImageException(code: uiInvalidArg, msg: "png: bad filter type")
    for x in 0 ..< scanlineLen:
      let cur = raw[r0 + 1 + x]
      let left = if x >= bpp: recon[x - bpp] else: 0'u8
      let up = if y > 0: prev[x] else: 0'u8
      let upLeft = if x >= bpp and y > 0: prev[x - bpp] else: 0'u8
      recon[x] = case filt
        of 0: cur
        of 1: cur + left
        of 2: cur + up
        of 3: cur + uint8((int(left) + int(up)) div 2)
        else: cur + paeth(left, up, upLeft)
    # Unpack this row's reconstructed bytes into the output image.
    for dx in 0 ..< width:
      if colorType == 4: # gray + alpha -> RGBA (gray replicated to RGB)
        let o = (y * width + dx) * 4
        if bitDepth == 16:
          let g = recon[dx * 4] # high byte of the 16-bit gray sample
          let a = recon[dx * 4 + 2] # high byte of the 16-bit alpha sample
          result.data[o] = g
          result.data[o + 1] = g
          result.data[o + 2] = g
          result.data[o + 3] = a
        else: # 8-bit
          let g = recon[dx * 2]
          let a = recon[dx * 2 + 1]
          result.data[o] = g
          result.data[o + 1] = g
          result.data[o + 2] = g
          result.data[o + 3] = a
      elif colorType == 3: # indexed: 1/2/4/8-bit index into PLTE (+ tRNS alpha)
        let idx = if bitDepth == 8: int(recon[dx])
                  else: sampleBits(recon, dx, bitDepth)
        if idx >= plte.len:
          raise UniImageException(code: uiInvalidArg,
              msg: "png: palette index out of range")
        let o = (y * width + dx) * 4
        result.data[o] = plte[idx][0]
        result.data[o + 1] = plte[idx][1]
        result.data[o + 2] = plte[idx][2]
        result.data[o + 3] = if idx < trns.len: trns[idx] else: 255'u8
      elif bitDepth == 16: # take the high byte of each 16-bit sample
        let o = (y * width + dx) * outCh
        for c in 0 ..< outCh:
          result.data[o + c] = recon[dx * outCh * 2 + c * 2]
      elif bitDepth < 8: # 1/2/4-bit grayscale -> scaled 8-bit
        let v = sampleBits(recon, dx, bitDepth)
        result.data[y * width + dx] = scaleSample(v, bitDepth)
      else: # 8-bit gray/RGB/gray-alpha/RGBA
        let o = (y * width + dx) * outCh
        for c in 0 ..< outCh:
          result.data[o + c] = recon[dx * outCh + c]
    swap prev, recon

# ---- PNG encode -----------------------------------------------------------
# The inverse of `decodePng` for the 8-bit color spaces we model: csGray ->
# color type 0, csRgb -> type 2, csRgba -> type 6. Each scanline carries a
# single filter-type byte (0 = None) followed by the raw samples; the whole
# filtered buffer is zlib-compressed into a single IDAT. 1/2/4/16-bit depths and
# indexed (type 3) / gray+alpha (type 4) are decode-only here — they need a
# richer pixel model than `Image[uint8]` provides.

proc writeChunk(out8: var seq[byte]; ctype: array[4, byte]; body: openArray[byte]) =
  putU32be(out8, uint32(body.len))
  var crc = crc32Init()
  for b in ctype: crc = crc32Update(crc, b)
  for b in body: crc = crc32Update(crc, b)
  let c = crc32Final(crc)
  out8.add ctype[0]; out8.add ctype[1]; out8.add ctype[2]; out8.add ctype[3]
  if body.len > 0: out8.add body
  putU32be(out8, c)

proc encodePng*(img: Image[uint8]): seq[byte] =
  ## Encode an 8-bit `Image` as a non-interlaced PNG. csGray -> type 0, csRgb ->
  ## type 2, csRgba -> type 6; other color spaces raise `UniImageException`.
  let (colorType, channels) = case img.colorspace
    of csGray: (0'u8, 1)
    of csRgb: (2'u8, 3)
    of csRgba: (6'u8, 4)
    else: raise UniImageException(code: uiUnsupported,
        msg: "png: encode needs csGray, csRgb, or csRgba")
  if img.width == 0 or img.height == 0 or img.width > MaxCodecDim or
      img.height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "png: bad dimensions")
  result = newSeqOfCap[byte](64 + img.data.len)
  for b in PngSig: result.add b
  # IHDR: width, height, bitDepth=8, colorType, compression=0, filter=0,
  # interlace=0.
  var ihdr = newSeq[byte](13)
  putU32be(ihdr, 0, uint32(img.width))
  putU32be(ihdr, 4, uint32(img.height))
  ihdr[8] = 8 # bit depth
  ihdr[9] = colorType
  ihdr[10] = 0 # compression method (DEFLATE)
  ihdr[11] = 0 # filter method (adaptive)
  ihdr[12] = 0 # interlace (none)
  writeChunk(result, cIHDR, ihdr)
  # Build the filtered scanline buffer: one filter-type byte (0 = None) per
  # row, then the raw samples.
  let scanlineLen = img.width * channels
  var filtered = newSeqOfCap[byte](img.height * (scanlineLen + 1))
  for y in 0 ..< img.height:
    filtered.add byte(0) # filter type None
    let base = y * scanlineLen
    for x in 0 ..< scanlineLen: filtered.add img.data[base + x]
  let idat = zlibDeflate(filtered)
  writeChunk(result, cIDAT, idat)
  writeChunk(result, cIEND, [])
