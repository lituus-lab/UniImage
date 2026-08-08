# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Baseline JPEG decoder. Reimplemented from T.81/JFIF — not vendored. Supports
## 8-bit precision, sequential (baseline, SOF0), Huffman coding, 1 or 3
## components (grayscale -> csGray, YCbCr -> csRgb), arbitrary H/V sampling
## factors with nearest-neighbour chroma upsampling, and restart markers
## (RSTn/DRI). Progressive (SOF2), arithmetic coding, 12-bit, and CMYK/adobe
## 4-component raise `uiUnsupported`. IDCT is a straightforward separable
## reference transform — readable over fast.
import std/[math]
import UniImage/core
import util

const
  ZigZag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26,
      33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50,
      43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46,
      53, 60, 61, 54, 47, 55, 62, 63]
  JpegPi = 3.14159265358979'f32

static: doAssert ZigZag.len == 64,
  "ZigZag must list all 64 coefficients"

let
  Cu: array[8, float32] = [float32(1.0 / sqrt(2.0)), 1'f32, 1'f32, 1'f32, 1'f32,
      1'f32, 1'f32, 1'f32]
  CosT: array[8, array[8, float32]] = block:
    var t: array[8, array[8, float32]]
    for x in 0 .. 7:
      for u in 0 .. 7:
        t[x][u] = cos(float32((2 * x + 1) * u) * JpegPi / 16'f32)
    t

type
  QuantTable = array[64, int] # in zigzag order, as stored in DQT
  HuffTable = object
    minCode: array[17, int]
    maxCode: array[17, int]
    symOffset: array[17, int]
    symbols: seq[byte]
    valid: bool
  Comp = object
    id, h, v, qt, td, ta: int

proc buildHuff(counts: openArray[byte]; symbols: openArray[byte]): HuffTable =
  result.symbols = @symbols
  result.valid = true
  var code = 0
  var k = 0
  for l in 1 .. 16:
    let c = int(counts[l - 1])
    if c > 0:
      result.minCode[l] = code
      result.maxCode[l] = code + c - 1
      result.symOffset[l] = k
      code += c
      k += c
    else:
      result.maxCode[l] = -1
    code = code shl 1

type
  Bits = object
    data: seq[byte]
    pos: int
    buf: uint32
    cnt: int

proc readBit(b: var Bits): int =
  if b.cnt == 0:
    if b.pos >= b.data.len:
      raise UniImageException(code: uiTruncated,
          msg: "jpeg: entropy stream truncated")
    b.buf = uint32(b.data[b.pos])
    inc b.pos
    b.cnt = 8
  dec b.cnt
  result = int((b.buf shr b.cnt) and 1)

proc decodeSym(ht: HuffTable; b: var Bits): int =
  var code = readBit(b)
  for l in 1 .. 16:
    if code <= ht.maxCode[l]:
      return int(ht.symbols[ht.symOffset[l] + (code - ht.minCode[l])])
    code = (code shl 1) or readBit(b)
  raise UniImageException(code: uiInvalidArg, msg: "jpeg: bad Huffman code")

proc receive(b: var Bits; ssss: int): int =
  result = 0
  for _ in 0 ..< ssss: result = (result shl 1) or readBit(b)

proc extend(v, ssss: int): int =
  if ssss == 0: return 0
  let half = 1 shl (ssss - 1)
  if v < half: result = v - ((1 shl ssss) - 1)
  else: result = v

proc idct(f: array[64, float32]): array[64, float32] =
  ## Separable 8x8 inverse DCT (reference, not the fastest).
  var tmp: array[64, float32]
  for v in 0 .. 7: # 1D IDCT across each row (frequency u -> spatial x)
    for x in 0 .. 7:
      var s = 0.0'f32
      for u in 0 .. 7: s += Cu[u] * f[v * 8 + u] * CosT[x][u]
      tmp[v * 8 + x] = s
  for x in 0 .. 7: # 1D IDCT down each column (frequency v -> spatial y)
    for y in 0 .. 7:
      var s = 0.0'f32
      for v in 0 .. 7: s += Cu[v] * tmp[v * 8 + x] * CosT[y][v]
      result[y * 8 + x] = s * 0.25'f32

proc decodeBlock(b: var Bits; dc, ac: HuffTable; qt: QuantTable;
    pred: var int): array[64, float32] =
  var nat: array[64, float32]
  let s = decodeSym(dc, b)
  let diff = extend(receive(b, s), s)
  pred += diff
  nat[0] = float32(pred) * float32(qt[0])
  var k = 1
  while k < 64:
    let rs = decodeSym(ac, b)
    let r = rs shr 4
    let ssss = rs and 0x0F
    if ssss == 0:
      if r == 15: k += 16 # ZRL: skip 16 zeros
      else: break # EOB: rest of the block is zero
    else:
      k += r
      if k >= 64:
        raise UniImageException(code: uiInvalidArg,
            msg: "jpeg: AC index out of range")
      let v = extend(receive(b, ssss), ssss)
      nat[ZigZag[k]] = float32(v) * float32(qt[k])
      inc k
  result = idct(nat)

proc clamp8(v: float32): uint8 {.inline.} =
  let x = int(v + 128.5'f32)
  if x < 0: 0'u8 elif x > 255: 255'u8 else: uint8(x)

proc decodeJpeg*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory baseline JPEG into an 8-bit `Image`. Raises
  ## `UniImageException`.
  requireLen(data, 2, "jpeg: header truncated")
  if data[0] != 0xFF or data[1] != 0xD8:
    raise UniImageException(code: uiUnsupported, msg: "jpeg: bad SOI")
  var pos = 2
  var quant: array[4, QuantTable]
  var dcTab: array[4, HuffTable]
  var acTab: array[4, HuffTable]
  var comps: seq[Comp]
  var width, height, hMax, vMax: int
  var restartInterval = 0
  var entropyStart = -1
  while pos + 1 < data.len:
    if data[pos] != 0xFF:
      raise UniImageException(code: uiInvalidArg, msg: "jpeg: expected marker")
    inc pos
    while pos < data.len and data[pos] == 0xFF: inc pos # padding
    if pos >= data.len: break
    let marker = data[pos]; inc pos
    if marker == 0xD9: break # EOI
    if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7): continue # standalone
    requireLen(data, pos + 2, "jpeg: marker length truncated")
    let segLen = int(readU16be(data, pos))
    if segLen < 2 or pos + segLen > data.len:
      raise UniImageException(code: uiTruncated, msg: "jpeg: segment truncated")
    let segStart = pos + 2
    let segEnd = pos + segLen
    case marker
    of 0xDB: # DQT
      var p = segStart
      while p < segEnd:
        if p + 1 > segEnd:
          raise UniImageException(code: uiTruncated, msg: "jpeg: DQT truncated")
        let pq = int(data[p]) shr 4
        let tq = int(data[p]) and 0x0F
        inc p
        if tq > 3:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: bad quant table id")
        let step = if pq == 0: 1 else: 2
        if p + 64 * step > segEnd:
          raise UniImageException(code: uiTruncated,
              msg: "jpeg: quant values truncated")
        for i in 0 ..< 64:
          quant[tq][i] = if pq == 0: int(data[p + i])
                         else: int(readU16be(data, p + i * 2))
        p += 64 * step
    of 0xC4: # DHT
      var p = segStart
      while p < segEnd:
        if p + 17 > segEnd:
          raise UniImageException(code: uiTruncated, msg: "jpeg: DHT truncated")
        let tc = int(data[p]) shr 4
        let th = int(data[p]) and 0x0F
        inc p
        if th > 3:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: bad Huffman table id")
        var counts: array[16, byte]
        for i in 0 ..< 16: counts[i] = data[p + i]
        p += 16
        var total = 0
        for c in counts: total += int(c)
        if p + total > segEnd:
          raise UniImageException(code: uiTruncated,
              msg: "jpeg: Huffman symbols truncated")
        let syms = data[p ..< p + total]
        p += total
        let ht = buildHuff(counts, syms)
        if tc == 0: dcTab[th] = ht else: acTab[th] = ht
    of 0xC0: # SOF0 (baseline)
      if segEnd - segStart < 8:
        raise UniImageException(code: uiTruncated, msg: "jpeg: SOF0 truncated")
      let prec = int(data[segStart])
      if prec != 8:
        raise UniImageException(code: uiUnsupported,
            msg: "jpeg: non-8-bit precision")
      height = int(readU16be(data, segStart + 1))
      width = int(readU16be(data, segStart + 3))
      let nf = int(data[segStart + 5])
      if nf notin {1, 3}:
        raise UniImageException(code: uiUnsupported,
            msg: "jpeg: unsupported component count")
      if segStart + 6 + nf * 3 > segEnd:
        raise UniImageException(code: uiTruncated,
            msg: "jpeg: SOF0 components truncated")
      comps = newSeq[Comp](nf)
      hMax = 1; vMax = 1
      for i in 0 ..< nf:
        let base = segStart + 6 + i * 3
        comps[i].id = int(data[base])
        comps[i].h = int(data[base + 1]) shr 4
        comps[i].v = int(data[base + 1]) and 0x0F
        comps[i].qt = int(data[base + 2])
        if comps[i].h == 0 or comps[i].v == 0 or comps[i].h > 4 or comps[i].v > 4:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: bad sampling factor")
        if comps[i].qt > 3:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: bad quant table ref")
        if comps[i].h > hMax: hMax = comps[i].h
        if comps[i].v > vMax: vMax = comps[i].v
      if width == 0 or height == 0 or width > MaxCodecDim or height > MaxCodecDim:
        raise UniImageException(code: uiInvalidArg, msg: "jpeg: bad dimensions")
    of 0xC2:
      raise UniImageException(code: uiUnsupported,
          msg: "jpeg: progressive unsupported")
    of 0xC9, 0xCA:
      raise UniImageException(code: uiUnsupported,
          msg: "jpeg: arithmetic/12-bit unsupported")
    of 0xDD: # DRI
      if segEnd - segStart < 2:
        raise UniImageException(code: uiTruncated, msg: "jpeg: DRI truncated")
      restartInterval = int(readU16be(data, segStart))
    of 0xDA: # SOS
      if comps.len == 0:
        raise UniImageException(code: uiInvalidArg,
            msg: "jpeg: SOS before SOF0")
      if segEnd - segStart < 6:
        raise UniImageException(code: uiTruncated, msg: "jpeg: SOS truncated")
      let ns = int(data[segStart])
      if ns != comps.len:
        raise UniImageException(code: uiInvalidArg,
            msg: "jpeg: SOS component mismatch")
      var p = segStart + 1
      for i in 0 ..< ns:
        if p + 2 > segEnd:
          raise UniImageException(code: uiTruncated,
              msg: "jpeg: SOS selectors truncated")
        let cid = int(data[p])
        let sel = data[p + 1]
        p += 2
        var found = -1
        for j in 0 ..< comps.len:
          if comps[j].id == cid: found = j; break
        if found < 0:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: SOS unknown component")
        comps[found].td = int(sel) shr 4
        comps[found].ta = int(sel) and 0x0F
        if comps[found].td > 3 or comps[found].ta > 3:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: bad Huffman table ref")
      for i in 0 ..< ns:
        if not dcTab[comps[i].td].valid or not acTab[comps[i].ta].valid:
          raise UniImageException(code: uiInvalidArg,
              msg: "jpeg: scan references an undefined Huffman table")
      entropyStart = segEnd
      break
    else: discard # APPn, COM, etc. — skipped by segment length
    pos = segEnd
  if entropyStart < 0:
    raise UniImageException(code: uiInvalidArg, msg: "jpeg: no scan (SOS)")
  if width == 0 or height == 0:
    raise UniImageException(code: uiInvalidArg, msg: "jpeg: no frame (SOF0)")

  # Preprocess the entropy segment: drop FF00 stuffing, split on RSTn, stop at EOI.
  var clean: seq[byte] = @[]
  var restarts: seq[int] = @[]
  var i = entropyStart
  while i < data.len:
    if data[i] == 0xFF:
      if i + 1 >= data.len: break
      let n = data[i + 1]
      if n == 0x00: clean.add(0xFF); i += 2
      elif n >= 0xD0 and n <= 0xD7: restarts.add(clean.len); i += 2
      elif n == 0xD9: break
      else: raise UniImageException(code: uiInvalidArg,
          msg: "jpeg: bad marker in entropy")
    else:
      clean.add(data[i]); inc i

  let nf = comps.len
  var b = Bits(data: clean)
  let mcuW = hMax * 8
  let mcuH = vMax * 8
  let mcusX = (width + mcuW - 1) div mcuW
  let mcusY = (height + mcuH - 1) div mcuH
  # Per-component sample buffers sized to the MCU grid: each MCU contributes
  # comps[c].h x comps[c].v blocks, so the grid holds mcusX*h x mcusY*v blocks.
  var bufW: seq[int] = newSeq[int](nf)
  var bufH: seq[int] = newSeq[int](nf)
  var cbuf: seq[seq[float32]] = newSeq[seq[float32]](nf)
  for c in 0 ..< nf:
    bufW[c] = mcusX * comps[c].h * 8
    bufH[c] = mcusY * comps[c].v * 8
    cbuf[c] = newSeq[float32](bufW[c] * bufH[c])
  var pred: array[4, int]
  var nextRst = 0
  var mcuCount = 0

  proc resetPred() =
    for c in 0 ..< nf: pred[c] = 0

  for my in 0 ..< mcusY:
    for mx in 0 ..< mcusX:
      for c in 0 ..< nf:
        for bi in 0 ..< comps[c].h * comps[c].v:
          let blk = decodeBlock(b, dcTab[comps[c].td], acTab[comps[c].ta],
              quant[comps[c].qt], pred[c])
          let br = my * comps[c].v + bi div comps[c].h
          let bc = mx * comps[c].h + bi mod comps[c].h
          let off = br * 8 * bufW[c] + bc * 8
          for y in 0 .. 7:
            for x in 0 .. 7:
              cbuf[c][off + y * bufW[c] + x] = blk[y * 8 + x]
      inc mcuCount
      if restartInterval > 0 and mcuCount mod restartInterval == 0 and
          nextRst < restarts.len:
        b.pos = restarts[nextRst]
        b.cnt = 0
        resetPred()
        inc nextRst

  let outCs = if nf == 1: csGray else: csRgb
  result = newImage[uint8](width, height, outCs)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let yVal = cbuf[0][(y * comps[0].v div vMax) * bufW[0] + (x * comps[0].h div hMax)]
      if nf == 1:
        result.data[y * width + x] = clamp8(yVal)
      else:
        let cbX = x * comps[1].h div hMax
        let cbY = y * comps[1].v div vMax
        let crX = x * comps[2].h div hMax
        let crY = y * comps[2].v div vMax
        let cb = cbuf[1][cbY * bufW[1] + cbX]
        let cr = cbuf[2][crY * bufW[2] + crX]
        # cb/cr are raw IDCT outputs (pixel - 128); clamp8 adds the level shift
        # back, so the conversion uses them directly.
        let yL = float32(yVal)
        let r = yL + 1.402'f32 * cr
        let g = yL - 0.344136'f32 * cb - 0.714136'f32 * cr
        let bl = yL + 1.772'f32 * cb
        let o = (y * width + x) * 3
        result.data[o] = clamp8(r)
        result.data[o + 1] = clamp8(g)
        result.data[o + 2] = clamp8(bl)

# ---- JPEG encode (baseline SOF0) ------------------------------------------
# The inverse of `decodeJpeg` for csGray (1 component) and csRgb (3 components,
# 4:4:4 — all sampling factors 1, so no chroma subsampling: simpler and still a
# valid JFIF stream the decoder reads back). The forward DCT is the separable
# transpose of the decoder's `idct`; quantization divides by the (quality-scaled)
# Annex K tables; entropy coding uses the standard Annex K Huffman tables,
# emitted verbatim in DHT so any decoder (ours included) reads them. The result
# is lossy via DCT + quantization only — a structural round-trip, not byte-exact.

const
  # Annex K base quant tables, NATURAL (row-major) order. Scaled per quality at
  # encode time; output in zigzag order. Provenance: ITU-T T.81 Annex K (public
  # standard). Verified against a Pillow/libjpeg JPEG (which uses these verbatim).
  QlumNat*: array[64, int] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
  QchrNat*: array[64, int] = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99]
  # Standard Huffman tables (Annex K), bits counts + symbol values.
  Dc0Bits*: array[16, uint8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
  Dc0Syms*: array[12, uint8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
  Dc1Bits*: array[16, uint8] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
  Dc1Syms*: array[12, uint8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
  Ac0Bits*: array[16, uint8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125]
  Ac0Syms*: array[162, uint8] = [
    1, 2, 3, 0, 4, 17, 5, 18, 33, 49, 65, 6, 19, 81, 97, 7, 34, 113, 20, 50, 129,
    145, 161, 8, 35, 66, 177, 193, 21, 82, 209, 240, 36, 51, 98, 114, 130, 9, 10,
    22, 23, 24, 25, 26, 37, 38, 39, 40, 41, 42, 52, 53, 54, 55, 56, 57, 58, 67,
    68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101,
    102, 103, 104, 105, 106, 115, 116, 117, 118, 119, 120, 121, 122, 131, 132,
    133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154,
    162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183,
    184, 185, 186, 194, 195, 196, 197, 198, 199, 200, 201, 202, 210, 211, 212,
    213, 214, 215, 216, 217, 218, 225, 226, 227, 228, 229, 230, 231, 232, 233,
    234, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250]
  Ac1Bits*: array[16, uint8] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119]
  Ac1Syms*: array[162, uint8] = [
    0, 1, 2, 3, 17, 4, 5, 33, 49, 6, 18, 65, 81, 7, 97, 113, 19, 34, 50, 129,
    8, 20, 66, 145, 161, 177, 193, 9, 35, 51, 82, 240, 21, 98, 114, 209, 10, 22,
    36, 52, 225, 37, 241, 23, 24, 25, 26, 38, 39, 40, 41, 42, 53, 54, 55, 56,
    57, 58, 67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99,
    100, 101, 102, 103, 104, 105, 106, 115, 116, 117, 118, 119, 120, 121, 122,
    130, 131, 132, 133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151,
    152, 153, 154, 162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180,
    181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198, 199, 200, 201, 202,
    210, 211, 212, 213, 214, 215, 216, 217, 218, 226, 227, 228, 229, 230, 231,
    232, 233, 234, 242, 243, 244, 245, 246, 247, 248, 249, 250]

type
  HuffEnc = object
    code: array[256, uint32]
    len: array[256, int] # 0 = no code for that symbol

proc buildHuffEnc(bits: openArray[byte]; syms: openArray[byte]): HuffEnc =
  ## Canonical Huffman code assignment (RFC/JPEG): codes of length l are
  ## assigned in symbol order, incrementing, then shifted left for the next
  ## length. Matches the decoder's `buildHuff` code progression.
  var code = 0'u32
  var k = 0
  for l in 1 .. 16:
    let c = int(bits[l - 1])
    for _ in 0 ..< c:
      result.code[syms[k]] = code
      result.len[syms[k]] = l
      inc code
      inc k
    code = code shl 1

type JBits = object
  out8: seq[byte]
  buf: uint32
  cnt: int

proc putBit(j: var JBits; b: uint32) {.inline.} =
  j.buf = (j.buf shl 1) or (b and 1)
  inc j.cnt
  if j.cnt == 8:
    let b8 = byte(j.buf and 0xFF)
    j.out8.add b8
    if b8 == 0xFF: j.out8.add 0x00 # FF -> FF00 byte stuffing
    j.buf = 0
    j.cnt = 0

proc putBits(j: var JBits; v: uint32; n: int) {.inline.} =
  ## Write `n` bits MSB-first (JPEG entropy coding is MSB-first within bytes).
  if n == 0: return
  for k in countdown(n - 1, 0): putBit(j, (v shr k) and 1)

proc putHuff(j: var JBits; he: HuffEnc; sym: int) {.inline.} =
  putBits(j, he.code[sym], he.len[sym])

proc flush(j: var JBits) =
  if j.cnt > 0:
    # Pad the final byte with 1 bits (the decoder stops at the last symbol, so
    # the padding is never read; 1-bits are the spec-recommended fill).
    let pad = 8 - j.cnt
    j.buf = (j.buf shl pad) or ((uint32(1) shl pad) - 1)
    let b8 = byte(j.buf and 0xFF)
    j.out8.add b8
    if b8 == 0xFF: j.out8.add 0x00
    j.buf = 0
    j.cnt = 0

proc fdct(p: array[64, float32]): array[64, float32] =
  ## Separable 8x8 forward DCT, the transpose of `idct`. F[v][u] = 0.25 *
  ## Cu[u]*Cu[v] * Σ_x Σ_y p[y][x] * CosT[x][u] * CosT[y][v].
  var tmp: array[64, float32] # tmp[y][u] = Cu[u] * Σ_x p CosT[x][u]
  for y in 0 .. 7:
    for u in 0 .. 7:
      var s = 0.0'f32
      for x in 0 .. 7: s += p[y * 8 + x] * CosT[x][u]
      tmp[y * 8 + u] = Cu[u] * s
  for u in 0 .. 7:
    for v in 0 .. 7:
      var s = 0.0'f32
      for y in 0 .. 7: s += tmp[y * 8 + u] * CosT[y][v]
      result[v * 8 + u] = 0.25'f32 * Cu[v] * s

proc scaleQt(base: array[64, int]; quality: int): array[64, int] =
  let q = max(1, min(100, quality))
  let scale = if q < 50: 5000 div q else: 200 - 2 * q
  for i in 0 .. 63:
    var v = (base[i] * scale + 50) div 100
    if v < 1: v = 1
    elif v > 255: v = 255 # 8-bit quantization values
    result[i] = v

proc bitSize(v: int): int {.inline.} =
  let a = if v < 0: -v else: v
  if a == 0: return 0
  var t = a
  while t > 0: t = t shr 1; inc result

proc encBlock(j: var JBits; blk: array[64, float32]; qnat: array[64, int];
    dcHe, acHe: HuffEnc; pred: var int) =
  let f = fdct(blk)
  # Quantize in zigzag scan order; qt for position k is qnat[natural ZigZag[k]].
  var zz: array[64, int]
  for k in 0 .. 63:
    let n = ZigZag[k]
    let q = float32(qnat[n])
    let r = f[n] / q
    zz[k] = int(if r >= 0: r + 0.5'f32 else: r - 0.5'f32) # round half away from 0
  # DC: difference-coded.
  let dc = zz[0]
  let diff = dc - pred
  pred = dc
  let s = bitSize(diff)
  putHuff(j, dcHe, s)
  if s > 0: putBits(j, uint32(if diff >= 0: diff else: diff - 1), s)
  # AC: run-length of zeros + (run, size) symbols.
  var run = 0
  for k in 1 .. 63:
    let v = zz[k]
    if v == 0: inc run
    else:
      while run >= 16:
        putHuff(j, acHe, 0xF0) # ZRL: 16 zeros
        run -= 16
      let s2 = bitSize(v)
      putHuff(j, acHe, (run shl 4) or s2)
      putBits(j, uint32(if v >= 0: v else: v - 1), s2)
      run = 0
  if run > 0: putHuff(j, acHe, 0x00) # EOB: trailing zeros

proc marker(r: var seq[byte]; m: int) {.inline.} = r.add 0xFF'u8; r.add byte(m)
proc segU16(r: var seq[byte]; v: int) {.inline.} =
  r.add byte((v shr 8) and 0xFF); r.add byte(v and 0xFF)

proc encodeJpeg*(img: Image[uint8]; quality = 90): seq[byte] =
  ## Encode an 8-bit `Image` as a baseline (SOF0) JFIF JPEG. csGray -> 1
  ## component; csRgb -> 3 components 4:4:4 (no chroma subsampling). `quality`
  ## 1..100 scales the Annex K quant tables. Raises `UniImageException` for
  ## other color spaces or bad dimensions. Lossy via DCT + quantization; the
  ## decoder reads it back structurally (dimensions, color space, coarse pixels).
  if img.colorspace notin {csGray, csRgb}:
    raise UniImageException(code: uiUnsupported,
        msg: "jpeg: encode needs csGray or csRgb")
  if img.width == 0 or img.height == 0 or img.width > MaxCodecDim or
      img.height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "jpeg: bad dimensions")
  let nf = if img.colorspace == csGray: 1 else: 3
  let qlum = scaleQt(QlumNat, quality)
  let qchr = scaleQt(QchrNat, quality)
  let dcLum = buildHuffEnc(Dc0Bits, Dc0Syms)
  let acLum = buildHuffEnc(Ac0Bits, Ac0Syms)
  let dcChr = buildHuffEnc(Dc1Bits, Dc1Syms)
  let acChr = buildHuffEnc(Ac1Bits, Ac1Syms)
  result = newSeqOfCap[byte](256 + img.data.len)
  marker(result, 0xD8) # SOI
  # APP0 (JFIF 1.01, no units, no thumbnail).
  marker(result, 0xE0)
  segU16(result, 16)
  for c in "JFIF": result.add byte(c)
  result.add 0x00
  result.add 0x01; result.add 0x01 # version 1.01
  result.add 0x00 # units: none
  segU16(result, 1); segU16(result, 1) # 1x1 pixel density
  result.add 0x00; result.add 0x00 # no thumbnail
  # DQT: luminance (tq=0), and chrominance (tq=1) only when 3 components.
  marker(result, 0xDB)
  let nqt = if nf == 3: 2 else: 1
  segU16(result, 2 + nqt * 65)
  for tq in 0 ..< nqt:
    result.add byte(tq) # pq=0 (8-bit), table id
    let qnat = if tq == 0: qlum else: qchr
    for k in 0 .. 63: result.add byte(qnat[ZigZag[k]]) # zigzag-scan order
  # SOF0: 8-bit, h/v sampling 1 for every component (4:4:4).
  marker(result, 0xC0)
  segU16(result, 8 + nf * 3)
  result.add 0x08 # precision
  segU16(result, img.height); segU16(result, img.width)
  result.add byte(nf)
  for c in 0 ..< nf:
    result.add byte(c + 1) # component id 1..3
    result.add 0x11 # h=1, v=1
    result.add byte(if c == 0: 0 else: 1) # qt: 0 luminance, 1 chrominance
  # DHT: DC+AC for luminance, plus chrominance when 3 components.
  proc emitDht(r: var seq[byte]; tc, th: int; bits: openArray[byte];
      syms: openArray[byte]) =
    r.add byte((tc shl 4) or th)
    for b in bits: r.add b
    for s in syms: r.add s
  marker(result, 0xC4)
  var dhtLen = 2
  if nf == 3:
    dhtLen += (1 + 16 + Dc0Syms.len) + (1 + 16 + Dc1Syms.len) +
        (1 + 16 + Ac0Syms.len) + (1 + 16 + Ac1Syms.len)
  else:
    dhtLen += (1 + 16 + Dc0Syms.len) + (1 + 16 + Ac0Syms.len)
  segU16(result, dhtLen)
  result.emitDht(0, 0, Dc0Bits, Dc0Syms)
  if nf == 3: result.emitDht(0, 1, Dc1Bits, Dc1Syms)
  result.emitDht(1, 0, Ac0Bits, Ac0Syms)
  if nf == 3: result.emitDht(1, 1, Ac1Bits, Ac1Syms)
  # SOS.
  marker(result, 0xDA)
  segU16(result, 2 + 1 + nf * 2 + 3)
  result.add byte(nf)
  for c in 0 ..< nf:
    result.add byte(c + 1)
    result.add byte(if c == 0: 0x00 else: 0x11) # td/ta: lum 0/0, chrom 1/1
  result.add 0x00; result.add 0x3F; result.add 0x00 # Ss=0, Se=63, Ah=0|Al=0
  # Entropy: encode each 8x8 block of the MCU grid (padded by edge replication).
  var j: JBits
  let pw = ((img.width + 7) div 8) * 8
  let ph = ((img.height + 7) div 8) * 8
  var pred: array[4, int]
  for by in 0 ..< ph div 8:
    for bx in 0 ..< pw div 8:
      for c in 0 ..< nf:
        var blk: array[64, float32]
        for yy in 0 .. 7:
          for xx in 0 .. 7:
            let px = min(bx * 8 + xx, img.width - 1)
            let py = min(by * 8 + yy, img.height - 1)
            if nf == 1:
              blk[yy * 8 + xx] = float32(img.data[py * img.width + px]) - 128.0'f32
            else:
              let o = (py * img.width + px) * 3
              let r = float32(img.data[o])
              let g = float32(img.data[o + 1])
              let b = float32(img.data[o + 2])
              blk[yy * 8 + xx] = case c
                of 0: 0.299'f32 * r + 0.587'f32 * g + 0.114'f32 * b - 128.0'f32
                of 1: -0.168736'f32 * r - 0.331264'f32 * g + 0.5'f32 * b
                else: 0.5'f32 * r - 0.418688'f32 * g - 0.081312'f32 * b
        let qnat = if c == 0: qlum else: qchr
        encBlock(j, blk, qnat, if c == 0: dcLum else: dcChr,
            if c == 0: acLum else: acChr, pred[c])
  j.flush()
  result.add j.out8
  marker(result, 0xD9) # EOI
