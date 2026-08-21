# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[unittest, strutils]
when not defined(release):
  import contracts
import UniImage/compress

template expectCode(expected: UniImageError; body: untyped) =
  var got: UniImageError = uiOk
  try: body
  except UniImageException as e: got = e.code
  check got == expected

proc sbytes(s: string): seq[byte] =
  for c in s: result.add byte(c)

suite "deflate inflate":
  test "stored block round-trips":
    # BFINAL=1, BTYPE=0 -> 0x01; LEN=2, NLEN=0xFFFD; literal "Hi".
    let b = @[byte 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69]
    check inflate(b) == @[byte 0x48, 0x69]

  test "stored LEN/NLEN mismatch raises uiInvalidArg":
    let b = @[byte 0x01, 0x02, 0x00, 0x00, 0xFF, 0x48, 0x69]
    expectCode(uiInvalidArg): discard inflate(b)

  test "truncated stream raises uiTruncated":
    let b = @[byte 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48] # missing last byte
    expectCode(uiTruncated): discard inflate(b)

  test "reserved BTYPE 3 raises uiInvalidArg":
    # BFINAL=1, BTYPE=11 -> 0b111 = 0x07.
    expectCode(uiInvalidArg): discard inflate(@[byte 0x07])

  test "fixed-Huffman block (BTYPE=1) round-trips":
    let b = @[byte 0xF3, 0x48, 0xCD, 0xC9, 0xC9, 0xD7, 0x51, 0x28, 0xCF, 0x2F,
      0xCA, 0x49, 0x51, 0x04, 0x00]
    check inflate(b) == sbytes("Hello, world!")

  test "dynamic-Huffman block (BTYPE=2) round-trips":
    # A 72-byte raw-DEFLATE stream (zlib -15) of a repeated phrase; the
    # code-length alphabet uses the run symbols 16/17/18.
    let b = @[byte 0xED, 0xCB, 0xD1, 0x09, 0xC0, 0x20, 0x0C, 0x05, 0xC0, 0x55,
        0xDE, 0x00, 0xA5, 0x93, 0xB8, 0x84, 0x68, 0x90, 0x80, 0x1A, 0x49, 0xE2,
        0xFE, 0xDD, 0xA3, 0xBC, 0xFB, 0xBF, 0x62, 0x2E, 0x0B, 0x7A, 0xE2, 0x2E,
        0x74, 0x9B, 0xE6, 0x08, 0x4D, 0xD4, 0x25, 0xF9, 0xA0, 0xD9, 0x0E, 0x69,
        0x29, 0x79, 0x1D, 0xB5, 0xEB, 0xD1, 0x68, 0xBA, 0x07, 0x64, 0x6A, 0xBE,
        0x28, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x8C, 0x7F,
        0x8C, 0x1F]
    let expected = sbytes(repeat(
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 50))
    check inflate(b) == expected

  test "back-reference (length/distance) round-trips":
    let b = @[byte 0x4B, 0x4C, 0x4A, 0x4E, 0x49, 0x4D, 0x4B, 0xCF, 0x48, 0x1C,
      0xA5, 0x47, 0xE9, 0x51, 0x1A, 0x83, 0x06, 0x00]
    check inflate(b) == sbytes(repeat("abcdefgh", 100))

  test "output cap rejects decompression beyond maxOutput":
    # BFINAL=1, BTYPE=0 -> 0x01; LEN=2, NLEN=0xFFFD; literal "Hi".
    let b = @[byte 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69]
    expectCode(uiInvalidArg): discard inflate(b, maxOutput = 1)

when not defined(release):
  suite "deflate contracts":
    test "start must designate an input boundary":
      expect PreConditionDefect:
        discard inflateWithConsumed([byte 0x03, 0x00], start = 3)

suite "zlib inflate":
  test "zlib-wrapped stored block round-trips with Adler-32":
    # CMF=0x78, FLG=0x9C (check passes); stored "Hi"; Adler-32 = 0x00FB00B2.
    let b = @[byte 0x78, 0x9C, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69,
      0x00, 0xFB, 0x00, 0xB2]
    check zlibInflate(b) == @[byte 0x48, 0x69]

  test "trailing bytes follow the Adler-32 trailer":
    let b = @[byte 0x78, 0x9C, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69,
      0x00, 0xFB, 0x00, 0xB2, 0xAA, 0xBB]
    check zlibInflate(b) == @[byte 0x48, 0x69]

  test "bad header check raises uiInvalidArg":
    var b = @[byte 0x78, 0x9D, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69,
      0x00, 0xFB, 0x00, 0xB2] # FLG=0x9D breaks the mod-31 check
    expectCode(uiInvalidArg): discard zlibInflate(b)

  test "Adler-32 mismatch raises uiInvalidArg":
    var b = @[byte 0x78, 0x9C, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69,
      0x00, 0xFB, 0x00, 0xB3] # last byte tampered
    expectCode(uiInvalidArg): discard zlibInflate(b)

  test "non-deflate method raises uiUnsupported":
    let b = @[byte 0x09, 0x00, 0x01, 0x02, 0x00, 0xFD, 0xFF, 0x48, 0x69]
    expectCode(uiUnsupported): discard zlibInflate(b)

  test "preset dictionary (FDICT) raises uiUnsupported":
    # CMF=0x78, FLG=0x20 (FDICT bit set; (0x7800|0x20) mod 31 == 0).
    let b = @[byte 0x78, 0x20, 0x00, 0x00, 0x00, 0x00]
    expectCode(uiUnsupported): discard zlibInflate(b)

  test "CINFO > 7 raises uiInvalidArg":
    # CMF=0x88: CM=8 (DEFLATE), CINFO=8 (window > 32 KiB). FLG=0x1C passes the
    # mod-31 FCHECK and clears FDICT, so the header is otherwise well-formed and
    # only the CINFO check rejects it.
    let b = @[byte 0x88, 0x1C, 0x03, 0x00]
    expectCode(uiInvalidArg): discard zlibInflate(b)

  test "missing trailer raises uiTruncated":
    # Valid header + an empty fixed-Huffman block, but no Adler-32 trailer;
    # data.len (4) < start + 4 (6).
    let b = @[byte 0x78, 0x9C, 0x03, 0x00]
    expectCode(uiTruncated): discard zlibInflate(b)

suite "deflate compress":
  template roundTrip(name: string; data: seq[byte]) =
    let out8 = compress(data)
    checkpoint name
    check inflate(out8) == data

  test "empty round-trips":
    roundTrip("empty", newSeq[byte]())

  test "single byte round-trips":
    roundTrip("one", @[byte 42])

  test "short literal run round-trips":
    roundTrip("lit", @[byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

  test "repeated pattern exercises LZ77 matches":
    var rep = newSeq[byte](4096)
    for i in 0 ..< rep.len: rep[i] = byte(i mod 7)
    roundTrip("rep7", rep)

  test "ramp round-trips":
    var ramp = newSeq[byte](10000)
    for i in 0 ..< ramp.len: ramp[i] = byte(i mod 256)
    roundTrip("ramp", ramp)

  test "redundant payload beyond the LZ77 window round-trips":
    var large = newSeq[byte](128 * 1024)
    for i in 0 ..< 32 * 1024:
      large[i] = byte((i * 31 + i div 251) mod 256)
    for i in 32 * 1024 ..< large.len:
      large[i] = large[i mod (32 * 1024)]
    roundTrip("128 KiB window", large)

  test "compressed output is smaller than input for redundant data":
    var rep = newSeq[byte](4096)
    for i in 0 ..< rep.len: rep[i] = byte(i mod 7)
    check compress(rep).len < rep.len

suite "zlib deflate":
  test "zlib round-trips with Adler-32":
    var rep = newSeq[byte](2048)
    for i in 0 ..< rep.len: rep[i] = byte(i mod 11)
    let z = zlibDeflate(rep)
    check zlibInflate(z) == rep

  test "zlib header is CMF=0x78 with a valid FCHECK":
    let z = zlibDeflate(@[byte 1, 2, 3])
    check z[0] == 0x78
    check ((int(z[0]) shl 8) or int(z[1])) mod 31 == 0
    check (z[1] and 0x20) == 0 # FDICT clear
