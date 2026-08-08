# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## WebP decoder — RIFF container + VP8L (lossless) bitstream. Reimplemented
## from the "Specification for WebP Lossless Bitstream" (Jyrji Alakuijala,
## Google) and the RIFF/container spec — not vendored. VP8 (lossy) is not yet
## implemented: the container is parsed and the lossy payload is reported as
## `uiUnsupported` rather than decoded incorrectly. Alpha reaches us two ways:
## in-stream for a standalone VP8L, or via an `ALPH` chunk under `VP8X`; both
## are merged into a 4-channel `csRgba` result.
import UniImage/core
import ./util

const WebpMaxDim = 16384 # VP8L canvas cap (14-bit width/height fields).

proc divRoundUp(a, b: int): int {.inline.} = (a + b - 1) div b

# ---------------------------------------------------------------------------
# Bit reader — LSB-first within each byte, the order VP8L consumes bits.
# ---------------------------------------------------------------------------

type
  BitReader = object
    data: ptr UncheckedArray[byte]
    len: int
    bytePos: int # next byte to pull from
    bitPos: int  # 0..7, LSB position within the current byte

proc initBitReader(data: openArray[byte]; startByte: int): BitReader =
  result.data = cast[ptr UncheckedArray[byte]](unsafeAddr data[0])
  result.len = data.len
  result.bytePos = startByte
  result.bitPos = 0

proc readBit(b: var BitReader): uint32 =
  if b.bytePos >= b.len:
    raise UniImageException(code: uiTruncated, msg: "webp: bitstream truncated")
  let v = (uint32(b.data[b.bytePos]) shr b.bitPos) and 1
  inc b.bitPos
  if b.bitPos == 8:
    b.bitPos = 0
    inc b.bytePos
  v

proc readBits(b: var BitReader; n: int): uint32 =
  ## Read `n` bits LSB-first into a 32-bit value (first bit read = bit 0).
  if n <= 0: return 0
  if n > 32:
    raise UniImageException(code: uiInvalidArg, msg: "webp: readBits > 32")
  result = 0
  for i in 0 ..< n:
    result = result or (b.readBit() shl i)

# ---------------------------------------------------------------------------
# Canonical Huffman. VP8L reads code bits LSB-first, so the canonical integer
# code is consumed with its LSB first — we accumulate the path the same way and
# match against (length, code) pairs. A single-symbol code is a zero-bit leaf.
# ---------------------------------------------------------------------------

type
  HuffCode = object
    lens: seq[int]     # per-symbol code length (0 = unused)
    codes: seq[uint32] # canonical integer code per symbol
    maxSymbol: int     # highest symbol that may appear
    singleLeaf: int    # the only coded symbol, or -1 when not a single leaf
    minCode: array[16, uint32]
    maxCode: array[16, int]
    symIndex: array[16, int]
    sorted: seq[int]

proc buildCanonical(lens: seq[int]; maxSymbol: int): HuffCode =
  ## Build canonical (length, code) pairs over the *full* `lens` alphabet.
  ## `maxSymbol` (from `use_length`) only caps how many code-length codes were
  ## read — run codes (16/17/18) can place nonzero lengths anywhere in the
  ## alphabet, so the table must span all of `lens`, not just `maxSymbol`.
  result.lens = lens
  result.maxSymbol = lens.len
  result.codes = newSeq[uint32](lens.len)
  result.singleLeaf = -1
  for depth in 0 .. 15: result.maxCode[depth] = -1
  let n = lens.len
  var blCount: array[16, int]
  var nonZero = 0
  var sole = -1
  for s in 0 ..< n:
    let l = lens[s]
    if l > 0:
      inc blCount[l]
      inc nonZero
      sole = s
  if nonZero == 1:
    result.singleLeaf = sole
    return # a single leaf reads zero bits; codes stay zero
  var nextCode: array[16, uint32]
  var code = 0'u32
  for bits in 1 .. 15:
    code = (code + uint32(blCount[bits - 1])) shl 1
    nextCode[bits] = code
    result.minCode[bits] = code
    if blCount[bits] > 0:
      result.maxCode[bits] = int(code) + blCount[bits] - 1
      result.symIndex[bits] = result.sorted.len
      for s in 0 ..< n:
        if lens[s] == bits: result.sorted.add s
  for s in 0 ..< n:
    let l = lens[s]
    if l > 0:
      result.codes[s] = nextCode[l]
      inc nextCode[l]

proc decodeSymbol(b: var BitReader; hc: HuffCode): int =
  if hc.singleLeaf >= 0: return hc.singleLeaf
  var path = 0'u32
  for depth in 1 .. 15:
    path = (path shl 1) or b.readBit() # MSB-first: first bit read is the high bit
    if hc.maxCode[depth] >= 0 and path >= hc.minCode[depth] and
        int(path) <= hc.maxCode[depth]:
      return hc.sorted[hc.symIndex[depth] + int(path - hc.minCode[depth])]
  raise UniImageException(code: uiInvalidArg,
      msg: "webp: huffman code longer than 15 bits")

# ---------------------------------------------------------------------------
# Code-length code reading (shared by every prefix code and the entropy image).
# ---------------------------------------------------------------------------

const CodeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11,
    12, 13, 14, 15]

proc readCodeLengths(b: var BitReader; numSymbols: int): tuple[lens: seq[int];
    maxSym: int] =
  ## Read `numSymbols` code lengths via the meta code-length prefix code. The
  ## `use_length` (max_symbol) bit is read in the normal path only, AFTER the
  ## code-length code is built and BEFORE the symbol loop — matching libwebp's
  ## `ReadHuffmanCodeLengths`. The simple path has no such bit.
  result.lens = newSeq[int](numSymbols)
  result.maxSym = numSymbols
  var clcl: array[19, int]
  let isSimple = b.readBit()
  if isSimple == 1:
    let numSym = int(b.readBit()) + 1
    let is8 = b.readBit()
    let sym0 = int(b.readBits(1 + 7 * int(is8)))
    if sym0 >= numSymbols:
      raise UniImageException(code: uiInvalidArg,
          msg: "webp: simple code symbol out of range")
    result.lens[sym0] = 1
    if numSym == 2:
      let sym1 = int(b.readBits(8))
      if sym1 >= numSymbols:
        raise UniImageException(code: uiInvalidArg,
            msg: "webp: simple code symbol out of range")
      result.lens[sym1] = 1
  else:
    let numCodeLengths = 4 + int(b.readBits(4))
    for i in 0 ..< numCodeLengths:
      clcl[CodeLengthOrder[i]] = int(b.readBits(3))
    let clHuff = buildCanonical(@clcl, 19)
    if b.readBit() == 1: # use_length: cap the number of coded symbols
      let nbits = 2 + 2 * int(b.readBits(3))
      result.maxSym = 2 + int(b.readBits(nbits))
      if result.maxSym > numSymbols:
        raise UniImageException(code: uiInvalidArg,
            msg: "webp: max_symbol exceeds alphabet")
    var i = 0
    var prevLen = 8
    var remaining = result.maxSym # one huffman symbol per iteration, not per entry
    while i < numSymbols and remaining > 0:
      dec remaining
      let sym = decodeSymbol(b, clHuff)
      case sym
      of 16:
        let rep = 3 + int(b.readBits(2))
        # libwebp seeds prev_code_len with DEFAULT_CODE_LENGTH (8), so a run
        # at symbol 0 is legal and repeats 8 — not a stream error.
        for _ in 0 ..< rep:
          if i >= numSymbols: break
          result.lens[i] = prevLen
          inc i
      of 17:
        let rep = 3 + int(b.readBits(3))
        for _ in 0 ..< rep:
          if i >= numSymbols: break
          result.lens[i] = 0
          inc i
      of 18:
        let rep = 11 + int(b.readBits(7))
        for _ in 0 ..< rep:
          if i >= numSymbols: break
          result.lens[i] = 0
          inc i
      else:
        result.lens[i] = sym
        if sym > 0: prevLen = sym
        inc i

proc readHuffCode(b: var BitReader; alphabetSize: int): HuffCode =
  ## Read one prefix code over `alphabetSize` symbols (handles max_symbol).
  let (lens, maxSym) = readCodeLengths(b, alphabetSize)
  result = buildCanonical(lens, maxSym)

# ---------------------------------------------------------------------------
# Predictor / color transform helpers.
# ---------------------------------------------------------------------------

proc outBit(px: uint32; shift: int; v: uint32): uint32 {.inline.} =
  (px and not (uint32(0xff) shl shift)) or (v shl shift)

proc avg2(a, b: uint32): uint32 {.inline.} =
  let ar = (a shr 24) and 0xff
  let ag = (a shr 16) and 0xff
  let ab = (a shr 8) and 0xff
  let aa = a and 0xff
  let br = (b shr 24) and 0xff
  let bg = (b shr 16) and 0xff
  let bb = (b shr 8) and 0xff
  let ba = b and 0xff
  result = ((ar + br) div 2) shl 24 or ((ag + bg) div 2) shl 16 or
      ((ab + bb) div 2) shl 8 or ((aa + ba) div 2)

proc clampU8(v: int32): uint32 {.inline.} =
  if v < 0: 0'u32 elif v > 255: 255'u32 else: uint32(v)

proc selectLTL(a, b, c: uint32): uint32 {.inline.} =
  template ch(p: uint32; s: int): int32 = int32((p shr s) and 0xff)
  var pL, pT: int32
  for shift in [24, 16, 8, 0]:
    let l = a.ch(shift); let t = b.ch(shift); let tl = c.ch(shift)
    let p = l + t - tl
    pL += abs(p - l)
    pT += abs(p - t)
  if pL < pT: a else: b

proc clampAddSubFull(a, b, c: uint32): uint32 {.inline.} =
  template ch(p: uint32; s: int): int32 = int32((p shr s) and 0xff)
  var outPx: uint32 = 0
  for shift in [24, 16, 8, 0]:
    outPx = outBit(outPx, shift,
        clampU8(a.ch(shift) + b.ch(shift) - c.ch(shift)))
  outPx

proc clampAddSubHalf(a, b: uint32): uint32 {.inline.} =
  template ch(p: uint32; s: int): int32 = int32((p shr s) and 0xff)
  var outPx: uint32 = 0
  for shift in [24, 16, 8, 0]:
    let v = a.ch(shift) + (a.ch(shift) - b.ch(shift)) div 2
    outPx = outBit(outPx, shift, clampU8(v))
  outPx

proc predictorValue(mode: int; left, top, tl, tr: uint32): uint32 =
  case mode
  of 0: 0xff000000'u32
  of 1: left
  of 2: top
  of 3: tr
  of 4: tl
  of 5: avg2(avg2(left, tr), top)
  of 6: avg2(left, tl)
  of 7: avg2(left, top)
  of 8: avg2(tl, top)
  of 9: avg2(top, tr)
  of 10: avg2(avg2(left, tl), avg2(top, tr))
  of 11: selectLTL(left, top, tl)
  of 12: clampAddSubFull(left, top, tl)
  of 13: clampAddSubHalf(avg2(left, top), tl)
  else: 0xff000000'u32

proc toS8(u: uint32): int32 {.inline.} =
  let v = int32(u and 0xff)
  if v >= 128: v - 256 else: v

proc colorDelta(t, c: int32): int32 {.inline.} =
  ## 3.5 fixed-point ColorTransformDelta; t and c are signed 8-bit values.
  ## libwebp uses an arithmetic `>> 5`; Nim `shr` is logical, so use `ashr`.
  ashr(t * c, 5)

# ---------------------------------------------------------------------------
# Transforms and the shared decode state.
# ---------------------------------------------------------------------------

type
  TransformKind = enum tkPredictor, tkColor, tkSubtractGreen, tkColorIndex
  Transform = object
    kind: TransformKind
    sizeBits: int        # predictor / color block size
    bits: seq[uint32]    # subresolution image (ARGB per block/pixel)
    width: int           # subresolution width
    height: int          # subresolution height
    palette: seq[uint32] # color-indexing table
    widthBits: int       # color-indexing pixel bundling
    imageWidth: int      # main-image width current when this was read
  HTreeGroup = array[5, HuffCode]
  DecodeState = object
    br: BitReader
    width: int
    height: int
    colorCacheBits: int    # 0 = no cache
    colorCache: seq[uint32]
    htreeGroups: seq[HTreeGroup]
    metaImage: seq[uint32] # entropy image (empty when single htree group)
    metaBits: int
    metaWidth: int

proc colorCacheIndex(color: uint32; bits: int): int {.inline.} =
  int((uint32(0x1e35a7bd) * color) shr (32 - bits))

const DistanceOffsets = [
  (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
  (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
  (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
  (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
  (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
  (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
  (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
  (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
  (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
  (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
  (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
  (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
  (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
  (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
  (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7)]

proc distanceCodeToLinear(code, width: int): int =
  let (xi, yi) = DistanceOffsets[code - 1]
  result = xi + yi * width
  if result < 1: result = 1

proc lz77Length(b: var BitReader; code: int): int =
  if code < 4: return code + 1
  let extra = (code - 2) shr 1
  let offset = (2 + (code and 1)) shl extra
  offset + int(b.readBits(extra)) + 1

proc lz77Distance(b: var BitReader; code: int; width: int): int =
  ## Decode a distance symbol to a linear back-reference distance. The raw
  ## code yields a *plane code* (libwebp `GetCopyDistance`); every plane code
  ## — including the four small ones — is then mapped through
  ## `PlaneCodeToDistance` (here `distanceCodeToLinear`), so dist_symbol 1
  ## becomes plane code 2, i.e. distance 1, not 2.
  var plane: int
  if code < 4: plane = code + 1
  else:
    let extra = (code - 2) shr 1
    let offset = (2 + (code and 1)) shl extra
    plane = offset + int(b.readBits(extra)) + 1
  if plane > 120: return plane - 120
  return distanceCodeToLinear(plane, width)

proc readHtreeGroup(b: var BitReader; colorCacheSize: int): HTreeGroup =
  result[0] = readHuffCode(b, 256 + 24 + colorCacheSize)
  result[1] = readHuffCode(b, 256)
  result[2] = readHuffCode(b, 256)
  result[3] = readHuffCode(b, 256)
  result[4] = readHuffCode(b, 40)

proc htreeFor(st: DecodeState; pos: int): int {.inline.} =
  if st.metaImage.len == 0: return 0
  let x = pos mod st.width
  let y = pos div st.width
  let p = (y shr st.metaBits) * st.metaWidth + (x shr st.metaBits)
  int((st.metaImage[p] shr 8) and 0xffff)

proc decodeImageData(st: var DecodeState; outLen: int): seq[uint32] =
  ## Decode `outLen` ARGB pixels (LZ77 + literals + color cache) into a buffer.
  result = newSeq[uint32](outLen)
  var pos = 0
  while pos < outLen:
    let hg = st.htreeGroups[st.htreeFor(pos)]
    let s = decodeSymbol(st.br, hg[0])
    if s < 256:
      let green = uint32(s)
      let red = uint32(decodeSymbol(st.br, hg[1]))
      let blue = uint32(decodeSymbol(st.br, hg[2]))
      let alpha = uint32(decodeSymbol(st.br, hg[3]))
      let color = (alpha shl 24) or (red shl 16) or (green shl 8) or blue
      result[pos] = color
      if st.colorCacheBits > 0:
        st.colorCache[colorCacheIndex(color, st.colorCacheBits)] = color
      inc pos
    elif s < 256 + 24:
      let length = lz77Length(st.br, s - 256)
      let distSym = decodeSymbol(st.br, hg[4])
      let dist = lz77Distance(st.br, distSym, st.width)
      if dist < 1 or pos - dist < 0:
        raise UniImageException(code: uiInvalidArg,
            msg: "webp: bad back-reference distance")
      for _ in 0 ..< length:
        if pos >= outLen:
          raise UniImageException(code: uiInvalidArg,
              msg: "webp: copy runs past image end")
        let color = result[pos - dist]
        result[pos] = color
        if st.colorCacheBits > 0:
          st.colorCache[colorCacheIndex(color, st.colorCacheBits)] = color
        inc pos
    else:
      let idx = s - (256 + 24)
      if st.colorCacheBits == 0 or idx >= (1 shl st.colorCacheBits):
        raise UniImageException(code: uiInvalidArg,
            msg: "webp: color cache code without a cache")
      result[pos] = st.colorCache[idx]
      inc pos

proc readColorCache(b: var BitReader; st: var DecodeState) =
  if b.readBit() == 1:
    st.colorCacheBits = int(b.readBits(4))
    if st.colorCacheBits < 1 or st.colorCacheBits > 11:
      raise UniImageException(code: uiInvalidArg,
          msg: "webp: bad color cache bits")
    st.colorCache = newSeq[uint32](1 shl st.colorCacheBits)

proc decodeEntropyImage(b: var BitReader; width, height: int): seq[uint32] =
  ## A subresolution image: color-cache-info + data (no meta-prefix, no
  ## transforms) decoded with a single htree group. All reads go through
  ## `st.br` so the caller's `b` stays in sync with every bit consumed.
  var st = DecodeState(width: width, height: height)
  st.br = b
  readColorCache(st.br, st)
  let ccs = if st.colorCacheBits > 0: 1 shl st.colorCacheBits else: 0
  st.htreeGroups = @[readHtreeGroup(st.br, ccs)]
  result = decodeImageData(st, width * height)
  b = st.br

proc expandColorMap(palette: var seq[uint32]; numColors, widthBits: int) =
  ## Reconstruct the palette from its per-channel cumulative-delta encoding
  ## (libwebp `ExpandColorMap`): entry 0 is stored raw, each later entry is the
  ## sum of its stored delta and the previous entry, per ARGB channel. The map
  ## is then padded to `1 << (8 >> widthBits)` entries with transparent black.
  let finalNum = 1 shl (8 shr widthBits)
  var expanded = newSeq[uint32](finalNum)
  expanded[0] = palette[0]
  for k in 1 ..< numColors:
    let prev = expanded[k - 1]
    let cur = if k < palette.len: palette[k] else: 0'u32
    let a = ((prev shr 24) and 0xff) + ((cur shr 24) and 0xff)
    let r = ((prev shr 16) and 0xff) + ((cur shr 16) and 0xff)
    let g = ((prev shr 8) and 0xff) + ((cur shr 8) and 0xff)
    let bl = (prev and 0xff) + (cur and 0xff)
    expanded[k] = (uint32(a and 0xff) shl 24) or (uint32(r and 0xff) shl 16) or
        (uint32(g and 0xff) shl 8) or uint32(bl and 0xff)
  palette = expanded

proc readTransforms(b: var BitReader; width, height: int): seq[Transform] =
  result = @[]
  var curW = width
  var seen: array[4, bool]
  while b.readBit() == 1:
    let t = int(b.readBits(2))
    if seen[t]:
      raise UniImageException(code: uiInvalidArg,
          msg: "webp: duplicate transform")
    seen[t] = true
    var tr: Transform
    tr.imageWidth = curW
    case t
    of 0, 1:
      tr.kind = if t == 0: tkPredictor else: tkColor
      tr.sizeBits = int(b.readBits(3)) + 2
      tr.width = divRoundUp(curW, 1 shl tr.sizeBits)
      tr.height = divRoundUp(height, 1 shl tr.sizeBits)
      tr.bits = decodeEntropyImage(b, tr.width, tr.height)
    of 2:
      tr.kind = tkSubtractGreen
    of 3:
      tr.kind = tkColorIndex
      let tableSize = int(b.readBits(8)) + 1
      tr.palette = decodeEntropyImage(b, tableSize, 1)
      tr.widthBits = if tableSize <= 2: 3 elif tableSize <= 4: 2
          elif tableSize <= 16: 1 else: 0
      expandColorMap(tr.palette, tableSize, tr.widthBits)
      curW = divRoundUp(width, 1 shl tr.widthBits)
    else: discard
    result.add tr

proc applyInverseTransforms(pixels: var seq[uint32]; tfms: seq[Transform];
    codedW, fullW, height: int) =
  var curW = codedW
  for ti in countdown(tfms.len - 1, 0):
    let tr = tfms[ti]
    case tr.kind
    of tkSubtractGreen:
      for i in 0 ..< curW * height:
        let p = pixels[i]
        let g = int((p shr 8) and 0xff)
        let r = (int((p shr 16) and 0xff) + g) and 0xff
        let bl = (int(p and 0xff) + g) and 0xff
        pixels[i] = (p and 0xff000000'u32) or (uint32(r) shl 16) or
            (uint32(g) shl 8) or uint32(bl)
    of tkColor:
      for y in 0 ..< height:
        for x in 0 ..< curW:
          let idx = (y shr tr.sizeBits) * tr.width + (x shr tr.sizeBits)
          let elt = tr.bits[idx]
          let g2r = toS8(elt and 0xff) # blue slot = green_to_red
          let g2b = toS8((elt shr 8) and 0xff) # green slot = green_to_blue
          let r2b = toS8((elt shr 16) and 0xff) # red slot = red_to_blue
          let p = pixels[y * curW + x]
          let g = toS8(uint32((p shr 8) and 0xff)) # signed 8-bit, per libwebp
          var red = int32((p shr 16) and 0xff)
          var blue = int32(p and 0xff)
          red = red + colorDelta(g2r, g)
          blue = blue + colorDelta(g2b, g)
          blue = blue + colorDelta(r2b, toS8(uint32(red and 0xff)))
          pixels[y * curW + x] = (p and 0xff000000'u32) or
              (uint32(red and 0xff) shl 16) or (uint32(g.uint32 and
                  0xff) shl 8) or
              uint32(blue and 0xff)
    of tkPredictor:
      for y in 0 ..< height:
        for x in 0 ..< curW:
          let idx = (y shr tr.sizeBits) * tr.width + (x shr tr.sizeBits)
          let mode = int((tr.bits[idx] shr 8) and 0xff)
          let left = if x > 0: pixels[y * curW + x - 1]
              elif y > 0: pixels[(y - 1) * curW] else: 0xff000000'u32
          let top = if y > 0: pixels[(y - 1) * curW + x] else: left
          let tl = if x > 0 and y > 0: pixels[(y - 1) * curW + x - 1]
              elif y > 0: pixels[(y - 1) * curW]
              elif x > 0: pixels[y * curW + x - 1] else: 0xff000000'u32
          let trPix = if x + 1 < curW:
              (if y > 0: pixels[(y - 1) * curW + x + 1] else: top)
              else: pixels[y * curW] # rightmost: leftmost of the same row
          let pred = predictorValue(mode, left, top, tl, trPix)
          let cur = pixels[y * curW + x]
          let
            ar = ((cur shr 24) and 0xff) + ((pred shr 24) and 0xff)
            ag = ((cur shr 16) and 0xff) + ((pred shr 16) and 0xff)
            ab = ((cur shr 8) and 0xff) + ((pred shr 8) and 0xff)
            aa = (cur and 0xff) + (pred and 0xff)
          pixels[y * curW + x] = (uint32(ar and 0xff) shl 24) or
              (uint32(ag and 0xff) shl 16) or (uint32(ab and 0xff) shl 8) or
              uint32(aa and 0xff)
    of tkColorIndex:
      if tr.widthBits == 0:
        for i in 0 ..< curW * height:
          let idx = int((pixels[i] shr 8) and 0xff)
          pixels[i] = if idx < tr.palette.len: tr.palette[idx] else: 0
      else:
        # Un-bundle packed indices out of the green channel, expanding width.
        let bundle = 1 shl tr.widthBits
        let idxBits = 8 shr tr.widthBits
        let idxMask = (1 shl idxBits) - 1
        let newW = tr.imageWidth
        var outPx = newSeq[uint32](newW * height)
        for y in 0 ..< height:
          for x in 0 ..< curW:
            let g = int((pixels[y * curW + x] shr 8) and 0xff)
            for k in 0 ..< bundle:
              let xx = x * bundle + k
              if xx >= newW: break
              let idx = (g shr (k * idxBits)) and idxMask
              outPx[y * newW + xx] = if idx < tr.palette.len:
                  tr.palette[idx] else: 0
        pixels = outPx
        curW = newW

# ---------------------------------------------------------------------------
# VP8L top-level decode.
# ---------------------------------------------------------------------------

proc toRgba(img: Image[uint8]): Image[uint8] =
  result = newImage[uint8](img.width, img.height, csRgba)
  for i in 0 ..< img.width * img.height:
    result.data[i * 4] = img.data[i * 3]
    result.data[i * 4 + 1] = img.data[i * 3 + 1]
    result.data[i * 4 + 2] = img.data[i * 3 + 2]
    result.data[i * 4 + 3] = 255

proc decodeVp8lBody(data: openArray[byte]; startByte, width, height: int;
    alphaUsed: bool): Image[uint8] =
  var b = initBitReader(data, startByte)
  let tfms = readTransforms(b, width, height)
  var codedW = width
  for tr in tfms:
    if tr.kind == tkColorIndex:
      codedW = divRoundUp(width, 1 shl tr.widthBits)
  var st = DecodeState(height: height)
  st.br = b
  st.width = codedW
  readColorCache(st.br, st)
  if st.br.readBit() == 1: # meta huffman
    st.metaBits = int(st.br.readBits(3)) + 2
    st.metaWidth = divRoundUp(codedW, 1 shl st.metaBits)
    let metaH = divRoundUp(height, 1 shl st.metaBits)
    st.metaImage = decodeEntropyImage(st.br, st.metaWidth, metaH)
    var numGroups = 1
    for v in st.metaImage:
      let code = int((v shr 8) and 0xffff) + 1
      if code > numGroups: numGroups = code
    let ccs = if st.colorCacheBits > 0: 1 shl st.colorCacheBits else: 0
    st.htreeGroups = newSeq[HTreeGroup](numGroups)
    for g in 0 ..< numGroups:
      st.htreeGroups[g] = readHtreeGroup(st.br, ccs)
  else:
    let ccs = if st.colorCacheBits > 0: 1 shl st.colorCacheBits else: 0
    st.htreeGroups = @[readHtreeGroup(st.br, ccs)]
  var pixels = decodeImageData(st, codedW * height)
  applyInverseTransforms(pixels, tfms, codedW, width, height)
  let ch = if alphaUsed: 4 else: 3
  result = newImage[uint8](width, height, if alphaUsed: csRgba else: csRgb)
  for i in 0 ..< width * height:
    let p = pixels[i]
    result.data[i * ch] = uint8((p shr 16) and 0xff) # red
    result.data[i * ch + 1] = uint8((p shr 8) and 0xff) # green
    result.data[i * ch + 2] = uint8(p and 0xff) # blue
    if alphaUsed:
      result.data[i * ch + 3] = uint8((p shr 24) and 0xff)

proc decodeVp8lStream(data: openArray[byte]): Image[uint8] =
  var b = initBitReader(data, 0)
  if data.len < 5 or data[0] != 0x2f:
    raise UniImageException(code: uiUnsupported, msg: "webp: missing VP8L sig")
  inc b.bytePos # consume the 0x2f signature byte
  b.bitPos = 0
  let width = int(b.readBits(14)) + 1
  let height = int(b.readBits(14)) + 1
  let alphaUsed = b.readBit() == 1
  let version = int(b.readBits(3))
  if version != 0:
    raise UniImageException(code: uiUnsupported,
        msg: "webp: unsupported VP8L version " & $version)
  if width > WebpMaxDim or height > WebpMaxDim:
    raise UniImageException(code: uiInvalidArg, msg: "webp: canvas too large")
  result = decodeVp8lBody(data, b.bytePos, width, height, alphaUsed)

proc applyAlphChunk(img: var Image[uint8]; data: openArray[byte];
    off, sz: int) =
  ## Merge an `ALPH` alpha plane into a decoded image, promoting it to
  ## `csRgba`. Only the raw and VP8L-coded alpha variants are handled.
  if sz < 1 or off < 0 or off > data.len - sz:
    raise UniImageException(code: uiTruncated, msg: "webp: ALPH short")
  let header = data[off]
  let compression = int(header and 0x3)
  let filter = int((header shr 2) and 0x3)
  let preprocessing = int((header shr 4) and 0x3)
  let reserved = int(header shr 6)
  if filter != 0 or preprocessing != 0 or reserved != 0:
    raise UniImageException(code: uiUnsupported,
        msg: "webp: filtered or preprocessed ALPH unsupported")
  let alphaStart = off + 1
  if img.colorspace != csRgba: img = toRgba(img)
  let n = img.width * img.height
  if compression == 0: # uncompressed raw alpha
    if n > sz - 1:
      raise UniImageException(code: uiTruncated, msg: "webp: ALPH plane short")
    for i in 0 ..< n:
      img.data[i * 4 + 3] = data[alphaStart + i]
  elif compression == 1: # lossless: the green channel carries alpha
    let alphaImg = decodeVp8lBody(data.toOpenArray(off, off + sz - 1), 1,
        img.width, img.height, true)
    for i in 0 ..< n:
      img.data[i * 4 + 3] = uint8((alphaImg.data[i * 4 + 1])) # green slot
  else:
    raise UniImageException(code: uiUnsupported,
        msg: "webp: ALPH compression " & $compression & " unsupported")

# ---------------------------------------------------------------------------
# RIFF container.
# ---------------------------------------------------------------------------

type ChunkHeader = object
  fourcc: string
  offset: int # payload start
  size: int   # payload size

proc readChunk(data: openArray[byte]; pos: int): ChunkHeader =
  if pos + 8 > data.len:
    raise UniImageException(code: uiTruncated, msg: "webp: chunk header short")
  var cc = newString(4)
  for i in 0 ..< 4: cc[i] = char(data[pos + i])
  result.fourcc = cc
  result.offset = pos + 8
  result.size = int(readU32le(data, pos + 4))

proc findChunkOpt(data: openArray[byte]; start, endPos: int;
    fourcc: string): tuple[found: bool; ch: ChunkHeader] =
  var pos = start
  while pos + 8 <= endPos:
    let ch = readChunk(data, pos)
    if ch.offset > endPos or ch.size > endPos - ch.offset:
      raise UniImageException(code: uiTruncated,
          msg: "webp: chunk exceeds RIFF payload")
    if ch.fourcc == fourcc: return (true, ch)
    pos = ch.offset + ch.size
    if (pos and 1) != 0: inc pos # chunks are padded to even offsets
  (false, ChunkHeader())

proc decodeWebp*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory WebP. Supports VP8L (lossless) with in-stream or
  ## `ALPH`-chunk alpha. VP8 (lossy) is recognized but returned as
  ## `uiUnsupported` until a pure-Nim VP8 decoder lands.
  requireLen(data, 12, "webp: container truncated")
  if data[0] != byte('R') or data[1] != byte('I') or data[2] != byte('F') or
      data[3] != byte('F'):
    raise UniImageException(code: uiUnsupported, msg: "webp: not a RIFF")
  if data[8] != byte('W') or data[9] != byte('E') or data[10] != byte('B') or
      data[11] != byte('P'):
    raise UniImageException(code: uiUnsupported, msg: "webp: not a WEBP")
  let riffEnd = 8 + int(readU32le(data, 4))
  if riffEnd < 12 or riffEnd > data.len:
    raise UniImageException(code: uiTruncated, msg: "webp: bad RIFF size")
  let first = readChunk(data, 12)
  if first.offset > riffEnd or first.size > riffEnd - first.offset:
    raise UniImageException(code: uiTruncated,
        msg: "webp: first chunk exceeds RIFF payload")
  case first.fourcc
  of "VP8L":
    if first.size == 0:
      raise UniImageException(code: uiTruncated, msg: "webp: empty VP8L chunk")
    return decodeVp8lStream(data.toOpenArray(first.offset,
        first.offset + first.size - 1))
  of "VP8 ":
    raise UniImageException(code: uiUnsupported,
        msg: "webp: VP8 lossy decode not yet implemented")
  of "VP8X":
    if first.size != 10:
      raise UniImageException(code: uiInvalidArg,
          msg: "webp: VP8X chunk must be 10 bytes")
    let flags = data[first.offset]
    if (flags and 0xc1) != 0 or data[first.offset + 1] != 0 or
        data[first.offset + 2] != 0 or data[first.offset + 3] != 0:
      raise UniImageException(code: uiInvalidArg,
          msg: "webp: VP8X reserved bits are nonzero")
    if (flags and 0x02) != 0:
      raise UniImageException(code: uiUnsupported,
          msg: "webp: animated images unsupported")
    let hasAlpha = (flags and 0x10) != 0
    let cw = int(data[first.offset + 4]) or
        (int(data[first.offset + 5]) shl 8) or
        (int(data[first.offset + 6]) shl 16)
    let chh = int(data[first.offset + 7]) or
        (int(data[first.offset + 8]) shl 8) or
        (int(data[first.offset + 9]) shl 16)
    let canvasW = 1 + cw
    let canvasH = 1 + chh
    if canvasW > WebpMaxDim or canvasH > WebpMaxDim:
      raise UniImageException(code: uiInvalidArg, msg: "webp: canvas too large")
    let bodyStart = first.offset + first.size
    let (found, bitstream) = findChunkOpt(data, bodyStart, riffEnd, "VP8L")
    if found:
      if bitstream.size == 0:
        raise UniImageException(code: uiTruncated,
            msg: "webp: empty VP8L chunk")
      var img = decodeVp8lStream(data.toOpenArray(bitstream.offset,
          bitstream.offset + bitstream.size - 1))
      if img.width != canvasW or img.height != canvasH:
        raise UniImageException(code: uiInvalidArg,
            msg: "webp: VP8X canvas and payload dimensions differ")
      if hasAlpha:
        let (aFound, alph) = findChunkOpt(data, bodyStart, riffEnd, "ALPH")
        if aFound: applyAlphChunk(img, data, alph.offset, alph.size)
      return img
    raise UniImageException(code: uiUnsupported,
        msg: "webp: VP8X without a VP8L payload (lossy/anim unsupported)")
  else:
    raise UniImageException(code: uiUnsupported,
        msg: "webp: unknown chunk " & first.fourcc)
