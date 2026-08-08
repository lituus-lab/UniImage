# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## QOI (Quite OK Image) decoder. Reimplemented from the public-domain QOI spec
## (https://qoiformat.org) — not vendored. Supports RGB (3-channel) and RGBA
## (4-channel); the 8-byte end marker is consumed implicitly (the loop stops
## once `width × height` pixels are decoded). Output color space matches the header:
## 3 channels -> csRgb, 4 -> csRgba.
import contracts
import UniImage/core
import ./util

proc decodeQoiImpl(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory QOI into an 8-bit `Image`. Raises `UniImageException`.
  requireLen(data, 14, "qoi: header truncated")
  if data[0] != 0x71 or data[1] != 0x6F or data[2] != 0x69 or data[3] != 0x66:
    raise UniImageException(code: uiUnsupported,
        msg: "qoi: not a qoif container")
  let width = int(readU32be(data, 4))
  let height = int(readU32be(data, 8))
  let channels = int(data[12])
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "qoi: bad dimensions")
  if channels notin {3, 4}:
    raise UniImageException(code: uiUnsupported,
        msg: "qoi: channels must be 3 or 4")
  let outCh = if channels == 3: 3 else: 4
  let total64 = int64(width) * int64(height)
  if total64 > int64(MaxCodecDim):
    raise UniImageException(code: uiInvalidArg, msg: "qoi: too many pixels")
  let total = int(total64)
  result = newImage[uint8](width, height, if channels == 3: csRgb else: csRgba)
  var pos = 14
  var pr = uint8 0
  var pg = uint8 0
  var pb = uint8 0
  var pa = uint8 255
  var tab: array[64, array[4, uint8]]
  var written = 0
  while written < total:
    if pos >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "qoi: pixel stream truncated")
    let b0 = data[pos]
    inc pos
    if b0 == 0xFE: # QOI_OP_RGB
      if pos + 3 > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "qoi: RGB chunk truncated")
      pr = data[pos]; pg = data[pos + 1]; pb = data[pos + 2]; pos += 3
    elif b0 == 0xFF: # QOI_OP_RGBA
      if pos + 4 > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "qoi: RGBA chunk truncated")
      pr = data[pos]; pg = data[pos + 1]; pb = data[pos + 2]; pa = data[pos + 3]
      pos += 4
    else:
      let tag = b0 shr 6
      case tag
      of 0: # QOI_OP_INDEX
        let idx = int(b0 and 0x3F)
        pr = tab[idx][0]; pg = tab[idx][1]; pb = tab[idx][2]; pa = tab[idx][3]
      of 1: # QOI_OP_DIFF
        pr = uint8((int(pr) + int((b0 shr 4) and 3) - 2) and 0xFF)
        pg = uint8((int(pg) + int((b0 shr 2) and 3) - 2) and 0xFF)
        pb = uint8((int(pb) + int(b0 and 3) - 2) and 0xFF)
      of 2: # QOI_OP_LUMA
        if pos >= data.len:
          raise UniImageException(code: uiTruncated,
              msg: "qoi: LUMA chunk truncated")
        let b1 = data[pos]
        inc pos
        let dg = int(b0 and 0x3F) - 32
        pr = uint8((int(pr) + dg + int(b1 shr 4) - 8) and 0xFF)
        pg = uint8((int(pg) + dg) and 0xFF)
        pb = uint8((int(pb) + dg + int(b1 and 0xF) - 8) and 0xFF)
      of 3: # QOI_OP_RUN
        let run = int(b0 and 0x3F) + 1
        if run > total - written:
          raise UniImageException(code: uiInvalidArg,
              msg: "qoi: run exceeds image bounds")
        for _ in 0 ..< run:
          result.data[written * outCh] = pr
          result.data[written * outCh + 1] = pg
          result.data[written * outCh + 2] = pb
          if outCh == 4: result.data[written * outCh + 3] = pa
          inc written
        let h = (int(pr) * 3 + int(pg) * 5 + int(pb) * 7 + int(pa) * 11) mod 64
        tab[h] = [pr, pg, pb, pa]
        continue
      else: discard # tag is 0..3, exhaustive
    result.data[written * outCh] = pr
    result.data[written * outCh + 1] = pg
    result.data[written * outCh + 2] = pb
    if outCh == 4: result.data[written * outCh + 3] = pa
    inc written
    let h = (int(pr) * 3 + int(pg) * 5 + int(pb) * 7 + int(pa) * 11) mod 64
    tab[h] = [pr, pg, pb, pa]

proc decodeQoi*(data: openArray[byte]): Image[uint8] {.contractual.} =
  ## Decode an in-memory QOI into an 8-bit `Image`. Raises `UniImageException`.
  ensure:
    result.width * result.height * result.channels == result.data.len
  body:
    result = decodeQoiImpl(data)

proc qoiFlushRun(b: var seq[byte]; r: var int) {.inline.} =
  ## Emit accumulated QOI_OP_RUN packets (max 62 per packet).
  while r > 0:
    let n = min(62, r)
    b.add byte(0xC0 or (n - 1))
    r -= n

proc encodeQoiImpl(img: Image[uint8]): seq[byte] =
  ## Encode an 8-bit `Image` as QOI. Supports csRgb (3-channel) and csRgba
  ## (4-channel). Raises `UniImageException(uiUnsupported)` for other color
  ## spaces. Reimplemented from the public-domain QOI spec — not vendored.
  let outCh = img.channels
  if outCh notin {3, 4}:
    raise UniImageException(code: uiUnsupported,
        msg: "qoi: encode needs csRgb or csRgba")
  result = newSeqOfCap[byte](14 + img.data.len + 8)
  # Header: "qoif", width/height big-endian, channels, colorspace (0 = sRGB).
  result.add @[byte 0x71, 0x6F, 0x69, 0x66]
  result.add byte((img.width shr 24) and 0xFF)
  result.add byte((img.width shr 16) and 0xFF)
  result.add byte((img.width shr 8) and 0xFF)
  result.add byte(img.width and 0xFF)
  result.add byte((img.height shr 24) and 0xFF)
  result.add byte((img.height shr 16) and 0xFF)
  result.add byte((img.height shr 8) and 0xFF)
  result.add byte(img.height and 0xFF)
  result.add byte(outCh)
  result.add byte 0 # colorspace: sRGB
  var tab: array[64, array[4, uint8]]
  var pr = 0'u8; var pg = 0'u8; var pb = 0'u8; var pa = 255'u8
  var run = 0
  let total = img.width * img.height
  for i in 0 ..< total:
    let r = img.data[i * outCh]
    let g = img.data[i * outCh + 1]
    let b = img.data[i * outCh + 2]
    let a = if outCh == 4: img.data[i * outCh + 3] else: 255'u8
    if r == pr and g == pg and b == pb and a == pa:
      inc run
      if run == 62: qoiFlushRun(result, run)
    else:
      qoiFlushRun(result, run); run = 0
      let h = (int(r) * 3 + int(g) * 5 + int(b) * 7 + int(a) * 11) mod 64
      if tab[h][0] == r and tab[h][1] == g and tab[h][2] == b and tab[h][3] == a:
        result.add byte(h) # QOI_OP_INDEX
      elif a != pa:
        result.add 0xFF'u8
        result.add r; result.add g; result.add b; result.add a
      else:
        let dr = ((int(r) - int(pr) + 128) and 0xFF) - 128
        let dg = ((int(g) - int(pg) + 128) and 0xFF) - 128
        let db = ((int(b) - int(pb) + 128) and 0xFF) - 128
        if dr in -2 .. 1 and dg in -2 .. 1 and db in -2 .. 1:
          result.add byte(0x40 or ((dr + 2) shl 4) or ((dg + 2) shl 2) or (db + 2))
        elif dg in -32 .. 31 and (dr - dg) in -8 .. 7 and (db - dg) in -8 .. 7:
          result.add byte(0x80 or ((dg + 32) and 0x3F))
          result.add byte((((dr - dg) + 8) shl 4) or ((db - dg) + 8))
        else:
          result.add 0xFE'u8
          result.add r; result.add g; result.add b
      tab[h] = [r, g, b, a]
      pr = r; pg = g; pb = b; pa = a
  qoiFlushRun(result, run)
  # 8-byte end marker.
  result.add @[byte 0, 0, 0, 0, 0, 0, 0, 1]

proc encodeQoi*(img: Image[uint8]): seq[byte] {.contractual.} =
  ## Encode an RGB or RGBA 8-bit image as QOI.
  require:
    img.channels in {3, 4}
  ensure:
    result.len >= 22
  body:
    result = encodeQoiImpl(img)
