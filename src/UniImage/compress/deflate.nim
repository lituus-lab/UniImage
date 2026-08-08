# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Pure-Nim DEFLATE (RFC 1951) inflate. No zlib dependency — PNG decodes its
## IDAT stream through this. Reimplemented from the spec; bounds-checked so a
## truncated or malformed stream raises `UniImageException` rather than
## `IndexDefect`. Bits are read LSB-first within each byte, as DEFLATE requires.
import contracts
import UniImage/core

const MaxInflateOutput* = 1'i64 shl 32
  ## 4 GiB ceiling on inflate output, matching the `MaxCodecDim × 4` image
  ## bound. Callers that know the expected size pass a tighter cap.

type
  BitReader = object
    pos: int    # next unread byte index
    bitBuf: uint32
    bitCnt: int # valid bits in bitBuf

  Huff = object
    counts: array[16, int] # number of codes of each bit length
    symbols: seq[int]      # symbols in canonical order

const
  LengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35,
    43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4,
    4, 4, 4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257,
    385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
    24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9,
    10, 10, 11, 11, 12, 12, 13, 13]
  CodeLenOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1,
    15]

proc readBits(data: openArray[byte]; br: var BitReader; n: int): uint32 =
  ## Read `n` LSB-first bits (0 <= n <= 24).
  while br.bitCnt < n:
    if br.pos >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "deflate: stream truncated")
    br.bitBuf = br.bitBuf or (uint32(data[br.pos]) shl br.bitCnt)
    inc br.pos
    br.bitCnt += 8
  result = br.bitBuf and ((uint32(1) shl n) - 1)
  br.bitBuf = br.bitBuf shr n
  br.bitCnt -= n

proc alignByte(br: var BitReader) =
  ## Discard partial bits so the next read starts on a byte boundary.
  br.bitBuf = 0
  br.bitCnt = 0

proc buildHuff(lengths: openArray[int]): Huff =
  ## Build a canonical Huffman table from per-symbol bit lengths.
  var counts: array[16, int]
  for l in lengths:
    if l > 0: inc counts[l]
  var offsets: array[16, int]
  for l in 1 .. 14:
    offsets[l + 1] = offsets[l] + counts[l]
  var symbols = newSeq[int](lengths.len)
  for s, l in lengths:
    if l > 0:
      symbols[offsets[l]] = s
      inc offsets[l]
  result.counts = counts
  result.symbols = symbols

proc decodeSym(data: openArray[byte]; br: var BitReader; h: Huff): int =
  ## Decode one symbol from `h`, one bit at a time (canonical Huffman).
  var code = 0
  var first = 0
  var index = 0
  for l in 1 .. 15:
    code = (code shl 1) or int(readBits(data, br, 1))
    let count = h.counts[l]
    if code - first < count:
      return h.symbols[index + (code - first)]
    index += count
    first = (first + count) shl 1
  raise UniImageException(code: uiInvalidArg,
      msg: "deflate: invalid Huffman code")

proc decodeStored(data: openArray[byte]; br: var BitReader; dest: var seq[byte];
    maxOutput: int64) =
  ## BTYPE=0: a raw, byte-aligned block.
  alignByte(br)
  if br.pos + 4 > data.len:
    raise UniImageException(code: uiTruncated,
        msg: "deflate: stored header truncated")
  let len = int(data[br.pos]) or (int(data[br.pos + 1]) shl 8)
  let nlen = int(data[br.pos + 2]) or (int(data[br.pos + 3]) shl 8)
  br.pos += 4
  if (len xor 0xFFFF) != nlen:
    raise UniImageException(code: uiInvalidArg,
        msg: "deflate: stored LEN/NLEN mismatch")
  if br.pos + len > data.len:
    raise UniImageException(code: uiTruncated,
        msg: "deflate: stored block truncated")
  if int64(dest.len) + int64(len) > maxOutput:
    raise UniImageException(code: uiInvalidArg,
        msg: "deflate: output exceeds the size cap")
  for k in 0 ..< len: dest.add(data[br.pos + k])
  br.pos += len

proc readCodeLengths(data: openArray[byte]; br: var BitReader;
    clHuff: Huff; count: int): seq[int] =
  ## Read `count` code lengths via the code-length Huffman, applying the
  ## run-length codes 16/17/18.
  result = newSeq[int](count)
  var i = 0
  while i < count:
    let sym = decodeSym(data, br, clHuff)
    if sym < 16:
      result[i] = sym; inc i
    elif sym == 16:
      if i == 0:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: code 16 at start")
      let rep = 3 + int(readBits(data, br, 2))
      if i + rep > count:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: code 16 overruns")
      let prev = result[i - 1]
      for _ in 0 ..< rep: result[i] = prev; inc i
    elif sym == 17:
      let rep = 3 + int(readBits(data, br, 3))
      if i + rep > count:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: code 17 overruns")
      for _ in 0 ..< rep: result[i] = 0; inc i
    else: # sym == 18
      let rep = 11 + int(readBits(data, br, 7))
      if i + rep > count:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: code 18 overruns")
      for _ in 0 ..< rep: result[i] = 0; inc i

proc fixedTables(): (Huff, Huff) =
  ## BTYPE=1: the fixed literal/length and distance tables from RFC 1951.
  var litLens = newSeq[int](288)
  for i in 0 ..< 144: litLens[i] = 8
  for i in 144 ..< 256: litLens[i] = 9
  for i in 256 ..< 280: litLens[i] = 7
  for i in 280 ..< 288: litLens[i] = 8
  var distLens = newSeq[int](30)
  for i in 0 ..< 30: distLens[i] = 5
  (buildHuff(litLens), buildHuff(distLens))

proc decodeBlock(data: openArray[byte]; br: var BitReader;
    litHuff, distHuff: Huff; dest: var seq[byte]; maxOutput: int64) =
  ## Decode one Huffman block (BTYPE=1 or 2) until the end-of-block symbol 256.
  while true:
    let sym = decodeSym(data, br, litHuff)
    if sym < 256:
      if int64(dest.len) + 1'i64 > maxOutput:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: output exceeds the size cap")
      dest.add(byte(sym))
    elif sym == 256:
      break
    else:
      let li = sym - 257
      if li > 28:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: bad length code")
      var length = LengthBase[li]
      if LengthExtra[li] > 0:
        length += int(readBits(data, br, LengthExtra[li]))
      let dsym = decodeSym(data, br, distHuff)
      if dsym > 29:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: bad distance code")
      var dist = DistBase[dsym]
      if DistExtra[dsym] > 0:
        dist += int(readBits(data, br, DistExtra[dsym]))
      if dist > dest.len:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: distance too far back")
      if int64(dest.len) + int64(length) > maxOutput:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: output exceeds the size cap")
      let start = dest.len - dist
      for k in 0 ..< length: dest.add(dest[start + k])

proc inflateWithConsumed*(data: openArray[byte]; start = 0;
    maxOutput = MaxInflateOutput): tuple[data: seq[byte];
        next: int] {.contractual.} =
  ## Inflate a raw DEFLATE stream beginning at byte `start`. Returns the
  ## decompressed bytes. Raises `UniImageException` on truncation, malformed
  ## data, or if the output would exceed `maxOutput` — a decompression-bomb
  ## guard. Callers that know the expected size (PNG, EXIF) pass a tighter cap.
  require:
    start >= 0 and start <= data.len
    maxOutput > 0
  ensure:
    int64(result.data.len) <= maxOutput
    result.next >= start
  body:
    var br = BitReader(pos: start)
    var dest: seq[byte] = @[]
    while true:
      let bfinal = int(readBits(data, br, 1))
      let btype = int(readBits(data, br, 2))
      case btype
      of 0: decodeStored(data, br, dest, maxOutput)
      of 1:
        let (lit, dist) = fixedTables()
        decodeBlock(data, br, lit, dist, dest, maxOutput)
      of 2:
        let hlit = int(readBits(data, br, 5)) + 257
        let hdist = int(readBits(data, br, 5)) + 1
        let hclen = int(readBits(data, br, 4)) + 4
        var clLens = newSeq[int](19)
        for k in 0 ..< hclen:
          clLens[CodeLenOrder[k]] = int(readBits(data, br, 3))
        let clHuff = buildHuff(clLens)
        let allLens = readCodeLengths(data, br, clHuff, hlit + hdist)
        let litLens = allLens[0 ..< hlit]
        let distLens = allLens[hlit ..< hlit + hdist]
        decodeBlock(data, br, buildHuff(litLens), buildHuff(distLens), dest,
            maxOutput)
      else:
        raise UniImageException(code: uiInvalidArg,
            msg: "deflate: reserved BTYPE 3")
      if bfinal == 1: break
    result = (dest, br.pos)

proc inflate*(data: openArray[byte]; start = 0;
    maxOutput = MaxInflateOutput): seq[byte] =
  ## Inflate a raw stream and discard its ending byte position.
  inflateWithConsumed(data, start, maxOutput).data

# ---- DEFLATE compress (fixed-Huffman + LZ77) -------------------------------
# The inverse of `inflate`: a readable, spec-faithful compressor. It emits a
# single fixed-Huffman block (BTYPE=01) so there are no dynamic tables to
# encode, and matches are found with a hash-chain LZ77 (greedy). It is not the
# tightest possible output — a dynamic-Huffman / lazy-match encoder would
# compress better — but the result is a valid DEFLATE stream that any inflater
# (ours included) reads back bit-for-bit, which is what PNG encode needs.

type
  BitWriter = object
    out8: seq[byte]
    bitBuf: uint32
    bitCnt: int

proc wbit(w: var BitWriter; b: uint32) {.inline.} =
  w.bitBuf = w.bitBuf or (b shl w.bitCnt)
  w.bitCnt += 1
  if w.bitCnt == 8:
    w.out8.add byte(w.bitBuf and 0xFF)
    w.bitBuf = 0
    w.bitCnt = 0

proc wbitsLsb(w: var BitWriter; v: uint32; n: int) {.inline.} =
  ## Write `n` data bits LSB-first (extra bits, block header).
  for k in 0 ..< n: wbit(w, (v shr k) and 1)

proc wHuff(w: var BitWriter; code: uint32; len: int) {.inline.} =
  ## Write a Huffman code MSB-first (the code's high bit goes into the stream
  ## first), per RFC 1951 section 3.1.1.
  for k in countdown(len - 1, 0): wbit(w, (code shr k) and 1)

proc wflush(w: var BitWriter) =
  if w.bitCnt > 0:
    w.out8.add byte(w.bitBuf and 0xFF)
    w.bitBuf = 0
    w.bitCnt = 0

proc fixedLitCode(sym: int): (uint32, int) {.inline.} =
  ## Fixed Huffman literal/length code for `sym` (0..287) -> (code, bitlen).
  if sym <= 143: (uint32(0x30 + sym), 8)
  elif sym <= 255: (uint32(0x190 + (sym - 144)), 9)
  elif sym <= 279: (uint32(sym - 256), 7)
  else: (uint32(0xC0 + (sym - 280)), 8)

# Map a match length (3..258) to its length symbol index 0..28 (sym = 257+i).
proc lengthCodeIndex(len: int): int {.inline.} =
  # Largest i with LengthBase[i] <= len. LengthBase is monotonic up to index 28.
  result = 0
  while result < 28 and LengthBase[result + 1] <= len: inc result

proc distCodeIndex(dist: int): int {.inline.} =
  result = 0
  while result < 29 and DistBase[result + 1] <= dist: inc result

proc compress*(data: openArray[byte]): seq[byte] =
  ## Compress `data` into a single fixed-Huffman DEFLATE block. Matches are
  ## found with a hash-chain LZ77 (3..258 bytes, 32 KiB window, greedy). Raises
  ## nothing on normal input. Round-trips through `inflate`.
  const HashBits = 15
  const HashSize = 1 shl HashBits
  const MaxChain = 64 # cap per-position chain walk for O(n) worst case
  const MinMatch = 3
  const MaxMatch = 258
  var w: BitWriter
  w.out8 = newSeqOfCap[byte](data.len + data.len div 8 + 16)
  # Block header: BFINAL=1, BTYPE=01 (fixed Huffman). Data bits, LSB-first.
  wbitsLsb(w, 1, 1) # BFINAL
  wbitsLsb(w, 1, 2) # BTYPE = 01
  if data.len == 0:
    let (c, l) = fixedLitCode(256)
    wHuff(w, c, l)
    wflush(w)
    return w.out8
  var head = newSeq[int32](HashSize)
  for h in mitems(head): h = -1
  var prev = newSeq[int32](data.len)
  for p in mitems(prev): p = -1
  proc hash3(d: openArray[byte]; p: int): int {.inline.} =
    ((int(d[p]) shl 16) xor (int(d[p + 1]) shl 8) xor int(d[p + 2])) and
      (HashSize - 1)
  var i = 0
  while i < data.len:
    var emitLiteral = true
    if i + MinMatch <= data.len:
      let h = hash3(data, i)
      var cand = int(head[h])
      var bestLen = 0
      var bestDist = 0
      var steps = 0
      let limit = if i + MaxMatch <= data.len: i + MaxMatch else: data.len
      while cand >= 0 and (i - cand) <= 32768 and steps < MaxChain:
        # Quick prefix check: a match can only beat bestLen if the byte at
        # cand+bestLen matches the byte at i+bestLen (and they diverged before).
        if cand + bestLen < data.len and data[cand + bestLen] == data[i + bestLen]:
          var n = 0
          while i + n < limit and cand + n < data.len and
              data[i + n] == data[cand + n]: inc n
          if n >= MinMatch and n > bestLen:
            bestLen = n
            bestDist = i - cand
            if n >= MaxMatch or i + n >= data.len: break
        cand = int(prev[cand])
        inc steps
      if bestLen >= MinMatch:
        # Emit length symbol + extra, then distance symbol + extra.
        let li = lengthCodeIndex(bestLen)
        let ls = 257 + li
        let (lc, ll) = fixedLitCode(ls)
        wHuff(w, lc, ll)
        wbitsLsb(w, uint32(bestLen - LengthBase[li]), LengthExtra[li])
        # Distance codes are a length-5 fixed Huffman table (RFC 1951 3.2.5):
        # the canonical code equals the symbol, so the symbol is written MSB-first
        # like any Huffman code. The extra bits that follow are LSB-first.
        let di = distCodeIndex(bestDist)
        wHuff(w, uint32(di), 5)
        wbitsLsb(w, uint32(bestDist - DistBase[di]), DistExtra[di])
        # Update hash chains for the bytes covered by the match so later
        # positions can still find matches into this run.
        var k = 0
        while k < bestLen and i + k + MinMatch <= data.len:
          let hh = hash3(data, i + k)
          prev[i + k] = head[hh]
          head[hh] = int32(i + k)
          inc k
        i += bestLen
        emitLiteral = false
    if emitLiteral:
      let (c, l) = fixedLitCode(int(data[i]))
      wHuff(w, c, l)
      if i + MinMatch <= data.len:
        let h = hash3(data, i)
        prev[i] = head[h]
        head[h] = int32(i)
      inc i
  # End of block.
  let (c, l) = fixedLitCode(256)
  wHuff(w, c, l)
  wflush(w)
  result = w.out8
