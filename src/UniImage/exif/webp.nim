# SPDX-License-Identifier: Apache-2.0

## WebP metadata: locate the EXIF chunk (a raw TIFF block) in the RIFF container.

import ./endian

proc isWebp*(data: openArray[byte]): bool =
  data.len >= 12 and
    data[0] == byte('R') and data[1] == byte('I') and
    data[2] == byte('F') and data[3] == byte('F') and
    data[8] == byte('W') and data[9] == byte('E') and
    data[10] == byte('B') and data[11] == byte('P')

proc findExifInWebp*(data: openArray[byte]): int =
  ## Offset of the TIFF block inside the WebP "EXIF" chunk (skipping an optional
  ## "Exif\0\0" prefix some encoders add), or 0.
  if not isWebp(data): return 0
  var i = 12
  while i + 8 <= data.len:
    var fourcc = ""
    for k in 0 .. 3: fourcc.add char(data[i + k])
    let size = int(readUint32(data, i + 4, LittleEndian))
    let dataStart = i + 8
    if fourcc == "EXIF" and dataStart < data.len:
      if dataStart + 6 <= data.len and data[dataStart] == 0x45 and
         data[dataStart + 1] == 0x78 and data[dataStart + 2] == 0x69 and
         data[dataStart + 3] == 0x66:
        return dataStart + 6
      return dataStart
    i = dataStart + size + (size and 1) # chunks are padded to even size
  0

# --- write -----------------------------------------------------------------

const
  ExifFlag = 0x08'u8 # VP8X flags byte: bit3 = EXIF present
  XmpFlag = 0x04'u8  # bit2 = XMP present

proc le32w(v: int): seq[byte] =
  @[byte(v and 0xFF), byte((v shr 8) and 0xFF),
    byte((v shr 16) and 0xFF), byte((v shr 24) and 0xFF)]

proc webpChunk(fourcc: string; payload: openArray[byte]): seq[byte] =
  for k in 0 .. 3: result.add byte(fourcc[k])
  result.add le32w(payload.len)
  for b in payload: result.add b
  if payload.len mod 2 == 1: result.add 0 # pad to even

proc assembleWebp(chunks: seq[seq[byte]]): seq[byte] =
  var body = @[byte('W'), byte('E'), byte('B'), byte('P')]
  for c in chunks: body.add c
  result = @[byte('R'), byte('I'), byte('F'), byte('F')]
  result.add le32w(body.len)
  result.add body

iterator chunks(data: openArray[byte]): (string, int, int) =
  ## (fourcc, payloadStart, size) for each chunk after the WEBP signature.
  var i = 12
  while i + 8 <= data.len:
    var f = ""
    for k in 0 .. 3: f.add char(data[i + k])
    let size = int(readUint32(data, i + 4, LittleEndian))
    if i + 8 + size > data.len: break
    yield (f, i + 8, size)
    i += 8 + size + (size and 1)

proc rebuildWebp(data: openArray[byte]; exif: openArray[byte];
    dropMeta: bool): seq[byte] =
  ## Rebuild a WebP, optionally replacing the EXIF chunk or dropping EXIF/XMP.
  ## EXIF write requires an existing VP8X header; returns @[] otherwise.
  if not isWebp(data): return
  var hasVp8x = false
  for f, _, _ in chunks(data):
    if f == "VP8X": hasVp8x = true
  if exif.len > 0 and not hasVp8x: return # simple-format write unsupported
  var outChunks: seq[seq[byte]]
  for f, start, size in chunks(data):
    if f == "EXIF": continue # re-added below / dropped
    if f == "XMP " and dropMeta: continue
    if f == "VP8X":
      var flags = newSeq[byte](size)
      for k in 0 ..< size: flags[k] = data[start + k]
      if size >= 1:
        if dropMeta: flags[0] = flags[0] and not (ExifFlag or XmpFlag)
        if exif.len > 0: flags[0] = flags[0] or ExifFlag
        else: flags[0] = flags[0] and not ExifFlag
      outChunks.add webpChunk("VP8X", flags)
      continue
    outChunks.add webpChunk(f, data[start ..< start + size])
  if exif.len > 0:
    outChunks.add webpChunk("EXIF", exif) # spec: EXIF after image data
  assembleWebp(outChunks)

proc replaceWebpExif*(data: openArray[byte]; tiff: openArray[byte]): seq[byte] =
  ## New WebP bytes with the EXIF chunk set to `tiff`. Returns `@[]` if this is
  ## not WebP or has no VP8X chunk.
  rebuildWebp(data, tiff, dropMeta = false)

proc stripWebp*(data: openArray[byte]): seq[byte] =
  ## New WebP bytes without EXIF/XMP chunks. Returns `@[]` if this is not WebP.
  rebuildWebp(data, @[], dropMeta = true)

proc findXmpInWebp*(data: openArray[byte]): string =
  ## XMP packet from the WebP "XMP " chunk, or "".
  if not isWebp(data): return ""
  for f, start, size in chunks(data):
    if f == "XMP ":
      var s = newString(size)
      for k in 0 ..< size: s[k] = char(data[start + k])
      return s
  ""
