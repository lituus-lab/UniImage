# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import contracts
import std/[unittest, sequtils]
import UniImage/core
import UniImage/formats

proc rgbImg(w, h: int; px: seq[uint8]): Image[uint8] =
  result = newImage[uint8](w, h, csRgb)
  doAssert px.len == w * h * 3
  result.data = px

proc rgbaImg(w, h: int; px: seq[uint8]): Image[uint8] =
  result = newImage[uint8](w, h, csRgba)
  doAssert px.len == w * h * 4
  result.data = px

proc grayImg(w, h: int; px: seq[uint8]): Image[uint8] =
  result = newImage[uint8](w, h, csGray)
  doAssert px.len == w * h
  result.data = px

suite "qoi encode":
  test "csRgb round-trips":
    let px = @[uint8 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
    let img = rgbImg(2, 2, px)
    let out8 = encodeQoi(img)
    let dec = decodeQoi(out8)
    check dec.colorspace == csRgb
    check dec.data == px

  test "csRgba round-trips (alpha preserved)":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    let img = rgbaImg(2, 2, px)
    let dec = decodeQoi(encodeQoi(img))
    check dec.colorspace == csRgba
    check dec.data == px

  test "run + diff + luma paths":
    # Covers RGB, RUN, DIFF, and LUMA chunks.
    let px = @[uint8 50, 50, 50, 50, 50, 50, 52, 51, 48, 58, 60, 54, 90, 90, 90]
    let img = rgbImg(5, 1, px)
    let dec = decodeQoi(encodeQoi(img))
    check dec.data == px

  test "unsupported colorspace raises":
    let img = newImage[uint8](1, 1, csIndexed)
    when defined(release):
      expect UniImageException: discard encodeQoi(img)
    else:
      expect PreConditionDefect: discard encodeQoi(img)

  test "channel deltas wrap across byte boundaries":
    let img = rgbImg(2, 1, @[uint8 255, 255, 255, 0, 0, 0])
    let encoded = encodeQoi(img)
    check encoded[15] == 0x7F # QOI_OP_DIFF with three wrapping +1 deltas
    check decodeQoi(encoded).data == img.data

suite "bmp encode":
  test "csRgb round-trips":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let img = rgbImg(2, 2, px)
    let dec = decodeBmp(encodeBmp(img))
    check dec.colorspace == csRgb
    check dec.data == px

  test "row padding to 4 bytes (width 1)":
    # 1-pixel-wide RGB: each row is 3 bytes, padded to 4. Round-trip must keep
    # the pixel and not read into the padding.
    let img = rgbImg(1, 2, @[uint8 200, 100, 50, 10, 20, 30])
    let dec = decodeBmp(encodeBmp(img))
    check dec.data == @[uint8 200, 100, 50, 10, 20, 30]

  test "csRgba encodes 32-bit; decode yields alpha 255 (BI_RGB reserved)":
    # 32-bit BI_RGB reserves the 4th byte, so the decoder documents alpha as
    # 255; the RGB channels survive.
    let px = @[uint8 1, 2, 3, 99, 4, 5, 6, 88]
    let img = rgbaImg(2, 1, px)
    let dec = decodeBmp(encodeBmp(img))
    check dec.colorspace == csRgba
    check dec.data == @[uint8 1, 2, 3, 255, 4, 5, 6, 255]

suite "pnm encode":
  test "csRgb -> P6 round-trips":
    let px = @[uint8 1, 2, 3, 4, 5, 6]
    let dec = decodePnm(encodePnm(rgbImg(2, 1, px)))
    check dec.colorspace == csRgb
    check dec.data == px

  test "csGray -> P5 round-trips":
    let px = @[uint8 10, 20, 30, 40]
    let dec = decodePnm(encodePnm(grayImg(2, 2, px)))
    check dec.colorspace == csGray
    check dec.data == px

  test "csRgba -> P7 (PAM) round-trips":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8]
    let dec = decodePnm(encodePnm(rgbaImg(2, 1, px)))
    check dec.colorspace == csRgba
    check dec.data == px

suite "tga encode":
  test "csRgb round-trips (uncompressed type 2)":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let dec = decodeTga(encodeTga(rgbImg(2, 2, px)))
    check dec.colorspace == csRgb
    check dec.data == px

  test "csRgba round-trips (alpha preserved)":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8]
    let dec = decodeTga(encodeTga(rgbaImg(2, 1, px)))
    check dec.colorspace == csRgba
    check dec.data == px

  test "csGray round-trips (type 3)":
    let px = @[uint8 10, 20, 30, 40]
    let dec = decodeTga(encodeTga(grayImg(2, 2, px)))
    check dec.colorspace == csGray
    check dec.data == px

  test "bottom-up orientation round-trips multi-row":
    var px = newSeq[uint8](3 * 3 * 3)
    for y in 0 ..< 3:
      for x in 0 ..< 3:
        px[(y * 3 + x) * 3] = uint8(x * 80)
        px[(y * 3 + x) * 3 + 1] = uint8(y * 80)
        px[(y * 3 + x) * 3 + 2] = uint8((x + y) * 40)
    let dec = decodeTga(encodeTga(rgbImg(3, 3, px)))
    check dec.data == px

suite "png encode":
  test "csGray round-trips (color type 0)":
    let px = @[uint8 10, 20, 30, 40]
    let dec = decodePng(encodePng(grayImg(2, 2, px)))
    check dec.colorspace == csGray
    check dec.data == px

  test "csRgb round-trips (color type 2)":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let dec = decodePng(encodePng(rgbImg(2, 2, px)))
    check dec.colorspace == csRgb
    check dec.data == px

  test "csRgba round-trips (color type 6, alpha preserved)":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    let dec = decodePng(encodePng(rgbaImg(2, 2, px)))
    check dec.colorspace == csRgba
    check dec.data == px

  test "redundant image compresses (IDAT smaller than raw)":
    var img = newImage[uint8](64, 4, csRgb)
    for y in 0 ..< 4:
      for x in 0 ..< 64:
        let v = uint8((y * 4 + x mod 7) and 0xFF)
        img.data[(y * 64 + x) * 3] = v
        img.data[(y * 64 + x) * 3 + 1] = v
        img.data[(y * 64 + x) * 3 + 2] = v
    let enc = encodePng(img)
    let dec = decodePng(enc)
    check dec.data == img.data
    check enc.len < img.data.len # DEFLATE + filtering shrinks the flat run

  test "unsupported colorspace raises":
    let img = newImage[uint8](1, 1, csIndexed)
    expect UniImageException: discard encodePng(img)

  test "PNG signature and IHDR are well-formed":
    let enc = encodePng(rgbImg(1, 1, @[uint8 7, 8, 9]))
    check enc[0 .. 7] == @[byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    check enc[12 .. 15] == @[byte('I'), byte('H'), byte('D'), byte('R')]
    check enc.len > 8 + 4 + 13 + 4 # signature + IHDR chunk minimum

  test "QOI DIFF boundary (delta +1 encodes, +2 falls through to LUMA)":
    # DIFF encodes deltas in [-2, +1] (2-bit field = value+2 in 0..3). A red
    # delta of +2 must NOT take DIFF (it would overflow the 2-bit field); it
    # falls through to LUMA. Round-trip both boundaries.
    let px = @[uint8 10, 10, 10, 11, 10, 10, 13, 10, 10]
    let img = rgbImg(3, 1, px)
    let encoded = encodeQoi(img)
    check encoded[17] shr 6 == 2 # QOI_OP_LUMA
    let dec = decodeQoi(encoded)
    check dec.data == px

suite "jpeg encode":
  proc maxErr(a, b: seq[uint8]): int =
    for i in 0 ..< min(a.len, b.len):
      let d = abs(int(a[i]) - int(b[i]))
      if d > result: result = d

  test "csGray round-trips structurally (dims + colorspace, low error)":
    var px = newSeq[uint8](16 * 16)
    for y in 0 ..< 16:
      for x in 0 ..< 16: px[y * 16 + x] = uint8(x * 15)
    let img = grayImg(16, 16, px)
    let dec = decodeJpeg(encodeJpeg(img, 90))
    check dec.width == 16 and dec.height == 16 and dec.colorspace == csGray
    check maxErr(dec.data, px) <= 8

  test "csRgb round-trips structurally (4:4:4, low error)":
    var px = newSeq[uint8](16 * 16 * 3)
    for y in 0 ..< 16:
      for x in 0 ..< 16:
        let o = (y * 16 + x) * 3
        px[o] = uint8(x * 15); px[o + 1] = uint8(y * 15); px[o + 2] = uint8((x +
            y) * 8)
    let img = rgbImg(16, 16, px)
    let dec = decodeJpeg(encodeJpeg(img, 85))
    check dec.width == 16 and dec.height == 16 and dec.colorspace == csRgb
    check maxErr(dec.data, px) <= 20

  test "non-multiple-of-8 pads by edge replication":
    # Edge replication preserves visible boundary pixels.
    var px = newSeq[uint8](13 * 7 * 3)
    for y in 0 ..< 7:
      for x in 0 ..< 13:
        let o = (y * 13 + x) * 3
        px[o] = uint8(x * 18); px[o + 1] = uint8(y * 32); px[o + 2] = uint8((x +
            y) * 12)
    let img = rgbImg(13, 7, px)
    let dec = decodeJpeg(encodeJpeg(img, 80))
    check dec.width == 13 and dec.height == 7 and dec.colorspace == csRgb
    check maxErr(dec.data, px) <= 25

  test "quality 100 is near-lossless for a flat block":
    let img = grayImg(8, 8, newSeq[uint8](64).mapIt(128'u8))
    let dec = decodeJpeg(encodeJpeg(img, 100))
    check maxErr(dec.data, img.data) <= 1

  test "unsupported colorspace raises":
    let img = newImage[uint8](1, 1, csIndexed)
    expect UniImageException: discard encodeJpeg(img)

  test "SOI/EOI markers are present":
    let enc = encodeJpeg(grayImg(8, 8, newSeq[uint8](64).mapIt(100'u8)), 90)
    check enc[0] == 0xFF and enc[1] == 0xD8 # SOI
    check enc[enc.len - 2] == 0xFF and enc[enc.len - 1] == 0xD9 # EOI

suite "encodeImage dispatcher":
  let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
  let img = rgbImg(2, 2, px)

  test "dispatches each lossless format and round-trips":
    # TGA carries no header magic, so `decodeImage` cannot sniff it — decode
    # via the matching codec instead of the magic-based dispatcher.
    for fmt in [efPng, efBmp, efQoi, efPnm]:
      let dec = decodeImage(encodeImage(img, fmt))
      check dec.width == 2 and dec.height == 2 and dec.colorspace == csRgb
      check dec.data == px
    let tga = decodeTga(encodeImage(img, efTga))
    check tga.width == 2 and tga.height == 2 and tga.colorspace == csRgb
    check tga.data == px

  test "jpeg dispatch honors quality":
    let enc = encodeImage(img, efJpeg, 95)
    check enc[0] == 0xFF and enc[1] == 0xD8 # SOI
    let dec = decodeImage(enc)
    check dec.width == 2 and dec.height == 2

  test "extension maps to the right encoder":
    check encodeFormatFromExt(".png") == efPng
    check encodeFormatFromExt(".JPG") == efJpeg
    check encodeFormatFromExt(".jpeg") == efJpeg
    check encodeFormatFromExt(".bmp") == efBmp
    check encodeFormatFromExt(".qoi") == efQoi
    check encodeFormatFromExt(".ppm") == efPnm
    check encodeFormatFromExt(".tga") == efTga

  test "unknown extension raises":
    expect UniImageException: discard encodeFormatFromExt(".webp")
