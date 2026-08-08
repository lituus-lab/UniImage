# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## TIFF decoder. Reimplemented from the TIFF 6.0 spec — not vendored. Supports
## baseline strips and tiles; uncompressed (1), PackBits (32773), LZW (5), and
## Deflate (8 / old-style 32946); grayscale, RGB, RGBA, CMYK, and palette
## photometrics; 1/4/8/16-bit samples (16-bit downscaled to 8-bit by the high
## byte, sub-byte grayscale scaled to 8-bit). The horizontal predictor (2) is
## undone for LZW/Deflate. Planar configuration 2, YCbCr, float samples, and
## CCITT/JPEG compressions raise `uiUnsupported` (honest stubs).
import std/tables
import UniImage/core
import UniImage/compress/zlib
import util

const
  tagImageWidth = 256
  tagImageLength = 257
  tagBitsPerSample = 258
  tagCompression = 259
  tagPhotometric = 262
  tagStripOffsets = 273
  tagSamplesPerPixel = 277
  tagRowsPerStrip = 278
  tagStripByteCounts = 279
  tagPlanarConfig = 284
  tagPredictor = 317
  tagColorMap = 320
  tagTileWidth = 322
  tagTileLength = 323
  tagTileOffsets = 324
  tagTileByteCounts = 325
  tagSampleFormat = 339

type
  FieldKind = enum fkInt, fkRat
  TiffField = object
    kind: FieldKind
    ints: seq[uint32]
    rats: seq[(uint32, uint32)]

proc r16(d: openArray[byte]; i: int; le: bool): uint16 {.inline.} =
  if le: readU16le(d, i) else: readU16be(d, i)

proc r32(d: openArray[byte]; i: int; le: bool): uint32 {.inline.} =
  if le: readU32le(d, i) else: readU32be(d, i)

proc typeSize(t: int): int =
  ## Bytes per element of a TIFF field type.
  case t
  of 1, 2, 6, 7: 1 # BYTE ASCII SBYTE UNDEFINED
  of 3, 8: 2 # SHORT SSHORT
  of 4, 9, 11: 4 # LONG SLONG FLOAT
  of 5, 10, 12: 8 # RATIONAL SRATIONAL DOUBLE
  else: 0

proc err(code: UniImageError; msg: string): UniImageException =
  UniImageException(code: code, msg: msg)

proc parseIfd(data: openArray[byte]; off: int; le: bool): Table[uint16, TiffField] =
  ## Parse one IFD at `off` into a tag -> field table.
  if off < 0 or off + 2 > data.len:
    raise err(uiTruncated, "tiff: IFD offset out of range")
  let count = int(r16(data, off, le))
  if off + 2 + count * 12 + 4 > data.len:
    raise err(uiTruncated, "tiff: IFD entries truncated")
  for e in 0 ..< count:
    let base = off + 2 + e * 12
    let tag = uint16(r16(data, base, le))
    let typ = int(r16(data, base + 2, le))
    let cnt = int(r32(data, base + 4, le))
    let ts = typeSize(typ)
    if ts == 0:
      continue # unknown type — skip
    let total = cnt * ts
    var fbase: int
    if total <= 4:
      fbase = base + 8 # value fits inline in the 4-byte value field
    else:
      fbase = int(r32(data, base + 8, le))
      if fbase < 0 or fbase + total > data.len:
        raise err(uiTruncated, "tiff: field value out of range")
    var f: TiffField
    if typ in {5, 10}: # RATIONAL / SRATIONAL: pairs of LONGs
      f.kind = fkRat
      for k in 0 ..< cnt:
        let num = r32(data, fbase + k * 8, le)
        let den = r32(data, fbase + k * 8 + 4, le)
        f.rats.add (num, den)
    else:
      f.kind = fkInt
      for k in 0 ..< cnt:
        case ts
        of 1: f.ints.add uint32(data[fbase + k])
        of 2: f.ints.add uint32(r16(data, fbase + k * 2, le))
        of 4: f.ints.add r32(data, fbase + k * 4, le)
        else: discard # FLOAT/DOUBLE not needed for raster decode
    result[tag] = f

proc getU32(t: Table[uint16, TiffField]; tag: uint16; default: uint32): uint32 =
  ## First integer value of `tag`, or `default` if absent.
  if tag in t and t[tag].kind == fkInt and t[tag].ints.len > 0:
    t[tag].ints[0]
  else:
    default

proc getSeq(t: Table[uint16, TiffField]; tag: uint16): seq[uint32] =
  if tag in t: t[tag].ints else: @[]

# ---- LZW (TIFF variant, MSB-first, 9..12 bits, no early change) -------------

type BitSrc = object
  p: ptr UncheckedArray[byte]
  n: int
  pos: int
  buf: uint32
  cnt: int

proc initBitSrc(src: openArray[byte]): BitSrc =
  if src.len > 0:
    result.p = cast[ptr UncheckedArray[byte]](unsafeAddr src[0])
  result.n = src.len

proc readBits(s: var BitSrc; width: int): int =
  ## MSB-first read of `width` bits; -1 on end of stream.
  while s.cnt < width:
    if s.pos >= s.n:
      return -1
    s.buf = (s.buf shl 8) or uint32(s.p[s.pos])
    s.pos += 1
    s.cnt += 8
  s.cnt -= width
  int((s.buf shr s.cnt) and ((1'u32 shl uint32(width)) - 1))

proc lzwDecode(src: openArray[byte]; maxOut: int): seq[byte] =
  const Clear = 256
  const Eoi = 257
  if src.len == 0:
    return @[]
  result = newSeqOfCap[byte](maxOut)
  var bs = initBitSrc(src)
  var
    width = 9
    nextCode = 258
    prev = -1
    prefix: array[4096, int]
    suffix: array[4096, uint8]
    firstB: array[4096, uint8]
  for i in 0 .. 255:
    prefix[i] = -1
    suffix[i] = uint8(i)
    firstB[i] = uint8(i)
  var stack: array[8192, uint8] # reversed string buffer; bounded by code width
  while true:
    let code = readBits(bs, width)
    if code == -1:
      break # stream ended without EOI
    if code == Clear:
      width = 9
      nextCode = 258
      prev = -1
      continue
    if code == Eoi:
      break
    if prev == -1: # first code after Clear must be a literal
      if code > 255:
        raise err(uiInvalidArg, "tiff: bad LZW first code")
      result.add uint8(code)
      prev = code
      continue
    var entryFirst: uint8
    if code < nextCode:
      entryFirst = firstB[code]
      var k = code
      var sp = 0
      while k != -1:
        stack[sp] = suffix[k]; sp += 1; k = prefix[k]
      while sp > 0:
        sp -= 1; result.add stack[sp]
    elif code == nextCode: # KwKwK: prev + prev's first byte
      entryFirst = firstB[prev]
      var k = prev
      var sp = 0
      while k != -1:
        stack[sp] = suffix[k]; sp += 1; k = prefix[k]
      while sp > 0:
        sp -= 1; result.add stack[sp]
      result.add entryFirst
    else:
      raise err(uiInvalidArg, "tiff: bad LZW code")
    if nextCode < 4096:
      prefix[nextCode] = prev
      suffix[nextCode] = entryFirst
      firstB[nextCode] = firstB[prev]
      nextCode += 1
      # TIFF LZW uses the early-change variant: widen one code before the
      # table fills (at 2^width - 1, not 2^width). GIF/PDF use the late form.
      if nextCode == (1 shl width) - 1 and width < 12:
        width += 1
    prev = code
    if result.len > maxOut:
      raise err(uiInvalidArg, "tiff: LZW output exceeds expected size")

proc packbitsDecode(src: openArray[byte]; maxOut: int): seq[byte] =
  result = newSeqOfCap[byte](maxOut)
  var i = 0
  while i < src.len:
    let n = cast[int8](src[i]); i += 1
    if n >= 0 and n <= 127:
      let cnt = int(n) + 1
      if i + cnt > src.len:
        raise err(uiTruncated, "tiff: PackBits literal run truncated")
      for j in 0 ..< cnt:
        result.add src[i + j]
      i += cnt
    elif n >= -127 and n <= -1:
      let cnt = 1 - int(n)
      if i >= src.len:
        raise err(uiTruncated, "tiff: PackBits repeat run truncated")
      let b = src[i]; i += 1
      for _ in 0 ..< cnt:
        result.add b
    # n == -128: no-op
    if result.len > maxOut:
      raise err(uiInvalidArg, "tiff: PackBits output exceeds expected size")

proc applyPredictor(buf: var seq[byte]; rowBytes, rows, spp, bps: int;
    le: bool) =
  ## Undo horizontal differencing (predictor 2) on each row's byte stream.
  if bps == 8:
    let stride = spp
    for r in 0 ..< rows:
      let base = r * rowBytes
      var i = base + stride
      let endp = base + rowBytes
      while i < endp:
        buf[i] = buf[i] + buf[i - stride] # uint8 wraps mod 256
        i += 1
  elif bps == 16:
    let nsamp = rowBytes div 2
    let stride = spp
    for r in 0 ..< rows:
      let base = r * rowBytes
      for s in stride ..< nsamp:
        let pa = base + (s - stride) * 2
        let pb = base + s * 2
        let v = r16(buf, pb, le) + r16(buf, pa, le) # uint16 wraps mod 65536
        if le:
          buf[pb] = byte(v and 0xFF)
          buf[pb + 1] = byte((v shr 8) and 0xFF)
        else:
          buf[pb] = byte((v shr 8) and 0xFF)
          buf[pb + 1] = byte(v and 0xFF)

proc decodeChunk(data: openArray[byte]; off, byteCount, expected,
    compression: int; le: bool): seq[byte] =
  ## Decompress one strip/tile into `expected` bytes (raw raster).
  if byteCount <= 0:
    raise err(uiTruncated, "tiff: empty strip/tile")
  if off < 0 or off + byteCount > data.len:
    raise err(uiTruncated, "tiff: strip/tile bytes out of range")
  let last = off + byteCount - 1
  case compression
  of 1: # uncompressed
    result = newSeq[byte](byteCount)
    copyMem(addr result[0], unsafeAddr data[off], byteCount)
  of 32773:
    result = packbitsDecode(data.toOpenArray(off, last), expected)
  of 5:
    result = lzwDecode(data.toOpenArray(off, last), expected)
  of 8, 32946: # Deflate / old-style Deflate (both zlib-wrapped)
    result = zlibInflate(data.toOpenArray(off, last), expected)
  else:
    raise err(uiUnsupported, "tiff: compression " & $compression & " unsupported")

proc rowBytesFor(pixelW, spp, bps: int): int =
  ## Bytes per raster row for `pixelW` pixels (chunky, any bit depth).
  let bits = pixelW * spp * bps
  (bits + 7) div 8

proc scaleSubByte(v, bps: int): uint8 {.inline.} =
  case bps
  of 1: uint8(v * 255)
  of 2: uint8(v * 85)
  of 4: uint8(v * 17)
  else: uint8(v)

proc decodeTiff*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory TIFF (first IFD) into an 8-bit `Image`. Raises
  ## `UniImageException`.
  requireLen(data, 8, "tiff: header truncated")
  let le = data[0] == byte('I') and data[1] == byte('I')
  let be = data[0] == byte('M') and data[1] == byte('M')
  if not le and not be:
    raise err(uiUnsupported, "tiff: bad byte order")
  let magic = int(r16(data, 2, le))
  if magic != 42:
    raise err(uiUnsupported, "tiff: bad magic (not classic TIFF)")
  let ifdOff = int(r32(data, 4, le))
  let ifd = parseIfd(data, ifdOff, le)

  let width = int(ifd.getU32(uint16(tagImageWidth), 0))
  let height = int(ifd.getU32(uint16(tagImageLength), 0))
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise err(uiInvalidArg, "tiff: bad image dimensions")
  if int64(width) * int64(height) > int64(MaxCodecDim):
    raise err(uiInvalidArg, "tiff: image has too many pixels")
  let compression = int(ifd.getU32(uint16(tagCompression), 1))
  let photometric = int(ifd.getU32(uint16(tagPhotometric), 0))
  let sppIn = int(ifd.getU32(uint16(tagSamplesPerPixel), 1))
  let planar = int(ifd.getU32(uint16(tagPlanarConfig), 1))
  let predictor = int(ifd.getU32(uint16(tagPredictor), 1))
  let bpsSeq = ifd.getSeq(uint16(tagBitsPerSample))
  let bps = if bpsSeq.len >= 1: int(bpsSeq[0]) else: 1
  let sampleFmt = ifd.getSeq(uint16(tagSampleFormat))

  if planar != 1:
    raise err(uiUnsupported, "tiff: planar configuration 2 unsupported")
  if photometric == 6:
    raise err(uiUnsupported, "tiff: YCbCr unsupported")
  if sampleFmt.len > 0 and int(sampleFmt[0]) == 3:
    raise err(uiUnsupported, "tiff: floating-point samples unsupported")
  if compression != 1 and compression != 5 and compression != 8 and
      compression != 32773 and compression != 32946:
    raise err(uiUnsupported, "tiff: compression " & $compression & " unsupported")
  if bps notin {1, 4, 8, 16}:
    raise err(uiUnsupported, "tiff: " & $bps & "-bit samples unsupported")
  if bps < 8 and sppIn != 1:
    raise err(uiUnsupported, "tiff: sub-byte samples need spp=1")
  if predictor notin {1, 2}:
    raise err(uiUnsupported, "tiff: predictor " & $predictor & " unsupported")
  if predictor == 2 and bps notin {8, 16}:
    raise err(uiUnsupported, "tiff: predictor 2 needs 8/16-bit samples")

  # Output color space and channel count for the photometric.
  var outCh: int
  var cs: Colorspace
  var isPalette = false
  var isCmyk = false
  var hasAlpha = false
  case photometric
  of 0, 1: # grayscale (0 = WhiteIsZero, 1 = BlackIsZero)
    if sppIn == 1: outCh = 1; cs = csGray
    elif sppIn == 2: outCh = 4; cs = csRgba; hasAlpha = true
    else: raise err(uiUnsupported, "tiff: gray with spp=" & $sppIn & " unsupported")
  of 2: # RGB
    if sppIn == 3: outCh = 3; cs = csRgb
    elif sppIn == 4: outCh = 4; cs = csRgba; hasAlpha = true
    else: raise err(uiUnsupported, "tiff: RGB with spp=" & $sppIn & " unsupported")
  of 3: # palette
    if sppIn != 1: raise err(uiUnsupported, "tiff: palette needs spp=1")
    outCh = 3; cs = csRgb; isPalette = true
  of 4: # transparency mask (1-bit) -> grayscale
    if sppIn != 1: raise err(uiUnsupported, "tiff: mask needs spp=1")
    outCh = 1; cs = csGray
  of 5: # CMYK
    if sppIn != 4: raise err(uiUnsupported, "tiff: CMYK needs spp=4")
    outCh = 4; cs = csCmyk; isCmyk = true
  else:
    raise err(uiUnsupported, "tiff: photometric " & $photometric & " unsupported")

  # Palette (ColorMap): 3 * 2^bps uint16 entries, R then G then B.
  var cmap: seq[uint8] = @[] # packed 8-bit RGB, length 3 * N
  if isPalette:
    let raw = ifd.getSeq(uint16(tagColorMap))
    let n = 1 shl bps
    if raw.len < 3 * n:
      raise err(uiInvalidArg, "tiff: ColorMap too small")
    cmap = newSeq[uint8](3 * n)
    for i in 0 ..< n:
      cmap[i] = byte((raw[i] shr 8) and 0xFF) # R
      cmap[n + i] = byte((raw[n + i] shr 8) and 0xFF) # G
      cmap[2 * n + i] = byte((raw[2 * n + i] shr 8) and 0xFF) # B

  let bytesPerSample = bps div 8
  let alphaIdx = sppIn - 1 # extra samples are the trailing ones
  result = newImage[uint8](width, height, cs)

  # Build the chunk list (strips or tiles), each: (tileW, tileH, dstX, dstY).
  var chunks: seq[tuple[tw, th, dx, dy, off, bc: int]]
  let hasTiles = uint16(tagTileWidth) in ifd
  if hasTiles:
    let twFull = int(ifd.getU32(uint16(tagTileWidth), 0))
    let thFull = int(ifd.getU32(uint16(tagTileLength), 0))
    if twFull <= 0 or thFull <= 0:
      raise err(uiInvalidArg, "tiff: bad tile dimensions")
    let toffs = ifd.getSeq(uint16(tagTileOffsets))
    let tbc = ifd.getSeq(uint16(tagTileByteCounts))
    let cols = (width + twFull - 1) div twFull
    let rowsT = (height + thFull - 1) div thFull
    if toffs.len < cols * rowsT or tbc.len < cols * rowsT:
      raise err(uiTruncated, "tiff: tile offset/count table truncated")
    for ty in 0 ..< rowsT:
      for tx in 0 ..< cols:
        let idx = ty * cols + tx
        let tw = min(twFull, width - tx * twFull)
        let th = min(thFull, height - ty * thFull)
        chunks.add((tw, th, tx * twFull, ty * thFull,
            int(toffs[idx]), int(tbc[idx])))
  else:
    let rps0 = int(ifd.getU32(uint16(tagRowsPerStrip), uint32(height)))
    let rps = if rps0 <= 0: height else: rps0
    let soffs = ifd.getSeq(uint16(tagStripOffsets))
    let sbc = ifd.getSeq(uint16(tagStripByteCounts))
    let nStrips = (height + rps - 1) div rps
    if soffs.len < nStrips or sbc.len < nStrips:
      raise err(uiTruncated, "tiff: strip offset/count table truncated")
    for s in 0 ..< nStrips:
      let th = min(rps, height - s * rps)
      chunks.add((width, th, 0, s * rps, int(soffs[s]), int(sbc[s])))

  if sppIn > 6:
    raise err(uiUnsupported, "tiff: sample count exceeds decoder capacity")

  for ch in chunks:
    let (tw, th, dx, dy, coff, cbc) = ch
    let rb = rowBytesFor(tw, sppIn, bps)
    let expected = rb * th
    var buf = decodeChunk(data, coff, cbc, expected, compression, le)
    if buf.len < expected:
      raise err(uiTruncated, "tiff: decoded strip/tile too short")
    if predictor == 2:
      applyPredictor(buf, rb, th, sppIn, bps, le)
    for y in 0 ..< th:
      let outY = dy + y
      if outY >= height:
        break
      let rowBase = y * rb
      for x in 0 ..< tw:
        let outX = dx + x
        if outX >= width:
          break
        let outOff = (outY * width + outX) * outCh
        if isPalette:
          let idx = if bps >= 8: int(buf[rowBase + x])
                    else: (int(buf[rowBase + (x * bps) shr 3]) shr
                        (8 - bps - ((x * bps) and 7))) and ((1 shl bps) - 1)
          let n = 1 shl bps
          if idx >= n:
            raise err(uiInvalidArg, "tiff: palette index out of range")
          result.data[outOff] = cmap[idx]
          result.data[outOff + 1] = cmap[n + idx]
          result.data[outOff + 2] = cmap[2 * n + idx]
        else:
          # Gather sppIn samples as 8-bit values.
          var sv: array[6, uint8]
          if bps >= 8:
            for s in 0 ..< sppIn:
              let off = rowBase + x * sppIn * bytesPerSample + s * bytesPerSample
              if bps == 8: sv[s] = buf[off]
              else: sv[s] = byte(r16(buf, off, le) shr 8)
          else: # sub-byte grayscale, sppIn == 1
            let bit = x * bps
            let v = (int(buf[rowBase + bit shr 3]) shr
                (8 - bps - (bit and 7))) and ((1 shl bps) - 1)
            sv[0] = scaleSubByte(v, bps)
          if isCmyk:
            for s in 0 ..< 4: result.data[outOff + s] = sv[s]
          elif outCh == 1: # gray (or mask)
            var g = sv[0]
            if photometric == 0 or photometric == 4: g = 255 - g
            result.data[outOff] = g
          elif outCh == 3: # RGB
            result.data[outOff] = sv[0]
            result.data[outOff + 1] = sv[1]
            result.data[outOff + 2] = sv[2]
          elif outCh == 4 and hasAlpha and photometric in {0, 1}: # gray + alpha
            var g = sv[0]
            if photometric == 0: g = 255 - g
            result.data[outOff] = g
            result.data[outOff + 1] = g
            result.data[outOff + 2] = g
            result.data[outOff + 3] = sv[1]
          else: # RGBA (RGB + extra alpha)
            result.data[outOff] = sv[0]
            result.data[outOff + 1] = sv[1]
            result.data[outOff + 2] = sv[2]
            result.data[outOff + 3] = sv[alphaIdx]
