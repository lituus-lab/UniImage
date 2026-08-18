# SPDX-License-Identifier: Apache-2.0

import ./endian
import std/[strutils, tables]

const MaxBoxDepth = 32
  ## Hard cap on ISOBMFF box nesting. Hostile files can chain thousands of
  ## `moov`/`meta` boxes; without a bound the recursive walk overflows the stack
  ## (a SIGSEGV that `try/except CatchableError` does NOT catch). 32 is far
  ## beyond any real file (a few levels: ftyp/moov/trak/mdia/minf/...).

type
  Box* = object
    offset*: int
    size*: int64
    kind*: string

  VideoMeta* = object
    creationTime*: string
    width*: int
    height*: int
    make*: string
    model*: string
    software*: string

proc readBoxHeader*(data: openArray[byte], offset: int): Box =
  if offset < 0 or offset > data.len - 8: return
  let size32 = readUint32(data, offset, BigEndian)
  result.offset = offset
  result.size = int64(size32)
  result.kind = ""
  for i in 0..3: result.kind.add char(data[offset + 4 + i])

  if size32 == 1:
    if offset + 16 <= data.len:
      let hi = readUint32(data, offset + 8, BigEndian)
      let lo = readUint32(data, offset + 12, BigEndian)
      result.size = (int64(hi) shl 32) or int64(lo)

iterator boxes*(data: openArray[byte]; start, limit: int): tuple[kind: string;
    body, bodyEnd: int] =
  ## Each box between `start` and `limit`, as its kind and the span of its
  ## payload.
  ##
  ## A size of 0 means "to the end of the enclosing box"; 1 means a 64-bit size
  ## follows the kind, which moves the payload eight bytes further along. A box
  ## claiming to be smaller than its own header, or to run past its parent, ends
  ## the walk rather than raising: trailing garbage after a valid box should not
  ## cost a caller what it already parsed.
  ##
  ## The bound is the caller's, not the buffer's, so a nested walk cannot escape
  ## its parent — which is what makes recursion over this safe.
  var offset = start
  while offset >= 0 and offset + 8 <= limit and offset + 8 <= data.len:
    let box = readBoxHeader(data, offset)
    var size = box.size
    var header = if readUint32(data, offset, BigEndian) == 1: 16 else: 8
    if size == 0: size = int64(limit - offset)
    if size < int64(header) or offset + int(size) > limit: break
    yield (box.kind, offset + header, offset + int(size))
    offset += int(size)

proc findBox*(data: openArray[byte]; start, limit: int;
              path: openArray[string]; depth = 0): tuple[body, bodyEnd: int] =
  ## Walk a path of box kinds, e.g. `["moov", "trak", "mdia"]`, and return the
  ## span of the last one's payload. `(-1, -1)` when any step is missing, so a
  ## caller tests one value rather than catching an exception for a box that is
  ## legitimately optional.
  ##
  ## `MaxBoxDepth` bounds the recursion: a file whose sizes describe a cycle
  ## stops here rather than running the stack out.
  if depth > MaxBoxDepth or path.len == 0: return (-1, -1)
  for kind, body, bodyEnd in boxes(data, start, limit):
    if kind != path[0]: continue
    if path.len == 1: return (body, bodyEnd)
    let inner = findBox(data, body, bodyEnd, path[1 .. ^1], depth + 1)
    if inner.body >= 0: return inner
  (-1, -1)

proc boxSizeAt(data: openArray[byte]; i, endAt: int): int =
  ## Box size at `i` via the shared `readBoxHeader` parser, with the to-end
  ## sentinel (size32 == 0) clamped to `endAt`. -1 when the header is
  ## truncated/malformed, so the caller's `size < 8` guard rejects it. Resolves
  ## the 64-bit extended size (size32 == 1) through `readBoxHeader`.
  if i < 0 or i > data.len - 8: return -1
  let box = readBoxHeader(data, i)
  if box.size == 0: return endAt - i
  if box.size < 8: return -1
  int(box.size)

proc findExifInHEIC*(data: openArray[byte]): int =
  const TiffSearchWindow = 64
  for i in 0 ..< data.len - 10:
    if data[i] == 0x45 and data[i+1] == 0x78 and
       data[i+2] == 0x69 and data[i+3] == 0x66:
      var j = i + 4
      let endAt = min(data.len - 4, i + 4 + TiffSearchWindow)
      while j < endAt:
        if (data[j] == 0x49 and data[j+1] == 0x49 and data[j+2] == 0x2A) or
           (data[j] == 0x4D and data[j+1] == 0x4D and data[j+2] == 0x00):
          return j
        j += 1
  return -1

proc parseIsobmff*(data: openArray[byte]): VideoMeta =
  var res: VideoMeta
  var keysList: seq[string]

  proc readStringData(boxData: openArray[byte]): string =
    # Expects an 'ilst' sub-box, which usually contains a 'data' box
    var i = 0
    while i + 8 <= boxData.len:
      let sub = readBoxHeader(boxData, i)
      if sub.size < 8: break
      if sub.kind == "data":
        if i + 16 <= boxData.len:
          let flags = readUint32(boxData, i + 8, BigEndian) and 0xFFFFFF
          if flags == 1: # UTF-8 text
            let strLen = int(sub.size) - 16
            if strLen > 0 and i + 16 + strLen <= boxData.len:
              for j in 0 ..< strLen:
                result.add char(boxData[i + 16 + j])
              return
      i += int(sub.size)

  proc recurse(boxData: openArray[byte], depth: int = 0) =
    if depth > MaxBoxDepth: return # bound nesting (hostile-input DoS)
    var i = 0
    while i + 8 <= boxData.len:
      let box = readBoxHeader(boxData, i)
      if box.size < 8: break # malformed / non-advancing box

      let payloadOffset = if readUint32(boxData, i, BigEndian) == 1: 16 else: 8
      let payloadLen = int(box.size) - payloadOffset
      if payloadLen < 0: break
      if i + payloadOffset + payloadLen > boxData.len: break

      let pStart = i + payloadOffset
      let pEnd = i + payloadOffset + payloadLen - 1

      case box.kind
      of "mvhd":
        if payloadLen >= 20:
          let version = boxData[pStart]
          if version == 0:
            let time = readUint32(boxData, pStart + 4, BigEndian)
            if res.creationTime == "": res.creationTime = "MP4-Time-V0:" & $time
          else:
            let hi = readUint32(boxData, pStart + 4, BigEndian)
            let lo = readUint32(boxData, pStart + 8, BigEndian)
            if res.creationTime == "": res.creationTime = "MP4-Time-V1:" & $((
                int64(hi) shl 32) or int64(lo))
      of "tkhd":
        # Parse Track Header for width/height
        if payloadLen >= 84:
          let version = boxData[pStart]
          let wOff = if version == 0: 76 else: 84
          let hOff = if version == 0: 80 else: 88
          if wOff + 4 <= payloadLen and hOff + 4 <= payloadLen:
            let w = int(readUint32(boxData, pStart + wOff, BigEndian) shr 16)
            let h = int(readUint32(boxData, pStart + hOff, BigEndian) shr 16)
            if w > res.width: res.width = w
            if h > res.height: res.height = h
      of "keys":
        # Parse 'keys' box for mdta handler (Apple)
        if payloadLen >= 8:
          let entryCount = int(readUint32(boxData, pStart + 4, BigEndian))
          var kIdx = 8
          for _ in 0 ..< entryCount:
            if kIdx + 8 > payloadLen: break
            let kSize = int(readUint32(boxData, pStart + kIdx, BigEndian))
            if kSize < 8: break
            var namespaceStr = ""
            for x in 0..3: namespaceStr.add char(boxData[pStart + kIdx + 4 + x])
            let kValLen = kSize - 8
            if kIdx + 8 + kValLen <= payloadLen:
              var kVal = ""
              for x in 0 ..< kValLen: kVal.add char(boxData[pStart + kIdx + 8 + x])
              keysList.add(kVal)
            kIdx += kSize
      of "ilst":
        # Parse item list (either ©mak/©mod directly or 1-based index from keysList)
        var j = 0
        while j + 8 <= payloadLen:
          let itemBox = readBoxHeader(boxData, pStart + j)
          if itemBox.size < 8: break

          let itemPayloadOffset = if readUint32(boxData, pStart + j,
              BigEndian) == 1: 16 else: 8
          let itemPayloadLen = int(itemBox.size) - itemPayloadOffset
          if itemPayloadLen > 0 and j + itemPayloadOffset + itemPayloadLen <= payloadLen:
            let itemPayloadStart = pStart + j + itemPayloadOffset
            let itemPayloadEnd = pStart + j + itemPayloadOffset +
                itemPayloadLen - 1
            let valStr = readStringData(boxData.toOpenArray(itemPayloadStart,
                itemPayloadEnd))

            if itemBox.kind == "\xA9mak": res.make = valStr
            elif itemBox.kind == "\xA9mod": res.model = valStr
            elif itemBox.kind == "\xA9swr": res.software = valStr
            elif itemBox.kind == "\xA9day" and res.creationTime ==
                "": res.creationTime = "String:" & valStr
            else:
              # Check if kind is an integer (1-based index into keysList)
              var isNum = true
              for ch in itemBox.kind:
                if ch < '0' or ch > '9': isNum = false; break

              if isNum and keysList.len > 0:
                try:
                  let idx = parseInt(itemBox.kind)
                  if idx >= 1 and idx <= keysList.len:
                    let keyName = keysList[idx - 1]
                    if keyName == "com.apple.quicktime.make": res.make = valStr
                    elif keyName == "com.apple.quicktime.model": res.model = valStr
                    elif keyName == "com.apple.quicktime.software": res.software = valStr
                    elif keyName == "com.apple.quicktime.creationdate" and
                        res.creationTime == "": res.creationTime = "String:" & valStr
                except CatchableError: discard

          j += int(itemBox.size)
      of "moov", "trak", "mdia", "udta", "meta":
        # Recurse
        if box.kind == "meta":
          # meta box has 4 bytes of version/flags before the actual content
          if payloadLen >= 4:
            recurse(boxData.toOpenArray(pStart + 4, pEnd), depth + 1)
        else:
          recurse(boxData.toOpenArray(pStart, pEnd), depth + 1)

      i += int(box.size)

  recurse(data)

  # Heuristic fallback for Make/Model/Software if box parsing misses them
  if res.make == "" or res.model == "" or res.software == "":
    let searchLen = min(data.len - 30, 1024 * 1024)
    for i in 0 ..< searchLen:
      # Apple iTunes Metadata (often preceded by 'data' box marker)
      if data[i] == 0x64 and data[i+1] == 0x61 and data[i+2] == 0x74 and data[
          i+3] == 0x61:
        if i + 16 < searchLen:
          let flags = readUint32(data, i + 4, BigEndian) and 0xFFFFFF
          if flags == 1: # UTF-8
            # Look backwards 8-12 bytes for a known key
            let keyOffset = max(0, i - 8)
            var keyStr = ""
            for k in 0..3: keyStr.add char(data[keyOffset + k])

            let valLen = int(readUint32(data, i - 4, BigEndian)) - 16
            if valLen > 0 and valLen < 128 and i + 12 + valLen < data.len:
              var val = ""
              for k in 0 ..< valLen: val.add char(data[i + 12 + k])

              if keyStr == "\xA9mak" and res.make == "": res.make = val
              elif keyStr == "\xA9mod" and res.model == "": res.model = val
              elif keyStr == "\xA9swr" and res.software ==
                  "": res.software = val
              elif keyStr == "\xA9day" and res.creationTime ==
                  "": res.creationTime = "String:" & val

              # If keyStr is a number (Apple 'keys' index), we might just guess it based on content
              elif val == "Apple" and res.make == "": res.make = val
              elif val.startsWith("iPhone") and res.model == "": res.model = val

  return res

proc findCreationTime*(data: openArray[byte]): string =
  ## Return only the creation timestamp from ISOBMFF metadata.
  let res = parseIsobmff(data)
  return res.creationTime

# --- strip (HEIC/AVIF) -----------------------------------------------------

proc isIsobmff*(data: openArray[byte]): bool =
  data.len >= 12 and data[4] == byte('f') and data[5] == byte('t') and
    data[6] == byte('y') and data[7] == byte('p')

proc box4(data: openArray[byte]; i: int): string =
  if i < 0 or i + 8 > data.len: return ""
  result = newString(4)
  for k in 0 .. 3: result[k] = char(data[i + 4 + k])

proc byteAt(data: openArray[byte]; p: int): int {.inline.} =
  ## Single byte at `p`, or 0 if out of range (bounds-safe FullBox version reads).
  if p < 0 or p >= data.len: 0 else: int(data[p])

proc beInt(data: openArray[byte]; p, size: int): int =
  ## Big-endian unsigned integer of `size` bytes at `p`.
  ## Returns 0 for size 0, and -1 if out of range or size is implausible (>8),
  ## which also rules out the shift overflow a hostile `offSz`/`lenSz` could cause.
  if size == 0: return 0
  if size < 0 or size > 8 or p < 0 or p + size > data.len: return -1
  result = 0
  for k in 0 ..< size: result = (result shl 8) or int(data[p + k])

const
  EmptyTiff = [0x4D'u8, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, # MM, IFD0 @8
    0x00, 0x00,             # 0 entries
    0x00, 0x00, 0x00, 0x00] # next IFD = 0
  EmptyXmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>" &
             "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF " &
             "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"></rdf:RDF>" &
             "</x:xmpmeta><?xpacket end=\"w\"?>"

type
  ExifItemLoc* = object
    found*: bool
    off*, length*: int
    offPos*, lenPos*: int
    offSz*, lenSz*, base*: int
    ec*, cmeth*: int

  ItemRecord = object
    kind, contentType: string
    loc: ExifItemLoc

proc readCString(data: openArray[byte]; pos, endAt: int;
    next: var int): string =
  next = pos
  while next < endAt and data[next] != 0:
    result.add char(data[next])
    inc next
  if next < endAt: inc next

proc parseItemRecords(data: openArray[byte]): Table[int, ItemRecord] =
  ## Parse `iinf` and `iloc` once for metadata read, strip, and replacement.
  if not isIsobmff(data): return
  var metaOff = -1
  var metaEnd = 0
  var i = 0
  while i + 8 <= data.len:
    let size = boxSizeAt(data, i, data.len)
    if size < 8 or i + size > data.len: break
    if box4(data, i) == "meta": metaOff = i; metaEnd = i + size; break
    i += size
  if metaOff < 0: return

  i = metaOff + 12
  while i + 8 <= metaEnd:
    let sz = boxSizeAt(data, i, metaEnd)
    if sz < 8 or i + sz > metaEnd: break
    let typ = box4(data, i)
    if typ == "iinf":
      let ver = byteAt(data, i + 8)
      var p = i + 12 + (if ver == 0: 2 else: 4)
      while p + 8 <= i + sz:
        let entrySize = boxSizeAt(data, p, i + sz)
        if entrySize < 8 or p + entrySize > i + sz: break
        if box4(data, p) == "infe":
          let infeEnd = p + entrySize
          let infeVer = byteAt(data, p + 8)
          var q = p + 12
          let idSize = if infeVer >= 3: 4 else: 2
          let iid = beInt(data, q, idSize)
          q += idSize
          if iid >= 0 and q + 6 <= infeEnd:
            q += 2 # item_protection_index
            let kind = box4(data, q - 4)
            q += 4
            var next: int
            discard readCString(data, q, infeEnd, next) # item_name
            var contentType = ""
            if kind == "mime" and next < infeEnd:
              contentType = readCString(data, next, infeEnd, q)
            result.mgetOrPut(iid, ItemRecord()).kind = kind
            result.mgetOrPut(iid, ItemRecord()).contentType = contentType
        p += entrySize
    elif typ == "iloc":
      let ver = byteAt(data, i + 8)
      var p = i + 12
      if p + 2 > i + sz: break
      let b0 = byteAt(data, p); let offSz = b0 shr 4; let lenSz = b0 and 0xF; inc p
      let b1 = byteAt(data, p); let baseSz = b1 shr 4; let idxSz = b1 and 0xF; inc p
      let countSize = if ver == 2: 4 else: 2
      let cnt = beInt(data, p, countSize)
      if cnt < 0: break
      p += countSize
      block items:
        for _ in 0 ..< cnt:
          let idSize = if ver == 2: 4 else: 2
          let iid = beInt(data, p, idSize)
          if iid < 0: break items
          p += idSize
          var cmeth = 0
          if ver in {1, 2}:
            let methodValue = beInt(data, p, 2)
            if methodValue < 0: break items
            cmeth = methodValue and 0xF
            p += 2
          if p + 2 > i + sz: break items
          p += 2 # data_reference_index
          let base = beInt(data, p, baseSz)
          if base < 0 or p + baseSz > i + sz: break items
          p += baseSz
          let ec = beInt(data, p, 2)
          if ec < 0: break items
          p += 2
          for extent in 0 ..< ec:
            if ver in {1, 2} and idxSz > 0:
              if beInt(data, p, idxSz) < 0: break items
              p += idxSz
            let offPos = p
            let eo = beInt(data, p, offSz)
            if eo < 0 or p + offSz > i + sz: break items
            p += offSz
            let lenPos = p
            let el = beInt(data, p, lenSz)
            if el < 0 or p + lenSz > i + sz: break items
            p += lenSz
            if extent == 0:
              result.mgetOrPut(iid, ItemRecord()).loc = ExifItemLoc(
                found: true, off: base + eo, length: el, offPos: offPos,
                lenPos: lenPos, offSz: offSz, lenSz: lenSz, base: base,
                ec: ec, cmeth: cmeth)
    i += sz

proc stripIsobmff*(data: openArray[byte]): seq[byte] =
  ## Neutralize EXIF and XMP (mime) item payloads of a HEIC/AVIF *in place*:
  ## the items stay but hold an empty TIFF / empty XMP, so no offsets shift and
  ## the image is untouched. Returns `@[]` if this is not ISOBMFF or has no
  ## `meta` box (caller fails).
  if not isIsobmff(data): return

  let records = parseItemRecords(data)
  if records.len == 0: return
  result = @data
  for _, record in records:
    if record.kind != "Exif" and not (record.kind == "mime" and
        record.contentType == "application/rdf+xml"): continue
    let off = record.loc.off
    let length = record.loc.length
    if not record.loc.found or record.loc.cmeth != 0 or record.loc.ec != 1: continue
    if length <= 4 or off < 0 or off + length > result.len: continue
    if record.kind == "Exif":
      for k in 0 ..< length: result[off + k] = 0 # tiff_offset=0 + zero pad
      var pos = off + 4
      for b in EmptyTiff:
        if pos < off + length: result[pos] = b; inc pos
    else: # mime == XMP
      if length >= EmptyXmp.len:
        for k in 0 ..< length:
          result[off + k] = if k < EmptyXmp.len: byte(EmptyXmp[k]) else: byte(' ')
      else:
        for k in 0 ..< length: result[off + k] = 0 # too small for a packet

# --- write EXIF (HEIC/AVIF) ------------------------------------------------

proc locateExifItem*(data: openArray[byte]): ExifItemLoc =
  ## Find the `Exif` item and the iloc field positions of its first extent.
  for _, record in parseItemRecords(data):
    if record.kind == "Exif": return record.loc

proc findExifTiffInIsobmff*(data: openArray[byte]): int =
  ## Offset of the EXIF TIFF block (II/MM) located through the `meta`/`iinf`/`iloc`
  ## item structure — the spec-correct counterpart to the byte-scan
  ## `findExifInHEIC`, and the same path the writer uses (`locateExifItem`), so
  ## read and write agree. Returns -1 when there is no single-extent, file-offset
  ## Exif item or the computed TIFF start is out of range / not a TIFF header.
  let loc = locateExifItem(data)
  if not loc.found or loc.cmeth != 0 or loc.ec != 1 or loc.length <= 4: return -1
  if loc.off < 0 or loc.off + loc.length > data.len: return -1
  let tho = beInt(data, loc.off, 4) # ExifDataBlock: exif_tiff_header_offset
  if tho < 0: return -1
  let tiffStart = loc.off + 4 + tho
  if tiffStart < 0 or tiffStart + 4 > loc.off + loc.length: return -1
  if tiffStart + 4 > data.len: return -1
  let isII = data[tiffStart] == 0x49 and data[tiffStart + 1] == 0x49 and
             data[tiffStart + 2] == 0x2A and data[tiffStart + 3] == 0x00
  let isMM = data[tiffStart] == 0x4D and data[tiffStart + 1] == 0x4D and
             data[tiffStart + 2] == 0x00 and data[tiffStart + 3] == 0x2A
  if not isII and not isMM: return -1
  tiffStart

proc putBE(s: var seq[byte]; pos, size, value: int) =
  for k in 0 ..< size:
    s[pos + k] = byte((value shr ((size - 1 - k) * 8)) and 0xFF)

proc fitsIn(value, size: int): bool =
  value >= 0 and (size >= 8 or value < (1 shl (size * 8)))

proc writeExifIsobmff*(data: openArray[byte]; tiff: openArray[byte]): seq[byte] =
  ## Replace the `Exif` item payload of a HEIC/AVIF with `tiff` (a TIFF block).
  ## In place when it fits; otherwise appends an `mdat` box and repoints the iloc
  ## extent — no other offsets shift. Returns `@[]` if there is no single-extent, file-offset
  ## Exif item (caller should fall back / report unsupported).
  let loc = locateExifItem(data)
  if not loc.found or loc.cmeth != 0 or loc.ec != 1: return
  if loc.off < 0 or loc.length < 0 or loc.off + loc.length > data.len: return
  var payload = @[byte 0, 0, 0, 0] # exif_tiff_header_offset = 0
  for b in tiff: payload.add b

  result = @data
  if payload.len <= loc.length and fitsIn(payload.len, loc.lenSz):
    for k in 0 ..< payload.len: result[loc.off + k] = payload[k]
    for k in payload.len ..< loc.length: result[loc.off + k] = 0
    putBE(result, loc.lenPos, loc.lenSz, payload.len)
  else:
    let newOff = result.len + 8 # data sits after the box header
    if not fitsIn(newOff - loc.base, loc.offSz) or not fitsIn(payload.len, loc.lenSz):
      return
    let boxSize = 8 + payload.len # mdat: size(4) + 'mdat'(4) + data
    if boxSize > 0xFFFFFFFF: return # 32-bit size header can't represent it
    result.add byte((boxSize shr 24) and 0xFF); result.add byte((
        boxSize shr 16) and 0xFF)
    result.add byte((boxSize shr 8) and 0xFF); result.add byte(boxSize and 0xFF)
    for c in "mdat": result.add byte(c)
    for b in payload: result.add b
    putBE(result, loc.offPos, loc.offSz, newOff - loc.base)
    putBE(result, loc.lenPos, loc.lenSz, payload.len)
