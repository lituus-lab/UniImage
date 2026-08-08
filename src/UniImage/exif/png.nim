# SPDX-License-Identifier: Apache-2.0

## PNG metadata: locate the eXIf chunk (a raw TIFF block) and read tEXt chunks.

import ./endian
import ./zlibutil

const PngSig = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

proc isPng*(data: openArray[byte]): bool =
  if data.len < 8: return false
  for k in 0 .. 7:
    if data[k] != PngSig[k]: return false
  true

proc chunkType(data: openArray[byte]; at: int): string =
  for k in 0 .. 3: result.add char(data[at + k])

proc findExifInPng*(data: openArray[byte]): int =
  ## Offset of the TIFF block inside the eXIf chunk (starts with II/MM), or 0.
  if not isPng(data): return 0
  var i = 8
  while i + 8 <= data.len:
    let length = int(readUint32(data, i, BigEndian))
    let typ = chunkType(data, i + 4)
    let dataStart = i + 8
    if typ == "eXIf" and dataStart < data.len: return dataStart
    if typ == "IDAT" or typ == "IEND": break # metadata precedes the image data
    i = dataStart + length + 4 # data + 4-byte CRC
  0

proc parseITxt(data: openArray[byte]; dataStart, length: int): (string, string, bool) =
  ## (keyword, text, ok). ok=false when compressed (flag=1) or malformed.
  ## iTXt layout: keyword \0 compFlag compMethod lang \0 transKw \0 text(UTF-8).
  let stop = dataStart + length
  var p = dataStart
  var kw = ""
  while p < stop and data[p] != 0: kw.add char(data[p]); inc p
  if p + 2 > stop: return ("", "", false)
  inc p # NUL after keyword
  let compFlag = data[p]; inc p # compression flag
  inc p # compression method
  while p < stop and data[p] != 0: inc p # language tag
  if p >= stop: return ("", "", false)
  inc p
  while p < stop and data[p] != 0: inc p # translated keyword
  if p >= stop: return ("", "", false)
  inc p
  if compFlag != 0:
    # Compressed UTF-8 text (zlib stream from p to stop).
    var comp = newSeq[byte](stop - p)
    for k in 0 ..< comp.len: comp[k] = data[p + k]
    let raw = zlibInflate(comp)
    if raw.len == 0: return (kw, "", false)
    var txt = ""
    for b in raw: txt.add char(b)
    return (kw, txt, true)
  var txt = ""
  while p < stop: txt.add char(data[p]); inc p
  (kw, txt, true)

proc parseZtxt(data: openArray[byte]; dataStart, length: int): (string, string, bool) =
  ## zTXt layout: keyword \0 compMethod(1) compressedText(zlib). (kw, text, ok).
  let stop = dataStart + length
  var p = dataStart
  var kw = ""
  while p < stop and data[p] != 0: kw.add char(data[p]); inc p
  if p + 2 > stop: return ("", "", false)
  inc p # NUL after keyword
  inc p # compression method
  var comp = newSeq[byte](stop - p)
  for k in 0 ..< comp.len: comp[k] = data[p + k]
  let raw = zlibInflate(comp)
  if raw.len == 0: return (kw, "", false)
  var txt = ""
  for b in raw: txt.add char(b)
  (kw, txt, true)

proc pngTextChunks*(data: openArray[byte]): seq[(string, string)] =
  ## tEXt, iTXt (incl. compressed) and zTXt chunks as (keyword, text) pairs.
  if not isPng(data): return
  var i = 8
  while i + 8 <= data.len:
    let length = int(readUint32(data, i, BigEndian))
    let typ = chunkType(data, i + 4)
    let dataStart = i + 8
    if typ == "IEND": break
    if dataStart + length > data.len: break
    if typ == "tEXt":
      var sep = -1
      for k in 0 ..< length:
        if data[dataStart + k] == 0: sep = k; break
      if sep >= 0:
        var kw, txt: string
        for k in 0 ..< sep: kw.add char(data[dataStart + k])
        for k in sep + 1 ..< length: txt.add char(data[dataStart + k])
        result.add (kw, txt)
    elif typ == "iTXt":
      let (kw, txt, ok) = parseITxt(data, dataStart, length)
      if ok and kw.len > 0: result.add (kw, txt)
    elif typ == "zTXt":
      let (kw, txt, ok) = parseZtxt(data, dataStart, length)
      if ok and kw.len > 0: result.add (kw, txt)
    i = dataStart + length + 4

proc findXmpInPng*(data: openArray[byte]): string =
  ## XMP packet from the iTXt chunk keyed "XML:com.adobe.xmp" (uncompressed), or "".
  if not isPng(data): return ""
  var i = 8
  while i + 8 <= data.len:
    let length = int(readUint32(data, i, BigEndian))
    let typ = chunkType(data, i + 4)
    let dataStart = i + 8
    if typ == "IEND": break
    if dataStart + length > data.len: break
    if typ == "iTXt":
      let (kw, txt, ok) = parseITxt(data, dataStart, length)
      if ok and kw == "XML:com.adobe.xmp": return txt
    i = dataStart + length + 4
  ""

# --- write -----------------------------------------------------------------

proc crc32(data: openArray[byte]): uint32 =
  ## PNG/zlib CRC-32 (poly 0xEDB88320), table-less; used only for new chunks.
  var c = 0xFFFFFFFF'u32
  for b in data:
    c = c xor uint32(b)
    for _ in 0 ..< 8:
      if (c and 1) != 0: c = (c shr 1) xor 0xEDB88320'u32
      else: c = c shr 1
  c xor 0xFFFFFFFF'u32

proc be32(v: uint32): seq[byte] =
  @[byte((v shr 24) and 0xFF), byte((v shr 16) and 0xFF),
    byte((v shr 8) and 0xFF), byte(v and 0xFF)]

proc makeChunk(typ: string; payload: openArray[byte]): seq[byte] =
  result.add be32(uint32(payload.len))
  var crcIn = newSeq[byte](4 + payload.len)
  for k in 0 .. 3: crcIn[k] = byte(typ[k])
  for k in 0 ..< payload.len: crcIn[4 + k] = payload[k]
  for k in 0 .. 3: result.add byte(typ[k])
  for b in payload: result.add b
  result.add be32(crc32(crcIn))

const PngMetaChunks = ["eXIf", "tEXt", "iTXt", "zTXt"]

proc rebuildPng(data: openArray[byte]; exif: openArray[byte];
    dropMeta: bool): seq[byte] =
  ## Copy PNG chunks, inserting/replacing the eXIf chunk (when `exif` is given)
  ## right after IHDR, and/or dropping textual+exif metadata when `dropMeta`.
  ## Returns @[] if not a PNG.
  if not isPng(data): return
  for k in 0 .. 7: result.add data[k] # signature
  var i = 8
  var wroteExif = false
  while i + 8 <= data.len:
    let length = int(readUint32(data, i, BigEndian))
    let typ = chunkType(data, i + 4)
    let chunkEnd = i + 12 + length # len(4)+type(4)+data+crc(4)
    if chunkEnd > data.len: break
    let drop = (typ == "eXIf" and exif.len > 0) or (dropMeta and typ in PngMetaChunks)
    if not drop:
      for k in i ..< chunkEnd: result.add data[k]
    i = chunkEnd
    if typ == "IHDR" and exif.len > 0 and not wroteExif:
      result.add makeChunk("eXIf", exif)
      wroteExif = true
  if i < data.len:
    let residueIsMeta = dropMeta and i + 8 <= data.len and
      chunkType(data, i + 4) in PngMetaChunks
    if not residueIsMeta:
      for k in i ..< data.len: result.add data[k]

proc replacePngExif*(data: openArray[byte]; tiff: openArray[byte]): seq[byte] =
  ## New PNG bytes with an eXIf chunk carrying `tiff` (a TIFF block). Returns
  ## `@[]` if this is not a PNG.
  rebuildPng(data, tiff, dropMeta = false)

proc stripPng*(data: openArray[byte]): seq[byte] =
  ## New PNG bytes without eXIf/tEXt/iTXt/zTXt metadata. Returns `@[]` if this
  ## is not a PNG.
  rebuildPng(data, @[], dropMeta = true)
