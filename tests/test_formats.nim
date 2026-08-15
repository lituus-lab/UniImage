# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[unittest, math, tables]
import UniImage/core
import UniImage/formats
import UniImage/formats/util

proc putU16le(b: var seq[byte]; i: int; v: uint16) =
  b[i] = byte(v and 0xFF)
  b[i + 1] = byte((v shr 8) and 0xFF)

proc putU32le(b: var seq[byte]; i: int; v: uint32) =
  b[i] = byte(v and 0xFF)
  b[i + 1] = byte((v shr 8) and 0xFF)
  b[i + 2] = byte((v shr 16) and 0xFF)
  b[i + 3] = byte((v shr 24) and 0xFF)

proc putI32le(b: var seq[byte]; i: int; v: int32) = putU32le(b, i, cast[uint32](v))

proc bmpTruecolor(w, h, bpp: int; px: seq[uint8]; topDown = false): seq[byte] =
  # `px` is RGB(A) stored top-to-bottom, `bpp div 8` bytes per pixel.
  let bytespp = bpp div 8
  let rowStride = ((bpp * w + 31) div 32) * 4
  let pixOffset = 14 + 40
  result = newSeq[byte](pixOffset + rowStride * h)
  result[0] = 0x42; result[1] = 0x4D
  putU32le(result, 2, uint32(result.len))
  putU32le(result, 10, uint32(pixOffset))
  putU32le(result, 14, 40)
  putI32le(result, 18, int32(w))
  putI32le(result, 22, if topDown: -int32(h) else: int32(h))
  putU16le(result, 26, 1)
  putU16le(result, 28, uint16(bpp))
  putU32le(result, 30, 0)
  putU32le(result, 34, uint32(rowStride * h))
  for dy in 0 ..< h:
    let srcRow = if topDown: dy else: h - 1 - dy
    let rowBase = pixOffset + dy * rowStride
    for dx in 0 ..< w:
      let s = srcRow * w * bytespp + dx * bytespp
      let d = rowBase + dx * bytespp
      result[d] = px[s + 2]; result[d + 1] = px[s + 1]; result[d + 2] = px[s]
      if bytespp == 4: result[d + 3] = px[s + 3]

proc bmpIndexed(w, h, bpp: int; idx: seq[uint8];
    pal: seq[(uint8, uint8, uint8)]; topDown = false): seq[byte] =
  let rowStride = ((bpp * w + 31) div 32) * 4
  let pixOffset = 14 + 40 + pal.len * 4
  result = newSeq[byte](pixOffset + rowStride * h)
  result[0] = 0x42; result[1] = 0x4D
  putU32le(result, 2, uint32(result.len))
  putU32le(result, 10, uint32(pixOffset))
  putU32le(result, 14, 40)
  putI32le(result, 18, int32(w))
  putI32le(result, 22, if topDown: -int32(h) else: int32(h))
  putU16le(result, 26, 1)
  putU16le(result, 28, uint16(bpp))
  putU32le(result, 30, 0)
  putU32le(result, 34, uint32(rowStride * h))
  putU32le(result, 46, uint32(pal.len))
  for k in 0 ..< pal.len:
    let p = 14 + 40 + k * 4
    result[p] = pal[k][2]; result[p + 1] = pal[k][1]; result[p + 2] = pal[k][0]
  for dy in 0 ..< h:
    let srcRow = if topDown: dy else: h - 1 - dy
    let rowBase = pixOffset + dy * rowStride
    for dx in 0 ..< w:
      let v = idx[srcRow * w + dx]
      if bpp == 8:
        result[rowBase + dx] = v
      else: # 1-bit, MSB first
        if v != 0:
          result[rowBase + (dx shr 3)] = result[rowBase + (dx shr 3)] or
            byte(0x80 shr (dx and 7))

template expectCode(expected: UniImageError; body: untyped) =
  var got: UniImageError = uiOk
  try: body
  except UniImageException as e: got = e.code
  check got == expected

suite "bmp decode":
  test "24-bit truecolor round-trips BGR->RGB":
    let px = @[uint8 255, 0, 0, 0, 255, 0, 0, 0, 255, # row 0: R G B
      10, 20, 30, 40, 50, 60, 70, 80, 90] # row 1
    let bmp = bmpTruecolor(3, 2, 24, px)
    let img = decodeBmp(bmp)
    check img.width == 3 and img.height == 2
    check img.colorspace == csRgb and img.channels == 3
    check img.data == px

  test "32-bit truecolor -> csRgba with alpha 255":
    let px = @[uint8 1, 2, 3, 7, 4, 5, 6, 8]
    let bmp = bmpTruecolor(2, 1, 32, px)
    let img = decodeBmp(bmp)
    check img.colorspace == csRgba and img.channels == 4
    check img.data == @[uint8 1, 2, 3, 255, 4, 5, 6, 255]

  test "8-bit indexed expands via palette":
    let pal = @[(uint8 255, uint8 0, uint8 0), (uint8 0, uint8 255, uint8 0)]
    let idx = @[uint8 0, 1, 0, 1]
    let bmp = bmpIndexed(4, 1, 8, idx, pal)
    let img = decodeBmp(bmp)
    check img.colorspace == csRgba and img.channels == 4
    check img.data == @[uint8 255, 0, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0,
        255, 0, 255]

  test "1-bit indexed, MSB-first":
    let pal = @[(uint8 0, uint8 0, uint8 0), (uint8 255, uint8 255, uint8 255)]
    let idx = @[uint8 1, 0, 1, 0, 1, 0, 1, 0]         # 8 px: alternating
    let bmp = bmpIndexed(8, 1, 1, idx, pal)
    let img = decodeBmp(bmp)
    check img.channels == 4
    check img.data == @[uint8 255, 255, 255, 255, 0, 0, 0, 255,
                       255, 255, 255, 255, 0, 0, 0, 255,
                       255, 255, 255, 255, 0, 0, 0, 255,
                       255, 255, 255, 255, 0, 0, 0, 255]

  test "bottom-up vs top-down orientation":
    let px = @[uint8 1, 1, 1, 2, 2, 2, # row 0 (top)
      3, 3, 3, 4, 4, 4]                # row 1 (bottom)
    let up = decodeBmp(bmpTruecolor(2, 2, 24, px, topDown = false))
    let dn = decodeBmp(bmpTruecolor(2, 2, 24, px, topDown = true))
    check up.data == px # bottom-up: image row 0 = top = px row 0
    check dn.data == px # top-down: image row 0 = top = px row 0

  test "truncated pixel data raises uiTruncated":
    var bmp = bmpTruecolor(3, 2, 24, @[uint8 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0])
    bmp.setLen(bmp.len - 1) # drop one byte: row stride no longer fits
    expectCode(uiTruncated): discard decodeBmp(bmp)

  test "bad magic raises uiUnsupported":
    var bmp = bmpTruecolor(2, 1, 24, @[uint8 0, 0, 0, 0, 0, 0])
    bmp[0] = 0x00
    expectCode(uiUnsupported): discard decodeBmp(bmp)

  test "RLE compression is unsupported":
    var bmp = bmpTruecolor(2, 1, 24, @[uint8 0, 0, 0, 0, 0, 0])
    putU32le(bmp, 30, 1) # BI_RLE8
    expectCode(uiUnsupported): discard decodeBmp(bmp)

  test "16-bit bpp is unsupported":
    var bmp = bmpTruecolor(2, 1, 24, @[uint8 0, 0, 0, 0, 0, 0])
    putU16le(bmp, 28, 16)
    expectCode(uiUnsupported): discard decodeBmp(bmp)

suite "decodeImage dispatch":
  test "routes BMP by magic":
    let bmp = bmpTruecolor(2, 1, 24, @[uint8 1, 2, 3, 4, 5, 6])
    let img = decodeImage(bmp)
    check img.width == 2 and img.height == 1
  test "unknown magic raises uiUnsupported":
    expectCode(uiUnsupported): discard decodeImage(@[byte 0x00, 0x01])

proc putU32be(b: var seq[byte]; v: uint32) =
  b.add byte((v shr 24) and 0xFF)
  b.add byte((v shr 16) and 0xFF)
  b.add byte((v shr 8) and 0xFF)
  b.add byte(v and 0xFF)

proc qoiRaw(w, h, ch: int; px: seq[uint8]): seq[byte] =
  # Encode each pixel as QOI_OP_RGB(A) — a verbatim round-trip the decoder
  # must reproduce exactly. `px` is top-to-bottom, `ch` bytes per pixel.
  result = newSeqOfCap[byte](14 + px.len + 8)
  result.add @[byte 0x71, 0x6F, 0x69, 0x66]
  putU32be(result, uint32(w))
  putU32be(result, uint32(h))
  result.add byte(ch)
  result.add byte(0) # colorspace: sRGB + linear alpha
  for i in 0 ..< w * h:
    let s = i * ch
    if ch == 3:
      result.add 0xFE
      result.add @[px[s], px[s + 1], px[s + 2]]
    else:
      result.add 0xFF
      result.add @[px[s], px[s + 1], px[s + 2], px[s + 3]]
  result.add @[byte 0, 0, 0, 0, 0, 0, 0, 1] # end marker

suite "qoi decode":
  test "pixel count is bounded before allocation":
    let data = @[byte 0x71, 0x6F, 0x69, 0x66, 0x00, 0x01, 0x00, 0x00,
      0x00, 0x01, 0x00, 0x00, 0x03, 0x00]
    expectCode(uiInvalidArg): discard decodeQoi(data)

  test "RGB (3-channel) verbatim round-trip":
    let px = @[uint8 10, 20, 30, 40, 50, 60]
    let img = decodeQoi(qoiRaw(2, 1, 3, px))
    check img.width == 2 and img.height == 1
    check img.colorspace == csRgb and img.channels == 3
    check img.data == px

  test "RGBA (4-channel) verbatim round-trip":
    let px = @[uint8 1, 2, 3, 200, 4, 5, 6, 250]
    let img = decodeQoi(qoiRaw(2, 1, 4, px))
    check img.colorspace == csRgba and img.channels == 4
    check img.data == px

  test "RUN repeats the previous pixel":
    # 4 identical pixels: emit pixel 0 as RGBA, then a RUN of 3 (0xC2 -> (2)+1).
    var b: seq[byte] = @[byte 0x71, 0x6F, 0x69, 0x66]
    putU32be(b, 4); putU32be(b, 1); b.add 4; b.add 0
    b.add 0xFF; b.add @[byte 7, 8, 9, 255]
    b.add 0xC2
    b.add @[byte 0, 0, 0, 0, 0, 0, 0, 1]
    let img = decodeQoi(b)
    check img.data == @[uint8 7, 8, 9, 255, 7, 8, 9, 255, 7, 8, 9, 255, 7, 8, 9, 255]

  test "DIFF adjusts by -2..+1":
    # pixel 0 = (10,10,10,255) via RGBA; pixel 1 = (11,11,11): DIFF (+1,+1,+1)
    # byte = 0b01_11_11_11 = 0x7F.
    var b: seq[byte] = @[byte 0x71, 0x6F, 0x69, 0x66]
    putU32be(b, 2); putU32be(b, 1); b.add 4; b.add 0
    b.add 0xFF; b.add @[byte 10, 10, 10, 255]
    b.add 0x7F
    b.add @[byte 0, 0, 0, 0, 0, 0, 0, 1]
    let img = decodeQoi(b)
    check img.data == @[uint8 10, 10, 10, 255, 11, 11, 11, 255]

  test "INDEX pulls from the 64-slot table":
    # pixel 0 = (1,2,3,255) via RGBA -> hash 23; pixel 1 = INDEX slot 23 (0x17).
    var b: seq[byte] = @[byte 0x71, 0x6F, 0x69, 0x66]
    putU32be(b, 2); putU32be(b, 1); b.add 4; b.add 0
    b.add 0xFF; b.add @[byte 1, 2, 3, 255]
    b.add 0x17
    b.add @[byte 0, 0, 0, 0, 0, 0, 0, 1]
    let img = decodeQoi(b)
    check img.data == @[uint8 1, 2, 3, 255, 1, 2, 3, 255]

  test "truncated stream raises uiTruncated":
    var b: seq[byte] = @[byte 0x71, 0x6F, 0x69, 0x66]
    putU32be(b, 2); putU32be(b, 1); b.add 3; b.add 0
    b.add 0xFE; b.add @[byte 1, 2] # RGB chunk missing one byte
    expectCode(uiTruncated): discard decodeQoi(b)

  test "bad magic raises uiUnsupported":
    expectCode(uiUnsupported): discard decodeQoi(@[byte 0x71, 0x6F, 0x69, 0x65,
      0, 0, 0, 1, 0, 0, 0, 1, 3, 0])

  test "decodeImage routes QOI by magic":
    let img = decodeImage(qoiRaw(2, 1, 3, @[uint8 1, 2, 3, 4, 5, 6]))
    check img.width == 2 and img.height == 1

proc pnmHdr(magic: string; w, h, maxval: int): seq[byte] =
  let s = if maxval > 0: magic & " " & $w & " " & $h & " " & $maxval & "\n"
          else: magic & " " & $w & " " & $h & "\n"
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

suite "pnm decode":
  test "oversized integer is rejected without overflow":
    expectCode(uiInvalidArg):
      discard decodePnm(toBytes("P5\n999999999999999999999999 1\n255\n"))

  test "P6 binary RGB round-trips":
    let body = @[byte 10, 20, 30, 40, 50, 60]
    let img = decodePnm(pnmHdr("P6", 2, 1, 255) & body)
    check img.colorspace == csRgb and img.channels == 3
    check img.data == body

  test "P5 binary grayscale round-trips":
    let body = @[byte 10, 20, 30, 40]
    let img = decodePnm(pnmHdr("P5", 4, 1, 255) & body)
    check img.colorspace == csGray and img.channels == 1
    check img.data == body

  test "P3 ASCII RGB round-trips":
    let body = toBytes("10 20 30 40 50 60")
    let img = decodePnm(pnmHdr("P3", 2, 1, 255) & body)
    check img.colorspace == csRgb
    check img.data == @[uint8 10, 20, 30, 40, 50, 60]

  test "P2 ASCII grayscale round-trips":
    let img = decodePnm(pnmHdr("P2", 3, 1, 255) & toBytes("1 2 3"))
    check img.colorspace == csGray and img.data == @[uint8 1, 2, 3]

  test "P4 binary bitmap: 1=black, 0=white":
    # 8 px: bits 1,0,1,0,1,0,1,0 -> 0b10101010 = 0xAA
    let img = decodePnm(pnmHdr("P4", 8, 1, 0) & @[byte 0xAA])
    check img.colorspace == csGray
    check img.data == @[uint8 0, 255, 0, 255, 0, 255, 0, 255]

  test "P1 ASCII bitmap":
    let img = decodePnm(pnmHdr("P1", 4, 1, 0) & toBytes("1 0 1 0"))
    check img.data == @[uint8 0, 255, 0, 255]

  test "maxval scales samples to 0..255":
    # maxval=100, value=50 -> 50*255/100 = 127.5 -> 128 (rounded).
    let img = decodePnm(pnmHdr("P5", 1, 1, 100) & @[byte 50])
    check img.data == @[uint8 128]

  test "16-bit P5 downscales to 8-bit":
    # maxval=65535, value=32768 -> 32768*255/65535 = 127.5 -> 128.
    let img = decodePnm(pnmHdr("P5", 1, 1, 65535) & @[byte 0x80, 0x00])
    check img.data == @[uint8 128]

  test "comments in the header are skipped":
    let hdr = toBytes("P5\n# a comment\n2 1\n255\n")
    let img = decodePnm(hdr & @[byte 5, 7])
    check img.data == @[uint8 5, 7]

  test "truncated P6 raises uiTruncated":
    let body = @[byte 10, 20] # need 6 bytes for 2 RGB px
    expectCode(uiTruncated): discard decodePnm(pnmHdr("P6", 2, 1, 255) & body)

  test "bad magic raises uiUnsupported":
    # P7 is now a supported PAM container (decodePam), so use a magic outside
    # the P1-P7 range to exercise the unsupported-type path.
    expectCode(uiUnsupported): discard decodePnm(toBytes("P9 1 1 255\n"))

  test "PAM header comments are skipped":
    let hdr = toBytes("P7\n# a comment\nWIDTH 2\nHEIGHT 1\nDEPTH 3\n" &
        "MAXVAL 255\nTUPLTYPE RGB\nENDHDR\n")
    let img = decodePnm(hdr & @[byte 1, 2, 3, 4, 5, 6])
    check img.width == 2 and img.height == 1 and img.colorspace == csRgb
    check img.data == @[uint8 1, 2, 3, 4, 5, 6]

  test "PAM non-numeric MAXVAL raises uiInvalidArg":
    let hdr = toBytes("P7\nWIDTH 1\nHEIGHT 1\nDEPTH 1\nMAXVAL abc\nENDHDR\n")
    expectCode(uiInvalidArg): discard decodePnm(hdr)

  test "decodeImage routes PNM by magic":
    let img = decodeImage(pnmHdr("P6", 2, 1, 255) & @[byte 1, 2, 3, 4, 5, 6])
    check img.width == 2 and img.height == 1

proc tgaTruecolor(w, h, depth: int; px: seq[uint8]; topDown = false): seq[byte] =
  # `px` is RGB(A) top-to-bottom, `depth div 8` bytes per pixel. TGA stores BGR
  # and (by default) bottom-up rows; the builder reverses rows so a bottom-up
  # decode returns `px` in top-to-bottom order.
  let bytespp = depth div 8
  let desc: uint8 = if topDown: 0x20 else: 0x00
  result = newSeq[byte](18 + w * h * bytespp)
  result[2] = 2 # uncompressed truecolor
  putU16le(result, 12, uint16(w))
  putU16le(result, 14, uint16(h))
  result[16] = byte(depth)
  result[17] = desc
  for dy in 0 ..< h:
    let srcRow = if topDown: dy else: h - 1 - dy
    for dx in 0 ..< w:
      let s = srcRow * w * bytespp + dx * bytespp
      let d = 18 + (dy * w + dx) * bytespp
      result[d] = px[s + 2]; result[d + 1] = px[s + 1]; result[d + 2] = px[s]
      if bytespp == 4: result[d + 3] = px[s + 3]

proc tgaGray(w, h: int; px: seq[uint8]; topDown = false): seq[byte] =
  let desc: uint8 = if topDown: 0x20 else: 0x00
  result = newSeq[byte](18 + w * h)
  result[2] = 3 # uncompressed grayscale
  putU16le(result, 12, uint16(w))
  putU16le(result, 14, uint16(h))
  result[16] = 8
  result[17] = desc
  for dy in 0 ..< h:
    let srcRow = if topDown: dy else: h - 1 - dy
    for dx in 0 ..< w:
      result[18 + dy * w + dx] = px[srcRow * w + dx]

proc tgaIndexed(w, h: int; idx: seq[uint8];
    pal: seq[(uint8, uint8, uint8, uint8)]; cmapBpp: int; topDown = false): seq[byte] =
  let entryBytes = cmapBpp div 8
  let desc: uint8 = if topDown: 0x20 else: 0x00
  result = newSeq[byte](18 + pal.len * entryBytes + w * h)
  result[1] = 1 # color map present
  result[2] = 1 # uncompressed color-mapped
  putU16le(result, 5, uint16(pal.len)) # color map length
  result[7] = byte(cmapBpp)
  putU16le(result, 12, uint16(w))
  putU16le(result, 14, uint16(h))
  result[16] = 8
  result[17] = desc
  for k in 0 ..< pal.len:
    let p = 18 + k * entryBytes
    result[p] = pal[k][2]; result[p + 1] = pal[k][1]; result[p + 2] = pal[k][0]
    if entryBytes == 4: result[p + 3] = pal[k][3]
  let pixBase = 18 + pal.len * entryBytes
  for dy in 0 ..< h:
    let srcRow = if topDown: dy else: h - 1 - dy
    for dx in 0 ..< w:
      result[pixBase + dy * w + dx] = idx[srcRow * w + dx]

suite "tga decode":
  test "24-bit truecolor round-trips BGR->RGB":
    let px = @[uint8 255, 0, 0, 0, 255, 0, 0, 0, 255,
      10, 20, 30, 40, 50, 60, 70, 80, 90]
    let img = decodeTga(tgaTruecolor(3, 2, 24, px))
    check img.width == 3 and img.height == 2
    check img.colorspace == csRgb and img.channels == 3
    check img.data == px

  test "32-bit truecolor -> csRgba":
    let px = @[uint8 1, 2, 3, 7, 4, 5, 6, 8]
    let img = decodeTga(tgaTruecolor(2, 1, 32, px))
    check img.colorspace == csRgba and img.channels == 4
    check img.data == px

  test "8-bit grayscale -> csGray":
    let px = @[uint8 10, 20, 30, 40]
    let img = decodeTga(tgaGray(2, 2, px))
    check img.colorspace == csGray and img.channels == 1
    check img.data == px

  test "bottom-up vs top-down orientation":
    let px = @[uint8 1, 1, 1, 2, 2, 2,
      3, 3, 3, 4, 4, 4]
    let up = decodeTga(tgaTruecolor(2, 2, 24, px, topDown = false))
    let dn = decodeTga(tgaTruecolor(2, 2, 24, px, topDown = true))
    check up.data == px
    check dn.data == px

  test "8-bit color-mapped, 24-bit palette -> csRgb":
    let pal = @[(uint8 255, uint8 0, uint8 0, uint8 0),
      (uint8 0, uint8 255, uint8 0, uint8 0)]
    let idx = @[uint8 0, 1, 1, 0]
    let img = decodeTga(tgaIndexed(2, 2, idx, pal, 24))
    check img.colorspace == csRgb and img.channels == 3
    check img.data == @[uint8 255, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 0]

  test "8-bit color-mapped, 32-bit palette -> csRgba":
    let pal = @[(uint8 255, uint8 0, uint8 0, uint8 200),
      (uint8 0, uint8 255, uint8 0, uint8 100)]
    let idx = @[uint8 0, 1]
    let img = decodeTga(tgaIndexed(2, 1, idx, pal, 32))
    check img.colorspace == csRgba and img.channels == 4
    check img.data == @[uint8 255, 0, 0, 200, 0, 255, 0, 100]

  test "RLE run packet decodes repeats":
    var b = newSeq[byte](18)
    b[2] = 10 # RLE truecolor
    putU16le(b, 12, 4); putU16le(b, 14, 1)
    b[16] = 24; b[17] = 0x20 # top-down
    b.add 0x83 # RLE packet, count = 4
    b.add @[byte 1, 2, 3] # BGR -> RGB (3, 2, 1)
    let img = decodeTga(b)
    check img.data == @[uint8 3, 2, 1, 3, 2, 1, 3, 2, 1, 3, 2, 1]

  test "RLE raw packet decodes distinct pixels":
    var b = newSeq[byte](18)
    b[2] = 10
    putU16le(b, 12, 2); putU16le(b, 14, 1)
    b[16] = 24; b[17] = 0x20
    b.add 0x01 # raw packet, count = 2
    b.add @[byte 1, 2, 3] # BGR -> (3, 2, 1)
    b.add @[byte 4, 5, 6] # BGR -> (6, 5, 4)
    let img = decodeTga(b)
    check img.data == @[uint8 3, 2, 1, 6, 5, 4]

  test "RLE exceeding image raises uiInvalidArg":
    var b = newSeq[byte](18)
    b[2] = 10
    putU16le(b, 12, 2); putU16le(b, 14, 1)
    b[16] = 24; b[17] = 0x20
    b.add 0x82 # RLE packet, count = 3 but image has 2 px
    b.add @[byte 1, 2, 3]
    expectCode(uiInvalidArg): discard decodeTga(b)

  test "truncated header raises uiTruncated":
    expectCode(uiTruncated): discard decodeTga(@[byte 0, 0, 2, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 2, 0, 1, 0, 24])

  test "truncated pixel data raises uiTruncated":
    var b = tgaTruecolor(3, 2, 24, @[uint8 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0])
    b.setLen(b.len - 1)
    expectCode(uiTruncated): discard decodeTga(b)

  test "bad image type raises uiUnsupported":
    var b = tgaTruecolor(2, 1, 24, @[uint8 0, 0, 0, 0, 0, 0])
    b[2] = 5
    expectCode(uiUnsupported): discard decodeTga(b)

  test "16-bit truecolor raises uiUnsupported":
    var b = newSeq[byte](18 + 4)
    b[2] = 2
    putU16le(b, 12, 2); putU16le(b, 14, 1)
    b[16] = 16; b[17] = 0x20
    expectCode(uiUnsupported): discard decodeTga(b)

proc pcxHeader(w, h, bpp, nplanes, bpl, encoding: int; paletteInfo = 1): seq[byte] =
  result = newSeq[byte](128)
  result[0] = 0x0A # ZSoft manufacturer
  result[1] = 5 # version 5
  result[2] = byte(encoding)
  result[3] = byte(bpp)
  putU16le(result, 8, uint16(w - 1)) # xmax
  putU16le(result, 10, uint16(h - 1)) # ymax
  result[65] = byte(nplanes)
  putU16le(result, 66, uint16(bpl))
  putU16le(result, 68, uint16(paletteInfo))

proc pcxRleScanline(raw: openArray[byte]): seq[byte] =
  # PCX RLE-encode one scanline. Runs are capped at 63 (count in the low 6 bits)
  # and never cross a scanline; literal bytes whose top two bits are 0xC0 are
  # escaped as a 1-run (0xC1, byte) so they are not mistaken for a packet.
  result = @[]
  var i = 0
  while i < raw.len:
    var run = 1
    while i + run < raw.len and raw[i + run] == raw[i] and run < 63: inc run
    if run >= 2:
      result.add byte(0xC0 or run); result.add raw[i]; i += run
    else:
      if (raw[i] and 0xC0) == 0xC0: result.add 0xC1'u8
      result.add raw[i]; inc i

proc pcxTruecolor(w, h: int; px: seq[uint8]; encoding = 0): seq[byte] =
  # `px` is RGB interleaved top-to-bottom. Planes are emitted R, G, B per row.
  result = pcxHeader(w, h, 8, 3, w, encoding)
  for dy in 0 ..< h:
    for plane in 0 ..< 3:
      var row = newSeq[byte](w)
      for dx in 0 ..< w: row[dx] = px[(dy * w + dx) * 3 + plane]
      if encoding == 1: result.add pcxRleScanline(row) else: result.add row

proc pcxIndexed(w, h: int; idx: seq[uint8];
    pal: seq[(uint8, uint8, uint8)]; encoding = 0): seq[byte] =
  result = pcxHeader(w, h, 8, 1, w, encoding, paletteInfo = 1)
  for dy in 0 ..< h:
    let row = idx[dy * w ..< (dy + 1) * w]
    if encoding == 1: result.add pcxRleScanline(row) else: result.add row
  result.add 0x0C # 256-color palette marker
  for c in pal: result.add @[c[0], c[1], c[2]]
  for _ in pal.len ..< 256: result.add @[byte 0, 0, 0] # pad to 768 bytes

proc pcxGray(w, h: int; vals: seq[uint8]; encoding = 0): seq[byte] =
  result = pcxHeader(w, h, 8, 1, w, encoding, paletteInfo = 2)
  for dy in 0 ..< h:
    let row = vals[dy * w ..< (dy + 1) * w]
    if encoding == 1: result.add pcxRleScanline(row) else: result.add row

proc pcxMono(w, h: int; px: seq[uint8]; encoding = 0): seq[byte] =
  let bpl = (w + 7) div 8
  result = pcxHeader(w, h, 1, 1, bpl, encoding)
  for dy in 0 ..< h:
    var row = newSeq[byte](bpl)
    for dx in 0 ..< w:
      if px[dy * w + dx] == 0: # black -> set bit (MSB first)
        row[dx shr 3] = row[dx shr 3] or byte(0x80 shr (dx and 7))
    if encoding == 1: result.add pcxRleScanline(row) else: result.add row

suite "pcx decode":
  test "24-bit truecolor round-trips":
    let px = @[uint8 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
    let img = decodePcx(pcxTruecolor(2, 2, px))
    check img.width == 2 and img.height == 2
    check img.colorspace == csRgb and img.channels == 3
    check img.data == px

  test "8-bit indexed expands via end palette":
    let pal = @[(uint8 255, uint8 0, uint8 0), (uint8 0, uint8 255, uint8 0)]
    let img = decodePcx(pcxIndexed(2, 1, @[uint8 0, 1], pal))
    check img.colorspace == csRgba and img.channels == 4
    check img.data == @[uint8 255, 0, 0, 255, 0, 255, 0, 255]

  test "8-bit grayscale (paletteInfo=2) -> csGray":
    let img = decodePcx(pcxGray(2, 1, @[uint8 10, 20]))
    check img.colorspace == csGray and img.channels == 1
    check img.data == @[uint8 10, 20]

  test "1-bit mono: set=black, clear=white":
    let img = decodePcx(pcxMono(4, 1, @[uint8 0, 255, 0, 255]))
    check img.colorspace == csGray
    check img.data == @[uint8 0, 255, 0, 255]

  test "RLE run packet decodes repeats":
    var b = pcxHeader(4, 1, 8, 3, 4, 1) # encoding = 1 (RLE)
    b.add 0xC4; b.add 10 # R plane: count 4, value 10
    b.add 0xC4; b.add 20 # G plane
    b.add 0xC4; b.add 30 # B plane
    let img = decodePcx(b)
    check img.colorspace == csRgb
    check img.data == @[uint8 10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30]

  test "truecolor RLE round-trips multi-row":
    # 3x2 image, every pixel (1,2,3). Each plane/row is one run of 3 reaching the
    # scanline end; the decoder must reset per scanline, not carry the run into
    # the next plane or row.
    let px = @[uint8 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3]
    let img = decodePcx(pcxTruecolor(3, 2, px, encoding = 1))
    check img.width == 3 and img.height == 2
    check img.data == px

  test "indexed RLE round-trips":
    let pal = @[(uint8 255, uint8 0, uint8 0), (uint8 0, uint8 255, uint8 0)]
    let idx = @[uint8 0, 0, 1, 1, 0, 1, 0, 1]         # 4x2
    let img = decodePcx(pcxIndexed(4, 2, idx, pal, encoding = 1))
    check img.colorspace == csRgba and img.channels == 4
    var expected: seq[uint8] = @[]
    for i in idx: expected.add @[pal[i][0], pal[i][1], pal[i][2], 255'u8]
    check img.data == expected

  test "grayscale RLE round-trips":
    let vals = @[uint8 10, 10, 20, 20, 30, 30, 40, 40] # 4x2
    let img = decodePcx(pcxGray(4, 2, vals, encoding = 1))
    check img.colorspace == csGray and img.channels == 1
    check img.data == vals

  test "mono RLE round-trips":
    # 4x2: row0 = B,W,B,W; row1 = W,W,W,W. bpl=1 byte per row; the second row
    # is a run reaching the scanline end so the decoder resets per scanline.
    let px = @[uint8 0, 255, 0, 255, 255, 255, 255, 255]
    let img = decodePcx(pcxMono(4, 2, px, encoding = 1))
    check img.colorspace == csGray
    check img.data == px

  test "truncated pixel data raises uiTruncated":
    var b = pcxTruecolor(2, 1, @[uint8 1, 2, 3, 4, 5, 6])
    b.setLen(b.len - 1)
    expectCode(uiTruncated): discard decodePcx(b)

  test "bad manufacturer raises uiUnsupported":
    var b = pcxTruecolor(2, 1, @[uint8 1, 2, 3, 4, 5, 6])
    b[0] = 0
    expectCode(uiUnsupported): discard decodePcx(b)

  test "unsupported pixel layout raises uiUnsupported":
    let b = pcxHeader(2, 1, 1, 4, 1, 0) # 4 planes x 1-bit (16-color)
    expectCode(uiUnsupported): discard decodePcx(b)

  test "decodeImage routes PCX by magic":
    let img = decodeImage(pcxTruecolor(2, 1, @[uint8 1, 2, 3, 4, 5, 6]))
    check img.width == 2 and img.height == 1

proc toBytesS(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc hdrFlat(w, h: int; px: seq[uint8]): seq[byte] =
  # `px` is RGBE top-to-bottom, 4 bytes per pixel. Flat (uncompressed) scanlines.
  result = toBytesS("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n")
  result.add toBytesS("-Y " & $h & " +X " & $w & "\n")
  result.add px

proc hdrRleChannel(b: var seq[byte]; chan: seq[byte]) =
  # Encode one channel as raw runs. Each control byte carries 1..127 literals
  # (128 is reserved and would be rejected by the decoder), so widths above 127
  # are split into chunks instead of being masked into an invalid count.
  var i = 0
  while i < chan.len:
    let n = min(127, chan.len - i)
    b.add byte(n)
    b.add chan[i ..< i + n]
    i += n

proc hdrRle(w, h: int; px: seq[uint8]): seq[byte] =
  # `px` is RGBE top-to-bottom, 4 bytes per pixel. New RLE (width >= 8).
  result = toBytesS("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n")
  result.add toBytesS("-Y " & $h & " +X " & $w & "\n")
  for dy in 0 ..< h:
    result.add @[byte 2, 2, byte(w and 0xFF), byte((w shr 8) and 0x7F)]
    for c in 0 ..< 4:
      var chan = newSeq[byte](w)
      for dx in 0 ..< w: chan[dx] = px[(dy * w + dx) * 4 + c]
      hdrRleChannel(result, chan)

suite "hdr decode":
  test "flat RGBE decodes to float RGB":
    # px (10,20,30,E=130): f = 2^(130-136) = 2^-6 = 1/64; r = 10.5/64
    let px = @[byte 10, 20, 30, 130, 10, 20, 30, 130]
    let img = decodeHdr(hdrFlat(2, 1, px))
    check img.colorspace == csRgb and img.channels == 3
    let f = pow(2.0'f32, -6.0'f32)
    check abs(img.data[0] - (10.5'f32 * f)) < 1e-5
    check abs(img.data[2] - (30.5'f32 * f)) < 1e-5

  test "E=0 yields black":
    let img = decodeHdr(hdrFlat(1, 1, @[byte 200, 200, 200, 0]))
    check img.data == @[float32 0, 0, 0]

  test "new RLE round-trips":
    let px = @[byte 10, 20, 30, 130, 40, 50, 60, 135, 70, 80, 90, 128,
      100, 110, 120, 130, 1, 2, 3, 131, 4, 5, 6, 132, 7, 8, 9, 133, 10, 11, 12, 134]
    let img = decodeHdr(hdrRle(8, 1, px))
    check img.width == 8 and img.height == 1
    # Re-derive expected floats from the source RGBE. Tolerance compare, not
    # exact equality (float rounding), and the name avoids shadowing math.exp.
    var expected = newSeq[float32](4 * 2 * 3)
    for i in 0 ..< 8:
      let e = int(px[i * 4 + 3])
      let fv = if e == 0: 0.0'f32 else: pow(2.0'f32, float32(e - 136))
      expected[i * 3] = (float32(px[i * 4]) + 0.5'f32) * fv
      expected[i * 3 + 1] = (float32(px[i * 4 + 1]) + 0.5'f32) * fv
      expected[i * 3 + 2] = (float32(px[i * 4 + 2]) + 0.5'f32) * fv
    check img.data.len == expected.len
    for k in 0 ..< expected.len:
      check abs(img.data[k] - expected[k]) < 1e-5

  test "bottom-up (+Y) flips rows":
    # Two rows, distinct E so the float values differ per row.
    let px = @[byte 0, 0, 0, 130, 0, 0, 0, 130, # row 0 (file) E=130
      0, 0, 0, 135, 0, 0, 0, 135] # row 1 (file) E=135
    var b = toBytesS("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n")
    b.add toBytesS("+Y 2 +X 2\n") # +Y: bottom-up
    b.add px
    let img = decodeHdr(b)
    # File row 0 is the image bottom; +Y flips it to image row 1.
    let f0 = (0.5'f32) * pow(2.0'f32, float32(130 - 136))
    let f1 = (0.5'f32) * pow(2.0'f32, float32(135 - 136))
    check abs(img.data[0] - f1) < 1e-5 # image row 0 = file row 1 (E=135)
    check abs(img.data[6] - f0) < 1e-5 # image row 1 = file row 0 (E=130)

  test "-X axis raises uiUnsupported":
    # -X is valid HDR but needs a horizontal flip the decoder does not do, so
    # it must be rejected rather than silently emit a mirrored image.
    let b = toBytesS("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 -X 1\n") &
      @[byte 0, 0, 0, 0]
    expectCode(uiUnsupported): discard decodeHdr(b)

  test "missing magic raises uiUnsupported":
    let b = toBytesS("not radiance\n\n-Y 1 +X 1\n") & @[byte 0, 0, 0, 0]
    expectCode(uiUnsupported): discard decodeHdr(b)

  test "truncated scanline raises uiTruncated":
    var b = hdrFlat(2, 1, @[byte 10, 20, 30, 130, 40, 50, 60, 135])
    b.setLen(b.len - 1)
    expectCode(uiTruncated): discard decodeHdr(b)

  test "new RLE round-trips a width > 127 (split raw runs)":
    # Width 200 exceeds the 127-literal raw-run limit; the encoder splits each
    # channel into two raw runs (127 + 73) and the decoder must reassemble them.
    const w = 200
    var px = newSeq[byte](w * 4)
    for i in 0 ..< w:
      px[i * 4] = byte(i and 0xFF)
      px[i * 4 + 1] = byte((i * 2) and 0xFF)
      px[i * 4 + 2] = byte((i * 3) and 0xFF)
      px[i * 4 + 3] = 130
    let img = decodeHdr(hdrRle(w, 1, px))
    check img.width == w and img.height == 1
    let f = pow(2.0'f32, float32(130 - 136))
    for i in 0 ..< w:
      let o = i * 3
      check abs(img.data[o] - (float32(px[i * 4]) + 0.5'f32) * f) < 1e-5
      check abs(img.data[o + 1] - (float32(px[i * 4 + 1]) + 0.5'f32) * f) < 1e-5
      check abs(img.data[o + 2] - (float32(px[i * 4 + 2]) + 0.5'f32) * f) < 1e-5

proc be32(v: uint32): seq[byte] =
  @[byte(v shr 24), byte(v shr 16), byte(v shr 8), byte(v)]

proc chunk(typ: string; body: seq[byte]): seq[byte] =
  var crcInput: seq[byte] = @[]
  for c in typ: crcInput.add(byte(c))
  for b in body: crcInput.add(b)
  result = be32(uint32(body.len))
  for c in typ: result.add(byte(c))
  result.add(body)
  result.add(be32(crc32(crcInput)))

proc adler32(data: seq[byte]): uint32 =
  const M = 65521
  var a = 1'u32; var b = 0'u32
  for x in data:
    a = (a + uint32(x)) mod M
    b = (b + a) mod M
  (b shl 16) or a

proc zlibStored(raw: seq[byte]): seq[byte] =
  # zlib header (CM=8, CINFO=7) + one or more stored DEFLATE blocks + Adler-32.
  result = @[byte 0x78, 0x9C]
  var i = 0
  while i < raw.len:
    let n = min(65535, raw.len - i)
    result.add(byte(if i + n == raw.len: 1 else: 0)) # BFINAL + BTYPE 0
    result.add(byte(n and 0xFF)); result.add(byte((n shr 8) and 0xFF))
    let nlen = uint16(n) xor 0xFFFF
    result.add(byte(nlen and 0xFF)); result.add(byte((nlen shr 8) and 0xFF))
    for k in 0 ..< n: result.add(raw[i + k])
    i += n
  if raw.len == 0:
    result.add 0x01'u8
    result.add 0x00
    result.add 0x00
    result.add 0xFF
    result.add 0xFF
  result.add(be32(adler32(raw)))

proc pngBuild(w, h, bitDepth, colorType: int; raw: seq[byte];
    plte: seq[(uint8, uint8, uint8)] = @[]; trns: seq[uint8] = @[];
    interlace = 0): seq[byte] =
  result = @[byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  var ihdr: seq[byte] = be32(uint32(w)) & be32(uint32(h))
  ihdr.add(byte(bitDepth)); ihdr.add(byte(colorType))
  ihdr.add 0; ihdr.add 0; ihdr.add byte(interlace)
  result.add(chunk("IHDR", ihdr))
  if plte.len > 0:
    var p: seq[byte] = @[]
    for c in plte: p.add(@[c[0], c[1], c[2]])
    result.add(chunk("PLTE", p))
  if trns.len > 0: result.add(chunk("tRNS", trns))
  result.add(chunk("IDAT", zlibStored(raw)))
  result.add(chunk("IEND", @[]))

suite "png decode":
  test "8-bit RGB round-trips":
    let raw = @[byte 0, 10, 20, 30, 40, 50, 60]         # filter=0 + 2 px
    let img = decodePng(pngBuild(2, 1, 8, 2, raw))
    check img.colorspace == csRgb and img.channels == 3
    check img.data == @[uint8 10, 20, 30, 40, 50, 60]

  test "8-bit RGBA round-trips":
    let raw = @[byte 0, 1, 2, 3, 4, 5, 6, 7, 8]
    let img = decodePng(pngBuild(2, 1, 8, 6, raw))
    check img.colorspace == csRgba and img.channels == 4
    check img.data == @[uint8 1, 2, 3, 4, 5, 6, 7, 8]

  test "8-bit grayscale -> csGray":
    let raw = @[byte 0, 10, 20]
    let img = decodePng(pngBuild(2, 1, 8, 0, raw))
    check img.colorspace == csGray and img.channels == 1
    check img.data == @[uint8 10, 20]

  test "8-bit indexed with PLTE + tRNS -> csRgba":
    let pal = @[(uint8 255, uint8 0, uint8 0), (uint8 0, uint8 255, uint8 0)]
    let raw = @[byte 0, 0, 1] # indices 0, 1
    let img = decodePng(pngBuild(2, 1, 8, 3, raw, pal, @[byte 0, 200]))
    check img.colorspace == csRgba
    check img.data == @[uint8 255, 0, 0, 0, 0, 255, 0, 200]

  test "1-bit grayscale unpacks and scales":
    # 4 px: bits 1,0,1,0 -> 0b10100000 = 0xA0 -> (255, 0, 255, 0).
    let raw = @[byte 0, 0xA0]
    let img = decodePng(pngBuild(4, 1, 1, 0, raw))
    check img.colorspace == csGray
    check img.data == @[uint8 255, 0, 255, 0]

  test "16-bit RGB downscales to high byte":
    # px: R=0x0102->0x01, G=0x0304->0x03, B=0x0506->0x05.
    let raw = @[byte 0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
    let img = decodePng(pngBuild(1, 1, 16, 2, raw))
    check img.colorspace == csRgb
    check img.data == @[uint8 0x01, 0x03, 0x05]

  test "filter Sub reconstructs":
    # 2 px RGB: px0=(10,20,30) stored; px1 filtered = (cur - left).
    let raw = @[byte 1, 10, 20, 30, 30, 30, 30]
    let img = decodePng(pngBuild(2, 1, 8, 2, raw))
    check img.data == @[uint8 10, 20, 30, 40, 50, 60]

  test "filter Up reconstructs":
    # row 0 filter 0: (10,20,30); row 1 filter 2 (Up): cur - up.
    let raw = @[byte 0, 10, 20, 30, 2, 30, 30, 30]
    let img = decodePng(pngBuild(1, 2, 8, 2, raw))
    check img.data == @[uint8 10, 20, 30, 40, 50, 60]

  test "bad signature raises uiUnsupported":
    var b = pngBuild(1, 1, 8, 2, @[byte 0, 1, 2, 3])
    b[0] = 0x00
    expectCode(uiUnsupported): discard decodePng(b)

  test "Adam7 interlace raises uiUnsupported":
    let b = pngBuild(1, 1, 8, 2, @[byte 0, 1, 2, 3], interlace = 1)
    expectCode(uiUnsupported): discard decodePng(b)

  test "chunk CRC mismatch raises uiInvalidArg":
    var b = pngBuild(2, 1, 8, 2, @[byte 0, 10, 20, 30, 40, 50, 60])
    b[16] = b[16] xor 0x01 # tamper IHDR width (body starts at sig+8)
    expectCode(uiInvalidArg): discard decodePng(b)

  test "missing IEND raises uiTruncated":
    let b = pngBuild(1, 1, 8, 2, @[byte 0, 1, 2, 3])
    let cut = b[0 ..< b.len - 12] # drop the IEND chunk (12 bytes)
    expectCode(uiTruncated): discard decodePng(cut)

  test "decodeImage routes PNG by signature":
    let img = decodeImage(pngBuild(2, 1, 8, 2, @[byte 0, 1, 2, 3, 4, 5, 6]))
    check img.width == 2 and img.height == 1

  test "8-bit gray+alpha expands to RGBA":
    # Real PIL vector (lossless, so byte-exact): each pixel is [gray, alpha] in
    # the scanline; the decoder must replicate gray to RGB and place alpha in A.
    # The pre-fix generic 8-bit branch read 4 channels from a 2-sample row,
    # pulling the neighbour's gray/alpha into G/B.
    # Provenance: regenerated by tests/fixtures/gen_images.py with
    # Pillow==12.3.0 (Image.new("LA", (4,2)) with the pixels below). The PNG
    # encoder is lossless so re-running the generator reproduces this blob.
    let img = decodePng(@[byte 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x02, 0x08, 0x04, 0x00, 0x00, 0x00, 0xD5, 0xA1, 0xB5,
        0xE8, 0x00, 0x00, 0x00, 0x1A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63,
        0xE4, 0x3A, 0xC1, 0xC5, 0xC5, 0xC5, 0xC5, 0xC5, 0xC5, 0x68, 0xC4, 0xC0,
        0xF5, 0x9F, 0xAB, 0x91, 0x6B, 0x05, 0x00, 0x19, 0x73, 0x03, 0x89, 0x9B,
        0xE4, 0x5E, 0xFC, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82])
    check img.width == 4 and img.height == 2
    check img.colorspace == csRgba
    check img.data == @[byte 10, 10, 10, 200, 20, 20, 20, 210, 30, 30, 30, 220,
        40, 40, 40, 230, 50, 50, 50, 0, 60, 60, 60, 255, 70, 70, 70, 128, 80,
        80, 80, 40]

# ---- GIF helpers ----

proc addU16le(b: var seq[byte]; v: int) =
  b.add(byte(v and 0xFF))
  b.add(byte((v shr 8) and 0xFF))

proc gifLzw(indices: seq[uint8]; minCodeSize: int): seq[byte] =
  let clear = 1 shl minCodeSize
  let endc = clear + 1
  var codeSize = minCodeSize + 1
  var dict: Table[seq[uint8], int] = initTable[seq[uint8], int]()
  for i in 0 ..< clear: dict[@[uint8(i)]] = i
  var nextCode = endc + 1
  var outBuf: seq[byte] = @[]
  var bitBuf: uint32
  var bitCnt: int
  proc emit(code: int) =
    bitBuf = bitBuf or (uint32(code) shl bitCnt)
    bitCnt += codeSize
    while bitCnt >= 8:
      outBuf.add(byte(bitBuf and 0xFF))
      bitBuf = bitBuf shr 8
      bitCnt -= 8
  proc flush() =
    if bitCnt > 0:
      outBuf.add(byte(bitBuf and 0xFF))
      bitBuf = 0
      bitCnt = 0
  emit(clear)
  if indices.len > 0:
    var w = @[indices[0]]
    for i in 1 ..< indices.len:
      let k = indices[i]
      let wk = w & @[k]
      if dict.hasKey(wk): w = wk
      else:
        emit(dict[w])
        if nextCode < 4096:
          dict[wk] = nextCode
          inc nextCode
          if nextCode > (1 shl codeSize) and codeSize < 12: inc codeSize
        w = @[k]
    emit(dict[w])
  emit(endc)
  flush()
  return outBuf

proc gifBuild(width, height: int; pal: seq[(uint8, uint8, uint8)];
    indices: seq[uint8]; interlace = false; transparentIdx = -1;
    useLct = false): seq[byte] =
  doAssert pal.len >= 2 and (pal.len and (pal.len - 1)) == 0, "palette size must be a power of 2"
  var bits = 0
  var n = pal.len
  while n > 1: n = n shr 1; inc bits
  dec bits # bits = log2(pal.len) - 1
  let minCodeSize = max(2, bits + 1)
  result = @[]
  for c in "GIF89a": result.add(byte(c))
  result.addU16le(width)
  result.addU16le(height)
  let gctPacked = if useLct: 0'u8 else: 0x80'u8 or byte(bits)
  result.add(gctPacked)
  result.add(0'u8) # background color index
  result.add(0'u8) # pixel aspect ratio
  if not useLct:
    for c in pal:
      result.add(c[0]); result.add(c[1]); result.add(c[2])
  if transparentIdx >= 0:
    result.add(0x21'u8); result.add(0xF9'u8); result.add(
        0x04'u8) # GCE introducer + label + block size
    result.add(0x01'u8) # packed: transparent flag set
    result.add(0'u8); result.add(0'u8) # delay (unused)
    result.add(byte(transparentIdx))
    result.add(0'u8) # block terminator
  result.add(0x2C'u8) # image descriptor
  result.addU16le(0); result.addU16le(0) # left, top
  result.addU16le(width); result.addU16le(height)
  let imgPacked = (if interlace: 0x40'u8 else: 0'u8) or
      (if useLct: 0x80'u8 or byte(bits) else: 0'u8)
  result.add(imgPacked)
  if useLct:
    for c in pal:
      result.add(c[0]); result.add(c[1]); result.add(c[2])
  result.add(byte(minCodeSize))
  let lzw = gifLzw(indices, minCodeSize)
  var i = 0
  while i < lzw.len:
    let chunk = min(255, lzw.len - i)
    result.add(byte(chunk))
    for k in 0 ..< chunk: result.add(lzw[i + k])
    i += chunk
  result.add(0'u8) # sub-block terminator
  result.add(0x3B'u8) # trailer

suite "gif decode":
  test "2x2 indexed maps through global color table":
    let pal = @[(0'u8, 0'u8, 0'u8), (0'u8, 0'u8, 255'u8),
        (0'u8, 255'u8, 0'u8), (255'u8, 0'u8, 0'u8)]
    let g = gifBuild(2, 2, pal, @[byte 0, 1, 2, 3])
    let img = decodeGif(g)
    check img.width == 2 and img.height == 2
    check img.colorspace == csRgba
    check img.data == @[uint8 0, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255,
        255, 0, 0, 255]

  test "transparency sets alpha 0 for the transparent index":
    let pal = @[(255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8)]
    let g = gifBuild(2, 1, pal, @[byte 0, 1], transparentIdx = 0)
    let img = decodeGif(g)
    check img.data == @[uint8 255, 0, 0, 0, 0, 255, 0, 255]

  test "local color table overrides the global one":
    let lct = @[(0'u8, 0'u8, 0'u8), (255'u8, 0'u8, 0'u8)]
    let g = gifBuild(2, 1, lct, @[byte 0, 1], useLct = true)
    let img = decodeGif(g)
    check img.data == @[uint8 0, 0, 0, 255, 255, 0, 0, 255]

  test "interlaced rows are deinterlaced":
    let pal = @[(0'u8, 0'u8, 0'u8), (0'u8, 0'u8, 255'u8),
        (0'u8, 255'u8, 0'u8), (255'u8, 0'u8, 0'u8)]
    # File order (interlaced) rows: 0, 2, 1, 3 -> indices [0, 1, 2, 3].
    let g = gifBuild(1, 4, pal, @[byte 0, 1, 2, 3], interlace = true)
    let img = decodeGif(g)
    # row0=pal[0], row1=pal[2], row2=pal[1], row3=pal[3].
    check img.data == @[uint8 0, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
        255, 0, 0, 255]

  test "decodeImage routes GIF by magic":
    let pal = @[(0'u8, 0'u8, 0'u8), (255'u8, 255'u8, 255'u8)]
    let img = decodeImage(gifBuild(2, 1, pal, @[byte 0, 1]))
    check img.width == 2 and img.height == 1

  test "bad version raises uiUnsupported":
    var g = gifBuild(1, 1, @[(0'u8, 0'u8, 0'u8), (255'u8, 255'u8, 255'u8)],
        @[byte 0])
    g[4] = byte('6') # GIF86a is not a real version
    expectCode(uiUnsupported): discard decodeGif(g)

  test "truncated header raises uiTruncated":
    expectCode(uiTruncated): discard decodeGif(@[byte 0x47, 0x49, 0x46])

  test "no image descriptor raises":
    # Trailer immediately after the header + a tiny global color table.
    var g: seq[byte] = @[]
    for c in "GIF89a": g.add(byte(c))
    g.addU16le(1); g.addU16le(1)
    g.add(0x80'u8) # GCT flag, size 0 -> 2 entries
    g.add(0'u8); g.add(0'u8)
    g.add(0'u8); g.add(0'u8); g.add(0'u8)
    g.add(0'u8); g.add(0'u8); g.add(0'u8)
    g.add(0x3B'u8)
    expectCode(uiInvalidArg): discard decodeGif(g)

# ---- JPEG helpers ----

proc be16(v: int): seq[byte] = @[byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc jpegSeg(marker: byte; payload: seq[byte]): seq[byte] =
  result = @[byte 0xFF, marker]
  result.add(be16(payload.len + 2))
  result.add(payload)

proc jpegBuild(width, height, ncomp: int; entropy: seq[byte];
    sofMarker = 0xC0'u8; acRun = false): seq[byte] =
  doAssert ncomp in {1, 3}
  result = @[byte 0xFF, 0xD8] # SOI
  # DQT: one 8-bit table (id 0), all values 1.
  var dqt: seq[byte] = @[byte 0x00]
  for _ in 0 ..< 64: dqt.add(0x01'u8)
  result.add(jpegSeg(0xDB'u8, dqt))
  # DHT: DC table 0 (symbols 0x00, 0x0B; two 1-bit codes) + AC table 0 (EOB,
  # plus RRRR=1/SSSS=1 when `acRun`, so a block can carry a real coefficient).
  var dht: seq[byte] = @[]
  dht.add(0x00'u8) # class 0 (DC), id 0
  dht.add(0x02'u8); for _ in 0 ..< 15: dht.add(0'u8) # counts: 2 codes of length 1
  dht.add(0x00'u8); dht.add(0x0B'u8) # symbols: SSSS=0, SSSS=11
  dht.add(0x10'u8) # class 1 (AC), id 0
  if acRun:
    dht.add(0x02'u8); for _ in 0 ..< 15: dht.add(0'u8) # counts: 2 codes of length 1
    dht.add(0x00'u8); dht.add(0x11'u8) # symbols: EOB, one zero then SSSS=1
  else:
    dht.add(0x01'u8); for _ in 0 ..< 15: dht.add(0'u8) # counts: 1 code of length 1
    dht.add(0x00'u8) # symbol: EOB
  result.add(jpegSeg(0xC4'u8, dht))
  # SOF0
  var sof: seq[byte] = @[byte 0x08] # precision 8
  sof.add(be16(height)); sof.add(be16(width))
  sof.add(byte(ncomp))
  for k in 1 .. ncomp:
    sof.add(byte(k)); sof.add(0x11'u8); sof.add(0x00'u8) # id, h=v=1, qt 0
  result.add(jpegSeg(sofMarker, sof))
  # SOS
  var sos: seq[byte] = @[byte(ncomp)]
  for k in 1 .. ncomp:
    sos.add(byte(k)); sos.add(0x00'u8) # id, td=ta=0
  sos.add(0x00'u8); sos.add(0x3F'u8); sos.add(0x00'u8) # Ss, Se, Ah|Al
  result.add(jpegSeg(0xDA'u8, sos))
  result.add(entropy)
  result.add(@[byte 0xFF, 0xD9]) # EOI

proc uniformEntropy(nBlocks: int): seq[byte] =
  # Each block: DC code "0" (SSSS=0) + AC code "0" (EOB) = 2 zero bits. The
  # final byte is padded with 1-bits, which no code here starts with, so the
  # padding cannot read as one more block.
  let bits = 2 * nBlocks
  let bytes = (bits + 7) div 8
  result = newSeq[byte](bytes)
  let pad = bytes * 8 - bits
  if pad > 0: result[^1] = byte((1 shl pad) - 1)

suite "jpeg decode":
  test "grayscale 8x8 uniform 128":
    let j = jpegBuild(8, 8, 1, uniformEntropy(1))
    let img = decodeJpeg(j)
    check img.width == 8 and img.height == 8
    check img.colorspace == csGray
    var ok = true
    for v in img.data:
      if v != 128: ok = false
    check ok

  test "grayscale 8x8 uniform 0 (nonzero DC, sign extend, IDCT)":
    # Flat block at 0: DCT DC = 64*(-128)/8 = -1024, quant 1 -> diff -1024.
    # SSSS=11, magnitude 1024 -> stored value 1023 (11 bits 0b01111111111).
    # DC code "1" (symbol 0x0B) + 11 bits + AC "0" (EOB).
    let entropy = @[byte 0xBF, 0xF7]
    let img = decodeJpeg(jpegBuild(8, 8, 1, entropy))
    check img.colorspace == csGray
    var ok = true
    for v in img.data:
      if v != 0: ok = false
    check ok

  test "ycbcr 8x8 4:4:4 uniform 128":
    let img = decodeJpeg(jpegBuild(8, 8, 3, uniformEntropy(3)))
    check img.colorspace == csRgb
    var ok = true
    for k in 0 ..< img.data.len:
      if img.data[k] != 128: ok = false
    check ok

  test "one eighth keeps the DC level and a block becomes one pixel":
    # A flat block at 128 must survive the reduction: with only the DC
    # coefficient, the block's single sample is its mean.
    let img = decodeJpeg(jpegBuild(8, 8, 1, uniformEntropy(1)), jdEighth)
    check img.width == 1 and img.height == 1
    check img.colorspace == csGray
    check img.data == @[128'u8]

  test "one eighth reads the same bitstream as a full decode":
    # The AC coefficients are skipped, not ignored: a stream carrying them has
    # to be walked to the end, or the next block starts at the wrong bit.
    let entropy = @[byte 0xBF, 0xF7]
    let full = decodeJpeg(jpegBuild(8, 8, 1, entropy))
    let small = decodeJpeg(jpegBuild(8, 8, 1, entropy), jdEighth)
    check full.width == 8 and small.width == 1
    check small.data == @[0'u8]

  test "one eighth walks a block's AC payload, so the next block stays aligned":
    # Two blocks side by side, the first carrying an actual AC coefficient.
    # Block 1: DC "0" (diff 0) + AC "1" (RRRR=1, SSSS=1) + magnitude bit "0"
    # (-1) + AC "0" (EOB)                                        -> 0100
    # Block 2: DC "1" (SSSS=11) + 11 bits 10000000000 (+1024) + AC "0" (EOB).
    # Padded with 1-bits: 0100 1 10000000000 0 1111111.
    let entropy = @[byte 0x4C, 0x00, 0x7F]
    let j = jpegBuild(16, 8, 1, entropy, acRun = true)
    let small = decodeJpeg(j, jdEighth)
    check small.width == 2 and small.height == 1
    # 128 from a zero DC, 255 from +1024/8 clamped: the second block was read
    # at the right bit, which only happens if block 1's AC payload was walked.
    check small.data == @[128'u8, 255'u8]
    check decodeJpeg(j).width == 16 # the same stream decodes in full

  test "one eighth rounds the size up, so no block is dropped":
    # 8x8 of blocks over a 12x12 image: two blocks each way, both kept.
    let j = jpegBuild(12, 12, 1, uniformEntropy(4))
    check decodeJpeg(j).width == 12
    let small = decodeJpeg(j, jdEighth)
    check small.width == 2 and small.height == 2

  test "one eighth of a colour image stays colour":
    let img = decodeJpeg(jpegBuild(8, 8, 3, uniformEntropy(3)), jdEighth)
    check img.colorspace == csRgb
    check img.width == 1 and img.height == 1
    check img.data.len == 3

  test "a large JPEG is reduced, and reports the size it came from":
    # 64 blocks each way: asking for 8 lets the eighth-scale decode answer.
    let j = jpegBuild(512, 512, 1, uniformEntropy(64 * 64))
    let scaled = decodeImageScaled(j, 8)
    check scaled.image.width == 64 and scaled.image.height == 64
    check scaled.sourceWidth == 512 and scaled.sourceHeight == 512

  test "a JPEG too small to reduce is decoded in full":
    let j = jpegBuild(64, 64, 1, uniformEntropy(8 * 8))
    let scaled = decodeImageScaled(j, 32)
    check scaled.image.width == 64
    check scaled.sourceWidth == 64 and scaled.sourceHeight == 64

  test "a format that cannot reduce still reports its own size":
    let png = encodeImage(newImage[uint8](40, 20, csGray), efPng)
    let scaled = decodeImageScaled(png, 4)
    check scaled.image.width == 40 and scaled.image.height == 20
    check scaled.sourceWidth == 40 and scaled.sourceHeight == 20

  test "decodeImageScaled refuses a maxEdge below one":
    let j = jpegBuild(8, 8, 1, uniformEntropy(1))
    expectCode(uiInvalidArg): discard decodeImageScaled(j, 0)

  test "decodeImage routes JPEG by SOI":
    let img = decodeImage(jpegBuild(8, 8, 1, uniformEntropy(1)))
    check img.width == 8 and img.height == 8

  test "bad SOI raises uiUnsupported":
    expectCode(uiUnsupported): discard decodeJpeg(@[byte 0x00, 0x00])

  test "truncated raises uiTruncated":
    let j = jpegBuild(8, 8, 1, uniformEntropy(1))
    let cut = j[0 ..< j.len - 3] # drop entropy byte + EOI -> empty entropy stream
    expectCode(uiTruncated): discard decodeJpeg(cut)

  test "progressive SOF2 raises uiUnsupported":
    let j = jpegBuild(8, 8, 1, uniformEntropy(1), sofMarker = 0xC2'u8)
    expectCode(uiUnsupported): discard decodeJpeg(j)


  # Real JPEGs (Pillow 12.3.0 vectors) exercising the fixed code paths that
  # the synthetic uniform blocks above do not reach.
  # Provenance: regenerated by tests/fixtures/gen_images.py with
  # Pillow==12.3.0 (which bundles a fixed libjpeg-turbo). JPEG is lossy and
  # libjpeg-version dependent, so a different Pillow pair yields different
  # bytes; the committed blobs are the Pillow 12.3.0 output and the tests
  # assert structural properties (dimensions, colorspace, non-flat output)
  # rather than exact pixels. Use `gen_images.py --dump-nim` to refresh the
  # inlined literals after a deliberate toolchain bump.

  test "4:2:0 non-multiple-of-16 width does not access outside the image":
    # 17x5 4:2:0: hMax=vMax=2, mcusX=2. The pre-fix buffer sizing used
    # ceil(width*h/(hMax*8)) = ceil(17*2/16) = 3 < mcusX*h = 4 for luma, so the
    # MCU grid wrote past bufW[0] -> IndexDefect. The MCU-grid sizing now holds.
    let img = decodeJpeg(@[byte 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
        0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
        0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B,
        0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D,
        0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C,
        0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
        0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xDB, 0x00,
        0x43, 0x01, 0x09, 0x09, 0x09, 0x0C, 0x0B, 0x0C, 0x18, 0x0D, 0x0D, 0x18,
        0x32, 0x21, 0x1C, 0x21, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32,
        0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32,
        0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32,
        0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0x32,
        0x32, 0x32, 0x32, 0x32, 0x32, 0x32, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00,
        0x05, 0x00, 0x11, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
        0x01, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4,
        0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05,
        0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04,
        0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22,
        0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15,
        0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A,
        0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66,
        0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A,
        0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95,
        0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8,
        0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2,
        0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5,
        0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7,
        0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9,
        0xFA, 0xFF, 0xC4, 0x00, 0x1F, 0x01, 0x00, 0x03, 0x01, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4,
        0x00, 0xB5, 0x11, 0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07,
        0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77, 0x00, 0x01, 0x02, 0x03, 0x11,
        0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13,
        0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23,
        0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1,
        0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x35,
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65,
        0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93,
        0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6,
        0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9,
        0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3,
        0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6,
        0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9,
        0xFA, 0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11,
        0x00, 0x3F, 0x00, 0xCA, 0xD3, 0xBC, 0x0F, 0xA6, 0x71, 0xC7, 0xFE, 0x3B,
        0x5D, 0x6E, 0x9D, 0xE0, 0x7D, 0x33, 0x8E, 0x3F, 0xF1, 0xDA, 0x28, 0xAC,
        0xB0, 0xB8, 0x8A, 0xBF, 0xCC, 0x79, 0x19, 0x26, 0x61, 0x8A, 0xD3, 0xDF,
        0x66, 0xCF, 0xFC, 0x21, 0x1A, 0x67, 0xA7, 0xFE, 0x3B, 0x45, 0x14, 0x57,
        0xA7, 0xF5, 0x9A, 0xBF, 0xCC, 0x7D, 0x9F, 0xF6, 0x86, 0x2B, 0xF9, 0xD9,
        0xFF, 0xD9])
    check img.width == 17 and img.height == 5
    check img.colorspace == csRgb

  test "noise block exercises the full AC zigzag path":
    # 8x8 random-noise grayscale: high-frequency AC coefficients are non-zero,
    # so decodeBlock walks deep into ZigZag (the missing-entry/OOB the static
    # assert now guards against). Asserts non-trivial output, not a flat field.
    let img = decodeJpeg(@[byte 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
        0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
        0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B,
        0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D,
        0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C,
        0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
        0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00,
        0x0B, 0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4,
        0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10,
        0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04,
        0x00, 0x00, 0x01, 0x7D, 0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32,
        0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A,
        0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55,
        0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85,
        0x86, 0x87, 0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2,
        0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
        0xD9, 0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
        0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA,
        0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7D, 0xC4, 0xB7, 0x7A,
        0x4F, 0x88, 0x58, 0x08, 0xAF, 0x1A, 0x18, 0x5A, 0x26, 0x86, 0xD9, 0x58,
        0xBA, 0x5A, 0x3E, 0xD9, 0x42, 0xA2, 0xBE, 0x18, 0x65, 0x4A, 0x82, 0x82,
        0x40, 0xC0, 0x03, 0xC2, 0x8A, 0xFF, 0xD9])
    check img.width == 8 and img.height == 8
    check img.colorspace == csGray
    var mn = 255'u8
    var mx = 0'u8
    for v in img.data:
      if v < mn: mn = v
      if v > mx: mx = v
    check mx > mn # noise is not crushed to a single value
