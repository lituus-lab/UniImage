# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[unittest, base64]
import UniImage/core
import UniImage/formats

# LE RGB 4x3 uncompressed TIFF written by libtiff (via Pillow). The pixel grid
# is known, so this is a byte-exact decode oracle.
const LeRgbB64 = "SUkqAAgAAAAKAAABBAABAAAABAAAAAEBBAABAAAAAwAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAAAwAAABcBBAABAAAAJAAAABwBAwABAAAAAQAAAAAAAAAIAAgACAD/AAAA/wAAAP///wD///8AAACAQCDIZDIKFB4oMjxGUFpueII="
const LeGrayB64 = "SUkqAAgAAAAJAAABBAABAAAABAAAAAEBBAABAAAAAwAAAAIBAwABAAAACAAAAAMBAwABAAAAAQAAAAYBAwABAAAAAQAAABEBBAABAAAAegAAABYBBAABAAAAAwAAABcBBAABAAAADAAAABwBAwABAAAAAQAAAAAAAAAKFB4oMjxGUFpkbng="
  # Hand-built big-endian (MM) 2x1 8-bit grayscale TIFF, photometric=1, pixels
  # [0xAB, 0xCD]. Exercises the BE header/IFD/sample path that Pillow (LE-only)
  # cannot generate.
const BeGrayB64 = "TU0AKgAAAAgACQEAAAMAAAABAAIAAAEBAAMAAAABAAEAAAECAAMAAAABAAgAAAEDAAMAAAABAAEAAAEGAAMAAAABAAEAAAERAAMAAAABAHoAAAEVAAMAAAABAAEAAAEWAAMAAAABAAEAAAEXAAMAAAABAAIAAAAAAACrzQ=="

const ExpectedRgb = [
  (255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8), (0'u8, 0'u8, 255'u8),
  (255'u8, 255'u8, 0'u8), (255'u8, 255'u8, 255'u8), (0'u8, 0'u8, 0'u8),
  (128'u8, 64'u8, 32'u8), (200'u8, 100'u8, 50'u8), (10'u8, 20'u8, 30'u8),
  (40'u8, 50'u8, 60'u8), (70'u8, 80'u8, 90'u8), (110'u8, 120'u8, 130'u8)]
const ExpectedGray = [10'u8, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]

proc b64decode(s: string): seq[byte] =
  let raw = decode(s)
  result = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc putU32le(data: var seq[byte]; offset, value: int) =
  for i in 0 .. 3:
    data[offset + i] = byte((value shr (i * 8)) and 0xff)

proc findLeTag(data: openArray[byte]; tag: int): int =
  let ifd = int(data[4]) or (int(data[5]) shl 8) or
      (int(data[6]) shl 16) or (int(data[7]) shl 24)
  let count = int(data[ifd]) or (int(data[ifd + 1]) shl 8)
  for i in 0 ..< count:
    let entry = ifd + 2 + i * 12
    let found = int(data[entry]) or (int(data[entry + 1]) shl 8)
    if found == tag: return entry
  -1

suite "tiff decode":
  test "LE RGB 4x3 decodes byte-exact":
    let img = decodeTiff(b64decode(LeRgbB64))
    check img.width == 4 and img.height == 3
    check img.channels == 3 and img.colorspace == csRgb
    for i in 0 ..< 12:
      let (r, g, b) = ExpectedRgb[i]
      check img.data[i * 3] == r
      check img.data[i * 3 + 1] == g
      check img.data[i * 3 + 2] == b

  test "LE grayscale 4x3 decodes byte-exact":
    let img = decodeTiff(b64decode(LeGrayB64))
    check img.width == 4 and img.height == 3
    check img.channels == 1 and img.colorspace == csGray
    for i in 0 ..< 12:
      check img.data[i] == ExpectedGray[i]

  test "big-endian (MM) grayscale decodes":
    let img = decodeTiff(b64decode(BeGrayB64))
    check img.width == 2 and img.height == 1
    check img.channels == 1 and img.colorspace == csGray
    check img.data[0] == 0xAB'u8
    check img.data[1] == 0xCD'u8

  test "decodeImage routes TIFF by II/MM + magic 42":
    let img = decodeImage(b64decode(LeRgbB64))
    check img.width == 4 and img.height == 3 and img.channels == 3
    let be = decodeImage(b64decode(BeGrayB64))
    check be.width == 2 and be.height == 1

  test "CCITT compression is unsupported":
    var data = b64decode(BeGrayB64)
    data[55] = 0x02'u8 # Compression SHORT value (BE) -> 2 (CCITT Group 3)
    try:
      discard decodeTiff(data)
      check false
    except UniImageException as e:
      check e.code == uiUnsupported

  test "truncated header raises uiTruncated":
    var short: seq[byte] = @[byte('I'), byte('I'), byte('*'), 0'u8,
        0'u8, 0'u8, 0'u8, 100'u8] # IFD offset 100, past EOF
    try:
      discard decodeTiff(short)
      check false
    except UniImageException as e:
      check e.code == uiTruncated

  test "total pixel count is bounded before allocation":
    var data = b64decode(LeGrayB64)
    data.putU32le(data.findLeTag(256) + 8, 32769)
    data.putU32le(data.findLeTag(257) + 8, 32769)
    try:
      discard decodeTiff(data)
      check false
    except UniImageException as e:
      check e.code == uiInvalidArg

  test "unexpected scalar field types never escape as a Defect":
    var data = b64decode(LeGrayB64)
    let width = data.findLeTag(256)
    data[width + 2] = 5 # RATIONAL instead of LONG
    data[width + 3] = 0
    try:
      discard decodeTiff(data)
      check false
    except UniImageException as e:
      check e.code == uiInvalidArg

  test "empty strips are rejected instead of synthesized as black":
    var data = b64decode(LeGrayB64)
    data.putU32le(data.findLeTag(279) + 8, 0)
    try:
      discard decodeTiff(data)
      check false
    except UniImageException as e:
      check e.code == uiTruncated
