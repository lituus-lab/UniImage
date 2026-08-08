# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## PNM decoder (Portable Anymap: PBM/PGM/PPM, ASCII P1-P3, binary P4-P6, and
## P7 PAM). Reimplemented from the Netpbm spec — not vendored. Samples whose
## maximum exceeds 255 are downscaled to 8-bit to fit `Image[uint8]`; a 16-bit surface would
## need `Image[uint16]`. Bitmap (P1/P4) outputs csGray (1=black,
## 0=white -> 0/255); grayscale -> csGray; PPM -> csRgb.
import std/strutils
import UniImage/core
import util

const PnmWs = {byte 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20}

proc pnmSkip(data: openArray[byte]; pos: var int) =
  while pos < data.len:
    if data[pos] == byte('#'):
      while pos < data.len and data[pos] notin {byte 0x0A, 0x0D}: inc pos
    elif data[pos] in PnmWs:
      inc pos
    else: break

proc pnmInt(data: openArray[byte]; pos: var int): int =
  pnmSkip(data, pos)
  if pos >= data.len or data[pos] < byte('0') or data[pos] > byte('9'):
    raise UniImageException(code: uiTruncated, msg: "pnm: expected an integer")
  var n = 0
  while pos < data.len and data[pos] >= byte('0') and data[pos] <= byte('9'):
    let digit = int(data[pos]) - int(byte('0'))
    if n > (high(int) - digit) div 10:
      raise UniImageException(code: uiInvalidArg,
          msg: "pnm: integer exceeds the platform range")
    n = n * 10 + digit
    inc pos
  result = n

proc scale(v, maxval: int): uint8 {.inline.} =
  let vv = if v > maxval: maxval elif v < 0: 0 else: v
  uint8((vv * 255 + maxval div 2) div maxval)

proc pamFieldInt(key, val: string): int =
  ## Parse a PAM header integer field, converting a malformed value into
  ## `UniImageException(uiInvalidArg)` — `parseInt` would raise `ValueError`,
  ## which would escape the documented `decodePnm`/`decodeImage` contract.
  try: result = parseInt(val)
  except ValueError:
    raise UniImageException(code: uiInvalidArg,
        msg: "pnm: PAM bad " & key & " value")

proc decodePam(data: openArray[byte]): Image[uint8] =
  ## Decode a P7 (PAM) binary image. Reads the keyword/value header (WIDTH,
  ## HEIGHT, DEPTH, MAXVAL, TUPLTYPE) up to ENDHDR, then the raster. DEPTH 1 ->
  ## csGray, 3 -> csRgb, 4 -> csRgba; other depths raise uiUnsupported.
  var pos = 2
  var width = -1; var height = -1; var depth = -1; var maxval = -1
  var tupl = ""
  while true:
    if pos >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "pnm: PAM header truncated")
    let lineStart = pos
    while pos < data.len and data[pos] != byte('\n'): inc pos
    if pos >= data.len:
      raise UniImageException(code: uiTruncated,
          msg: "pnm: PAM header truncated")
    var line = ""
    for b in data[lineStart ..< pos]: line.add(char(b))
    inc pos # consume the newline
    let s = line.strip()
    if s.len == 0: continue
    if s.startsWith("#"): continue # PAM headers allow '#' comment lines
    if s == "ENDHDR": break
    let sp = s.find(' ')
    if sp < 0:
      raise UniImageException(code: uiInvalidArg,
          msg: "pnm: bad PAM header line")
    let key = s[0 ..< sp]
    let val = s[sp + 1 .. ^1].strip()
    case key
    of "WIDTH": width = pamFieldInt("WIDTH", val)
    of "HEIGHT": height = pamFieldInt("HEIGHT", val)
    of "DEPTH": depth = pamFieldInt("DEPTH", val)
    of "MAXVAL": maxval = pamFieldInt("MAXVAL", val)
    of "TUPLTYPE": tupl = val
    else: discard # unknown headers are ignored
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pnm: PAM bad dimensions")
  if depth notin {1, 3, 4}:
    raise UniImageException(code: uiUnsupported,
        msg: "pnm: PAM depth must be 1, 3, or 4")
  if maxval <= 0 or maxval > 65535:
    raise UniImageException(code: uiInvalidArg, msg: "pnm: PAM bad maxval")
  let total = width * height
  if total > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pnm: too many pixels")
  let cs = if depth == 1: csGray elif depth == 3: csRgb else: csRgba
  result = newImage[uint8](width, height, cs)
  let bps = if maxval > 255: 2 else: 1
  if pos + total * depth * bps > data.len:
    raise UniImageException(code: uiTruncated, msg: "pnm: PAM data truncated")
  for i in 0 ..< total:
    for c in 0 ..< depth:
      let v = if bps == 1: int(data[pos]) else:
        int(data[pos]) shl 8 or int(data[pos + 1])
      pos += bps
      result.data[i * depth + c] = scale(v, maxval)

proc decodePnm*(data: openArray[byte]): Image[uint8] =
  ## Decode an in-memory PNM (P1-P6) into an 8-bit `Image`. Raises
  ## `UniImageException`.
  requireLen(data, 2, "pnm: header truncated")
  if data[0] != byte('P'):
    raise UniImageException(code: uiUnsupported,
        msg: "pnm: not a PNM container")
  let k = data[1]
  if k == byte('7'): return decodePam(data) # P7 (PAM) has a keyword header
  if k < byte('1') or k > byte('6'):
    raise UniImageException(code: uiUnsupported, msg: "pnm: unsupported type")
  let fmt = int(k) - int(byte('1')) + 1
  let binary = fmt >= 4
  let isColor = fmt == 3 or fmt == 6
  let isBitmap = fmt == 1 or fmt == 4
  var pos = 2
  let width = pnmInt(data, pos)
  let height = pnmInt(data, pos)
  if width <= 0 or height <= 0 or width > MaxCodecDim or height > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pnm: bad dimensions")
  var maxval = 1
  if not isBitmap:
    maxval = pnmInt(data, pos)
    if maxval <= 0 or maxval > 65535:
      raise UniImageException(code: uiInvalidArg, msg: "pnm: bad maxval")
  let total = width * height
  if total > MaxCodecDim:
    raise UniImageException(code: uiInvalidArg, msg: "pnm: too many pixels")
  let cs = if isColor: csRgb else: csGray
  result = newImage[uint8](width, height, cs)
  if binary:
    if pos >= data.len or data[pos] > byte(0x20):
      raise UniImageException(code: uiInvalidArg,
        msg: "pnm: missing whitespace after header")
    inc pos # exactly one whitespace separates the header from the payload
  if isBitmap:
    if binary: # P4
      let rowBytes = (width + 7) div 8
      if pos + rowBytes * height > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "pnm: P4 data truncated")
      for dy in 0 ..< height:
        let rowBase = pos + dy * rowBytes
        for dx in 0 ..< width:
          let bit = (data[rowBase + (dx shr 3)] shr (7 - (dx and 7))) and 1
          result.data[dy * width + dx] = if bit == 1: uint8 0 else: uint8 255
    else: # P1
      for i in 0 ..< total:
        let v = pnmInt(data, pos)
        if v notin {0, 1}:
          raise UniImageException(code: uiInvalidArg,
              msg: "pnm: P1 sample not 0/1")
        result.data[i] = if v == 1: uint8 0 else: uint8 255
  elif isColor:
    if binary: # P6
      let bps = if maxval > 255: 2 else: 1
      if pos + total * 3 * bps > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "pnm: P6 data truncated")
      for i in 0 ..< total:
        for c in 0 ..< 3:
          let v = if bps == 1: int(data[pos]) else:
            int(data[pos]) shl 8 or int(data[pos + 1])
          pos += bps
          result.data[i * 3 + c] = scale(v, maxval)
    else: # P3
      for i in 0 ..< total:
        for c in 0 ..< 3:
          result.data[i * 3 + c] = scale(pnmInt(data, pos), maxval)
  else: # grayscale P2/P5
    if binary: # P5
      let bps = if maxval > 255: 2 else: 1
      if pos + total * bps > data.len:
        raise UniImageException(code: uiTruncated,
            msg: "pnm: P5 data truncated")
      for i in 0 ..< total:
        let v = if bps == 1: int(data[pos]) else:
          int(data[pos]) shl 8 or int(data[pos + 1])
        pos += bps
        result.data[i] = scale(v, maxval)
    else: # P2
      for i in 0 ..< total:
        result.data[i] = scale(pnmInt(data, pos), maxval)

proc encodePnm*(img: Image[uint8]): seq[byte] =
  ## Encode an 8-bit `Image` as binary Netpbm: csRgb -> P6 (PPM), csGray -> P5
  ## (PGM), csRgba -> P7 (PAM, RGB_ALPHA). Raises `UniImageException` for other
  ## color spaces or 16-bit-only targets. Reimplemented from the Netpbm spec.
  template hdr(s: string) =
    for c in s: result.add byte(c)
  case img.colorspace
  of csRgb:
    result = newSeqOfCap[byte](32 + img.data.len)
    hdr "P6\n" & $img.width & " " & $img.height & "\n255\n"
    result.add img.data
  of csGray:
    result = newSeqOfCap[byte](32 + img.data.len)
    hdr "P5\n" & $img.width & " " & $img.height & "\n255\n"
    result.add img.data
  of csRgba:
    result = newSeqOfCap[byte](64 + img.data.len)
    hdr "P7\nWIDTH " & $img.width & "\nHEIGHT " & $img.height & "\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
    result.add img.data
  else:
    raise UniImageException(code: uiUnsupported,
        msg: "pnm: encode needs csRgb, csGray, or csRgba")
