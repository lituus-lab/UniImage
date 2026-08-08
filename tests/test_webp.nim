# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[unittest, base64]
import UniImage/core
import UniImage/formats

const LlB64 = "UklGRlwAAABXRUJQVlA4TE8AAAAvA4AAAF+gFpIkaA7i0o3u86c4q9Uw0jZS+bEXcPilvH9DbyiAmVNBAL5LvarmP0CMCY8Am0ypocbt+Xl1BrIAk2smE0gullgijeh/GN4BAA=="
const LossyB64 = "UklGRk4AAABXRUJQVlA4IEIAAABwAgCdASoEAAMAAUAmJYwCdGuAwQD1/wPQ7YhAAP7vrCsin+scxtK9kz48Xvf6m0ExO2gCHWe+Ubh6h5ZZ0Tj9+AA="

proc b64decode(s: string): seq[byte] =
  let raw = decode(s)
  result = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc addU32le(data: var seq[byte]; value: int) =
  for shift in [0, 8, 16, 24]:
    data.add byte((value shr shift) and 0xff)

proc addChunk(data: var seq[byte]; fourcc: string; payload: openArray[byte]) =
  for ch in fourcc: data.add byte(ch)
  data.addU32le(payload.len)
  data.add payload
  if (payload.len and 1) != 0: data.add 0

proc extendedWithAlpha(alphaHeader: byte): seq[byte] =
  let standalone = b64decode(LlB64)
  let payloadSize = int(standalone[16]) or (int(standalone[17]) shl 8) or
      (int(standalone[18]) shl 16) or (int(standalone[19]) shl 24)
  let vp8l = standalone[20 ..< 20 + payloadSize]
  var body: seq[byte]
  var vp8x = @[0x10'u8, 0, 0, 0, 3, 0, 0, 2, 0, 0]
  body.addChunk("VP8X", vp8x)
  var alpha = @[alphaHeader]
  alpha.add vp8l[5 .. ^1] # ALPH compression omits VP8L signature/dimensions.
  body.addChunk("ALPH", alpha)
  body.addChunk("VP8L", vp8l)
  result = @[byte('R'), byte('I'), byte('F'), byte('F')]
  result.addU32le(body.len + 4)
  result.add @[byte('W'), byte('E'), byte('B'), byte('P')]
  result.add body

# 4x3 RGB fixture encoded losslessly by libwebp (via cwebp -lossless). The
# pixel grid is known, so this is a byte-exact decode oracle.
const ExpectedW = 4
const ExpectedH = 3
const ExpectedPx = [
  (255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8), (0'u8, 0'u8, 255'u8),
  (255'u8, 255'u8, 0'u8), (255'u8, 255'u8, 255'u8), (0'u8, 0'u8, 0'u8),
  (128'u8, 64'u8, 32'u8), (200'u8, 100'u8, 50'u8), (10'u8, 20'u8, 30'u8),
  (40'u8, 50'u8, 60'u8), (70'u8, 80'u8, 90'u8), (110'u8, 120'u8, 130'u8)]

suite "webp decode":
  test "VP8L lossless decodes the known 4x3 grid":
    let data = b64decode(LlB64)
    let img = decodeWebp(data)
    check img.width == ExpectedW
    check img.height == ExpectedH
    check img.channels == 3
    check img.colorspace == csRgb
    for i in 0 ..< ExpectedW * ExpectedH:
      let (r, g, b) = ExpectedPx[i]
      check img.data[i * 3] == r
      check img.data[i * 3 + 1] == g
      check img.data[i * 3 + 2] == b

  test "decodeImage routes WebP by RIFF/WEBP magic":
    let data = b64decode(LlB64)
    let img = decodeImage(data)
    check img.width == ExpectedW and img.height == ExpectedH

  test "VP8 lossy is recognized but unsupported":
    let data = b64decode(LossyB64)
    expect UniImageException:
      discard decodeWebp(data)

  test "non-WebP RIFF is unsupported":
    var bad: seq[byte] = @[byte('R'), byte('I'), byte('F'), byte('F'),
        0'u8, 0'u8, 0'u8, 0'u8, byte('W'), byte('A'), byte('V'), byte('E')]
    expect UniImageException:
      discard decodeWebp(bad)

  test "truncated container raises uiTruncated":
    var short: seq[byte] = @[byte('R'), byte('I'), byte('F'), byte('F')]
    expect UniImageException:
      discard decodeWebp(short)

  test "compressed ALPH uses the headerless lossless payload":
    let img = decodeWebp(extendedWithAlpha(1))
    check img.width == ExpectedW and img.height == ExpectedH
    check img.colorspace == csRgba
    for i in 0 ..< ExpectedW * ExpectedH:
      check img.data[i * 4 + 3] == ExpectedPx[i][1]

  test "unsupported ALPH filtering is rejected instead of misdecoded":
    try:
      discard decodeWebp(extendedWithAlpha(5)) # compression 1, filter 1
      check false
    except UniImageException as e:
      check e.code == uiUnsupported

  test "chunks cannot exceed the declared RIFF payload":
    var data = b64decode(LlB64)
    data[4] = 12 # RIFF ends inside the first chunk payload.
    for i in 5 .. 7: data[i] = 0
    try:
      discard decodeWebp(data)
      check false
    except UniImageException as e:
      check e.code == uiTruncated
