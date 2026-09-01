# SPDX-License-Identifier: Apache-2.0

## Editable EXIF model: parse to a mutable tree, mutate, serialize back.
##
## EXIF lives in a self-contained TIFF block (IFD0 + Exif/GPS sub-IFDs). For JPEG
## that block sits in the APP1 segment and does not reference the image data, so
## it can be rebuilt and re-embedded losslessly. Standalone TIFF metadata is
## written directly; image-bearing TIFF/RAW (StripOffsets) is not rewritten.

import contracts
import std/[os, options, tables, algorithm, strutils, math]
when defined(windows):
  import std/winlean
else:
  import std/posix
import ./endian, ./tiff, ./jpeg, ./png, ./webp, ./isobmff

type
  ExifValue* = object
    typ*: TagType
    count*: uint32             ## original element count (for unmodeled types)
    text*: string              ## ASCII
    nums*: seq[int64]          ## BYTE/SHORT/LONG/SSHORT/SLONG
    rats*: seq[(int64, int64)] ## RATIONAL/SRATIONAL (num, den)
    bytes*: seq[byte]          ## UNDEFINED/FLOAT/DOUBLE and other raw types

  ExifIfd* = OrderedTable[uint16, ExifValue]

  ExifData* = object
    ifd0*: ExifIfd
    exif*: ExifIfd ## Exif sub-IFD (pointer 0x8769)
    gps*: ExifIfd  ## GPS sub-IFD (pointer 0x8825)
    endian*: TiffEndianness

# --- constructors ----------------------------------------------------------

proc asciiVal*(s: string): ExifValue =
  ## An ASCII tag value. TIFF stores these NUL-terminated; the terminator is
  ## added on serialisation, so `s` is the text without it.
  ExifValue(typ: ttAscii, text: s)
proc shortVal*(v: varargs[int]): ExifValue =
  ## One or more SHORT values (16-bit). `varargs` because a tag may be a
  ## single number or a small vector, and the type is the same either way.
  result.typ = ttShort
  for x in v: result.nums.add int64(x)
proc longVal*(v: varargs[int]): ExifValue =
  ## One or more LONG values (32-bit), as `shortVal` but wider.
  result.typ = ttLong
  for x in v: result.nums.add int64(x)
proc byteVal*(b: openArray[byte]): ExifValue =
  ## A BYTE tag value. Copied, not borrowed: the value outlives the buffer a
  ## caller parsed it from.
  ExifValue(typ: ttByte, bytes: @b)
proc rationalSeq*(pairs: seq[(int, int)]): ExifValue =
  ## RATIONAL values, each a numerator and a denominator. EXIF stores
  ## exposure times and GPS coordinates this way rather than as floats, so a
  ## `1/250` stays exactly that and does not acquire a rounding error on the
  ## way through.
  result.typ = ttRational
  for (n, d) in pairs: result.rats.add (int64(n), int64(d))

# --- decode a parsed Tag into a typed value --------------------------------

proc decodeTag(tag: Tag): ExifValue =
  result.typ = tag.tagType
  result.count = tag.count
  case tag.tagType
  of ttAscii:
    for b in tag.rawBytes:
      if b == 0: break
      result.text.add char(b)
  of ttByte, ttSByte, ttUndefined:
    result.bytes = tag.rawBytes
  of ttShort:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 2):
      result.nums.add int64(readUint16(tag.rawBytes, i * 2, tag.endian))
  of ttSShort:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 2):
      result.nums.add int64(cast[int16](readUint16(tag.rawBytes, i * 2, tag.endian)))
  of ttLong:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 4):
      result.nums.add int64(readUint32(tag.rawBytes, i * 4, tag.endian))
  of ttSLong:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 4):
      result.nums.add int64(cast[int32](readUint32(tag.rawBytes, i * 4, tag.endian)))
  of ttRational:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 8):
      result.rats.add (int64(readUint32(tag.rawBytes, i * 8, tag.endian)),
                       int64(readUint32(tag.rawBytes, i * 8 + 4, tag.endian)))
  of ttSRational:
    for i in 0 ..< min(int(tag.count), tag.rawBytes.len div 8):
      result.rats.add (int64(cast[int32](readUint32(tag.rawBytes, i * 8, tag.endian))),
                       int64(cast[int32](readUint32(tag.rawBytes, i * 8 + 4, tag.endian))))
  else:
    result.bytes = tag.rawBytes

# --- parse a file into the editable tree -----------------------------------

proc readAllBytes(path: string): seq[byte] =
  try:
    let fs = getFileSize(path)
    if fs <= 0: return
    result = newSeq[byte](min(int(fs), 16 * 1024 * 1024))
    var f: File
    if not open(f, path): return
    defer: f.close()
    let n = f.readBuffer(addr result[0], result.len)
    result.setLen(n)
  except CatchableError:
    result = @[]

proc readWholeFile(path: string): seq[byte] =
  ## Full file, uncapped — required when rewriting a container (else write paths
  ## would truncate files larger than the metadata-read cap).
  try:
    let s = readFile(path)
    result = newSeq[byte](s.len)
    if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)
  except CatchableError:
    result = @[]

proc parseExifBytesImpl(data: openArray[byte]): ExifData =
  ## Parse an editable EXIF model from an in-memory image buffer (the caller owns
  ## the bytes). Same container coverage as `parseExif`; used by the C ABI and
  ## any caller already holding the file in memory.
  result.endian = LittleEndian
  if data.len < 4: return

  var tiffOff = -1
  if data[0] == 0xFF and data[1] == 0xD8:
    let blk = findExifAPP1(data)
    if blk.offset > 0: tiffOff = blk.offset
  elif (data[0] == 0x49 and data[1] == 0x49 and data[2] == 0x2A and data[3] == 0x00) or
       (data[0] == 0x4D and data[1] == 0x4D and data[2] == 0x00 and data[3] == 0x2A):
    tiffOff = 0
  elif isPng(data):
    let off = findExifInPng(data)
    if off > 0: tiffOff = off # absent eXIf -> empty model, set() still works
  elif isWebp(data):
    let off = findExifInWebp(data)
    if off > 0: tiffOff = off
  elif isIsobmff(data):
    var off = findExifTiffInIsobmff(data) # spec-correct iloc/iinf localization
    if off < 0: off = findExifInHEIC(data) # fallback: byte scan
    if off > 0: tiffOff = off # absent Exif item -> empty model
  if tiffOff < 0 or tiffOff >= data.len: return
  if tiffOff + 8 > data.len: return

  let endian = if char(data[tiffOff]) == 'I': LittleEndian else: BigEndian
  result.endian = endian
  let firstIfd = int(readUint32(data, tiffOff + 4, endian))
  if tiffOff + firstIfd + 2 > data.len: return

  let ifd0 = readIFD(data, tiffOff + firstIfd, tiffOff, endian)
  for id, tag in ifd0.tags:
    if id == 0x8769 or id == 0x8825: continue # structural pointers, regenerated
    result.ifd0[id] = decodeTag(tag)

  if ifd0.tags.hasKey(0x8769):
    let offOpt = readLongTag(ifd0.tags[0x8769])
    if offOpt.isSome and tiffOff + offOpt.get + 2 <= data.len:
      let off = offOpt.get
      for id, tag in readIFD(data, tiffOff + off, tiffOff, endian).tags:
        result.exif[id] = decodeTag(tag)
  if ifd0.tags.hasKey(0x8825):
    let offOpt = readLongTag(ifd0.tags[0x8825])
    if offOpt.isSome and tiffOff + offOpt.get + 2 <= data.len:
      let off = offOpt.get
      for id, tag in readIFD(data, tiffOff + off, tiffOff, endian).tags:
        result.gps[id] = decodeTag(tag)

proc parseExifBytes*(data: openArray[byte]): ExifData {.contractual.} =
  ## Parse an editable EXIF model from an in-memory image buffer.
  ensure:
    data.len >= 4 or (result.ifd0.len == 0 and result.exif.len == 0 and
      result.gps.len == 0)
  body:
    result = parseExifBytesImpl(data)

proc parseExif*(path: string): ExifData =
  ## File wrapper over `parseExifBytes`.
  parseExifBytes(readAllBytes(path))

# --- mutation API ----------------------------------------------------------

proc del*(e: var ExifData; id: uint16) =
  e.ifd0.del(id); e.exif.del(id); e.gps.del(id)

proc stripAll*(e: var ExifData) =
  e.ifd0.clear(); e.exif.clear(); e.gps.clear()

proc setArtist*(e: var ExifData; s: string) = e.ifd0[0x013B] = asciiVal(s)
proc setSoftware*(e: var ExifData; s: string) = e.ifd0[0x0131] = asciiVal(s)
proc setOrientation*(e: var ExifData; o: int) = e.ifd0[0x0112] = shortVal(o)
proc setDateTimeOriginal*(e: var ExifData; dt: string) =
  e.exif[0x9003] = asciiVal(dt) # DateTimeOriginal
  e.exif[0x9004] = asciiVal(dt) # DateTimeDigitized
  e.ifd0[0x0132] = asciiVal(dt) # DateTime

proc setGps*(e: var ExifData; lat, lon: float; alt = 0.0) =
  proc dms(v: float): seq[(int, int)] =
    ## Degrees, minutes, and seconds with the seconds kept as a 1/10000 rational
    ## (~0.003 m) and rounded, not truncated — matching what exiftool/exiv2 emit.
    const SecDen = 10000
    let a = abs(v)
    let d = int(a)
    let restMin = (a - float(d)) * 60.0
    let m = int(restMin)
    var s = int(round((restMin - float(m)) * 60.0 * float(SecDen)))
    if s >= 60 * SecDen: s = 60 * SecDen - 1 # guard rounding up to exactly 60"
    @[(d, 1), (m, 1), (s, SecDen)]
  e.gps[0x0001] = asciiVal(if lat >= 0: "N" else: "S")
  e.gps[0x0002] = rationalSeq(dms(lat))
  e.gps[0x0003] = asciiVal(if lon >= 0: "E" else: "W")
  e.gps[0x0004] = rationalSeq(dms(lon))
  e.gps[0x0005] = byteVal([byte(if alt < 0: 1 else: 0)])
  e.gps[0x0006] = rationalSeq(@[(int(round(abs(alt) * 100.0)), 100)])

# --- generic tag write (exiv2-style: any IFD, any tag, any type) ------------

type IfdGroup* = enum igIfd0, igExif, igGps

proc setTag*(e: var ExifData; group: IfdGroup; id: uint16; v: ExifValue) =
  ## Write any tag in any IFD to a typed value (the generic foundation under the
  ## convenience setters above). Overwrites an existing tag of the same id.
  case group
  of igIfd0: e.ifd0[id] = v
  of igExif: e.exif[id] = v
  of igGps: e.gps[id] = v

proc delTag*(e: var ExifData; group: IfdGroup; id: uint16) =
  case group
  of igIfd0: e.ifd0.del(id)
  of igExif: e.exif.del(id)
  of igGps: e.gps.del(id)

proc parseTyped*(typ: TagType; s: string): ExifValue =
  ## Parse a string into an ExifValue of `typ`: space/comma-separated for arrays,
  ## "num/den" (or a bare integer) for rationals. Raises ValueError if malformed.
  result.typ = typ
  case typ
  of ttAscii: result.text = s
  of ttByte, ttSByte, ttUndefined:
    var bs: seq[byte]; var numeric = s.len > 0
    for tok in s.split({' ', ','}):
      if tok.len == 0: continue
      try: bs.add byte(parseInt(tok) and 0xFF)
      except ValueError: numeric = false; break
    if numeric and bs.len > 0: result.bytes = bs
    else: (for c in s: result.bytes.add byte(c)) # raw ASCII fallback
  of ttShort, ttLong, ttSShort, ttSLong:
    for tok in s.split({' ', ','}):
      if tok.len > 0:
        let value = parseBiggestInt(tok)
        let valid = case typ
          of ttShort: value >= 0 and value <= int64(high(uint16))
          of ttLong: value >= 0 and value <= int64(high(uint32))
          of ttSShort: value >= int64(low(int16)) and value <= int64(high(int16))
          of ttSLong: value >= int64(low(int32)) and value <= int64(high(int32))
          else: false
        if not valid: raise newException(ValueError, "EXIF integer out of range")
        result.nums.add value
  of ttRational, ttSRational:
    for tok in s.split({' ', ','}):
      if tok.len == 0: continue
      let sl = tok.find('/')
      let num = parseBiggestInt(if sl > 0: tok[0 ..< sl] else: tok)
      let den = if sl > 0: parseBiggestInt(tok[sl + 1 .. ^1]) else: 1'i64
      let valid = if typ == ttRational:
          num >= 0 and num <= int64(high(uint32)) and den >= 0 and
            den <= int64(high(uint32))
        else:
          num >= int64(low(int32)) and num <= int64(high(int32)) and
            den >= int64(low(int32)) and den <= int64(high(int32))
      if not valid: raise newException(ValueError, "EXIF rational out of range")
      result.rats.add (num, den)
  else: result.text = s

const WritableTags = {
  # IFD0
  "ImageDescription": (igIfd0, 0x010E'u16, ttAscii),
  "Make": (igIfd0, 0x010F'u16, ttAscii),
  "Model": (igIfd0, 0x0110'u16, ttAscii),
  "Orientation": (igIfd0, 0x0112'u16, ttShort),
  "Software": (igIfd0, 0x0131'u16, ttAscii),
  "DateTime": (igIfd0, 0x0132'u16, ttAscii),
  "HostComputer": (igIfd0, 0x013C'u16, ttAscii),
  "Artist": (igIfd0, 0x013B'u16, ttAscii),
  "Copyright": (igIfd0, 0x8298'u16, ttAscii),
  "Rating": (igIfd0, 0x4746'u16, ttShort),
  # Exif sub-IFD
  "ExposureTime": (igExif, 0x829A'u16, ttRational),
  "FNumber": (igExif, 0x829D'u16, ttRational),
  "ISO": (igExif, 0x8827'u16, ttShort),
  "ExposureProgram": (igExif, 0x8822'u16, ttShort),
  "DateTimeOriginal": (igExif, 0x9003'u16, ttAscii),
  "CreateDate": (igExif, 0x9004'u16, ttAscii),
  "ExposureCompensation": (igExif, 0x9204'u16, ttSRational),
  "MeteringMode": (igExif, 0x9207'u16, ttShort),
  "Flash": (igExif, 0x9209'u16, ttShort),
  "FocalLength": (igExif, 0x920A'u16, ttRational),
  "UserComment": (igExif, 0x9286'u16, ttUndefined),
  "LensModel": (igExif, 0xA434'u16, ttAscii),
}.toTable

proc setTagByName*(e: var ExifData; name, value: string): bool =
  ## Write a tag by its EXIF name (see WritableTags), parsing `value` into the
  ## tag's natural type. Returns false for an unknown name or malformed value.
  ## UserComment gets the standard 8-byte "ASCII\0\0\0" character-code prefix.
  if not WritableTags.hasKey(name): return false
  let (g, id, typ) = WritableTags[name]
  try:
    if name == "UserComment":
      var b = @[byte 0x41, 0x53, 0x43, 0x49, 0x49, 0, 0, 0] # "ASCII\0\0\0"
      for c in value: b.add byte(c)
      e.setTag(g, id, ExifValue(typ: ttUndefined, bytes: b))
    else:
      e.setTag(g, id, parseTyped(typ, value))
    true
  except ValueError:
    false

proc writableTagNames*(): seq[string] =
  ## The set of tag names accepted by setTagByName (for CLI help / discovery).
  for k in WritableTags.keys: result.add k
  result.sort()

# --- serialize to a TIFF block (little-endian) -----------------------------

proc le16b(v: uint16): seq[byte] = @[byte(v and 0xFF), byte(v shr 8)]
proc le32b(v: uint32): seq[byte] =
  @[byte(v and 0xFF), byte((v shr 8) and 0xFF),
    byte((v shr 16) and 0xFF), byte((v shr 24) and 0xFF)]

proc encode(v: ExifValue; endian: TiffEndianness): tuple[
    typ: uint16; count: uint32; data: seq[byte]] =
  case v.typ
  of ttAscii:
    var b: seq[byte]
    for c in v.text: b.add byte(c)
    b.add 0
    (2'u16, uint32(b.len), b)
  of ttShort:
    var b: seq[byte]
    for n in v.nums: b.add le16b(uint16(n))
    (3'u16, uint32(v.nums.len), b)
  of ttLong:
    var b: seq[byte]
    for n in v.nums: b.add le32b(uint32(n))
    (4'u16, uint32(v.nums.len), b)
  of ttSShort:
    var b: seq[byte]
    for n in v.nums: b.add le16b(cast[uint16](int16(n)))
    (8'u16, uint32(v.nums.len), b)
  of ttSLong:
    var b: seq[byte]
    for n in v.nums: b.add le32b(cast[uint32](int32(n)))
    (9'u16, uint32(v.nums.len), b)
  of ttRational:
    var b: seq[byte]
    for (n, d) in v.rats: b.add le32b(uint32(n)); b.add le32b(uint32(d))
    (5'u16, uint32(v.rats.len), b)
  of ttSRational:
    var b: seq[byte]
    for (n, d) in v.rats: b.add le32b(cast[uint32](int32(n))); b.add le32b(cast[
        uint32](int32(d)))
    (10'u16, uint32(v.rats.len), b)
  else:
    var bytes = v.bytes
    if endian == BigEndian and v.typ in {ttFloat, ttDouble}:
      let width = if v.typ == ttFloat: 4 else: 8
      if bytes.len >= width:
        for pos in countup(0, bytes.len - width, width):
          for k in 0 ..< width div 2:
            swap(bytes[pos + k], bytes[pos + width - 1 - k])
    let count = if v.typ in {ttByte, ttSByte, ttUndefined} and
        v.count != uint32(bytes.len): uint32(bytes.len) else: v.count
    (uint16(ord(v.typ)), count, bytes)

proc serializeImpl(e: ExifData): seq[byte] =
  ## Emit a valid little-endian TIFF carrying IFD0 + Exif/GPS sub-IFDs.
  var ifd0 = e.ifd0
  ifd0.del(0x8769); ifd0.del(0x8825)
  let hasExif = e.exif.len > 0
  let hasGps = e.gps.len > 0

  proc ifdSize(n: int): int = 2 + n * 12 + 4
  let
    ifd0Off = 8
    ifd0Count = ifd0.len + (if hasExif: 1 else: 0) + (if hasGps: 1 else: 0)
    ifd0Size = ifdSize(ifd0Count)
    exifOff = ifd0Off + ifd0Size
    exifSize = if hasExif: ifdSize(e.exif.len) else: 0
    gpsOff = exifOff + exifSize
    gpsSize = if hasGps: ifdSize(e.gps.len) else: 0
    dataBase = gpsOff + gpsSize

  if hasExif: ifd0[0x8769] = longVal(exifOff)
  if hasGps: ifd0[0x8825] = longVal(gpsOff)

  var dataPool: seq[byte]
  proc emitIfd(ifd: ExifIfd): seq[byte] =
    result.add le16b(uint16(ifd.len))
    var ids: seq[uint16]
    for id in ifd.keys: ids.add id
    ids.sort() # TIFF requires ascending tag ids
    for id in ids:
      let (typ, count, data) = encode(ifd[id], e.endian)
      result.add le16b(id)
      result.add le16b(typ)
      result.add le32b(count)
      if data.len <= 4:
        var field = data
        while field.len < 4: field.add 0
        result.add field
      else:
        result.add le32b(uint32(dataBase + dataPool.len))
        dataPool.add data
        if dataPool.len mod 2 == 1: dataPool.add 0 # word alignment
    result.add le32b(0) # no chained IFD

  let ifd0Bytes = emitIfd(ifd0)
  let exifBytes = if hasExif: emitIfd(e.exif) else: @[]
  let gpsBytes = if hasGps: emitIfd(e.gps) else: @[]

  result.add @[byte 0x49, 0x49] # "II"
  result.add le16b(42)
  result.add le32b(uint32(ifd0Off))
  result.add ifd0Bytes
  result.add exifBytes
  result.add gpsBytes
  result.add dataPool

func startsWithIntelMarker(tiff: openArray[byte]): bool {.inline.} =
  ## True when the buffer opens with `II`, TIFF's little-endian byte order.
  tiff.len >= 2 and tiff[0] == 0x49 and tiff[1] == 0x49

proc serialize*(e: ExifData): seq[byte] {.contractual.} =
  ## Emit a valid little-endian TIFF carrying IFD0 + Exif/GPS sub-IFDs.
  require:
    e.ifd0.len <= int(high(uint16)) and e.exif.len <= int(high(uint16)) and
      e.gps.len <= int(high(uint16))
  ensure:
    # `II` -- the TIFF byte-order marker for little-endian, which is what this
    # writer emits. Named, because `result[0] == 0x49` says the byte and not
    # the meaning, and because a bracket in a rendered contract is read as a
    # link reference by the doc generator.
    result.len >= 8 and startsWithIntelMarker(result)
  body:
    result = serializeImpl(e)

# --- write back into the container -----------------------------------------

proc embedExifInJpeg(orig, tiff: openArray[byte]): seq[byte] =
  let segLen = 2 + 6 + tiff.len # length field + "Exif\0\0" + tiff
  var app1 = @[byte 0xFF, 0xE1, byte((segLen shr 8) and 0xFF), byte(segLen and 0xFF)]
  app1.add @[byte 0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
  app1.add tiff

  result.add orig[0]; result.add orig[1] # SOI
  var i = 2
  var inserted = false
  while i + 4 <= orig.len:
    if orig[i] != 0xFF: return @[]
    let marker = orig[i + 1]
    if marker == 0xDA: # SOS -> insert before the scan
      if not inserted: result.add app1
      result.add orig[i ..< orig.len]
      return
    let segLength = (int(orig[i + 2]) shl 8) or int(orig[i + 3])
    if segLength < 2 or i + 2 + segLength > orig.len: return @[]
    let isExif = marker == 0xE1 and i + 10 <= orig.len and
      orig[i + 4] == 0x45 and orig[i + 5] == 0x78 and
      orig[i + 6] == 0x69 and orig[i + 7] == 0x66
    if isExif:
      if not inserted:
        result.add app1
        inserted = true # replace only the first APP1 Exif
    else:
      result.add orig[i ..< i + 2 + segLength]
    i += 2 + segLength
  if not inserted: result.add app1
  if i < orig.len: result.add orig[i ..< orig.len]

proc carriesImageStrips(data: openArray[byte]): bool =
  ## Whether a TIFF holds pixel data this writer does not reproduce.
  ##
  ## Serializing the parsed EXIF back is a whole file only for a TIFF that is
  ## nothing but metadata. A photographic TIFF, and every vendor RAW built on
  ## one, keeps its pixels in strips or tiles the parse never looked at --
  ## writing the block alone would hand back the thumbnail and drop the
  ## picture. Measured on a Nikon NEF: 17,780,638 bytes in, 108,878 out.
  if data.len < 8: return false
  let endian = if data[0] == 0x49: LittleEndian else: BigEndian
  var offset = int(readUint32(data, 4, endian))
  var seen = 0
  # A chain rather than one directory: a RAW keeps the full-size image in a
  # later entry and the thumbnail in the first.
  while offset > 0 and offset + 2 <= data.len and seen < 16:
    let ifd = readIFD(data, offset, 0, endian)
    # StripOffsets, StripByteCounts, TileOffsets, TileByteCounts.
    for id in [0x0111'u16, 0x0117'u16, 0x0144'u16, 0x0145'u16]:
      if ifd.tags.hasKey(id): return true
    inc seen
    let following = int(ifd.nextIfdOffset)
    if following <= 0 or following >= data.len: break
    offset = following

proc writeExifBytesImpl(orig: openArray[byte]; e: ExifData): seq[byte] =
  ## Embed `e` back into the original image bytes and return the new buffer, or
  ## `@[]` on an unsupported or oversized container. Pure in-memory, no file I/O.
  ## JPEG: rebuild the APP1 segment, preserving everything else. Standalone TIFF:
  ## the serialized block. PNG/WebP/HEIC/AVIF: replace the Exif payload in place.
  if orig.len < 2: return @[]
  let tiff = serialize(e)
  if orig[0] == 0xFF and orig[1] == 0xD8:
    if tiff.len + 8 > 0xFFFF: return @[] # cannot fit in one APP1 segment
    return embedExifInJpeg(orig, tiff)
  elif (orig[0] == 0x49 and orig[1] == 0x49) or
       (orig[0] == 0x4D and orig[1] == 0x4D):
    # Only a TIFF that is metadata and nothing else. One carrying pixels is
    # refused rather than replaced by its own EXIF block, which is what the
    # line below would otherwise do to every RAW handed to it.
    if carriesImageStrips(orig): return @[]
    return tiff
  elif isPng(orig):
    return replacePngExif(orig, tiff) # @[] on failure (propagated)
  elif isWebp(orig):
    return replaceWebpExif(orig, tiff) # @[] for simple-format WebP (no VP8X)
  elif isIsobmff(orig):
    return writeExifIsobmff(orig, tiff) # @[] if no single-extent file-offset Exif item
  else:
    return @[]

proc writeExifBytes*(orig: openArray[byte]; e: ExifData): seq[
    byte] {.contractual.} =
  ## Embed `e` in supported image bytes, or return `@[]` on failure.
  ensure:
    result.len == 0 or result.len >= 2
  body:
    result = writeExifBytesImpl(orig, e)

proc replaceFile(path: string; data: openArray[byte]): bool =
  let tmp = path & ".uniimage-" & $getCurrentProcessId() & ".tmp"
  if fileExists(tmp): return false
  let mode = if fileExists(path): some(getFilePermissions(path))
    else: none(set[FilePermission])
  var f: File
  try:
    if not open(f, tmp, fmWrite): return false
    defer:
      if f != nil: f.close()
      if fileExists(tmp):
        try: removeFile(tmp)
        except CatchableError: discard
    if data.len > 0 and f.writeBuffer(unsafeAddr data[0], data.len) != data.len:
      return false
    if mode.isSome: setFilePermissions(tmp, mode.get)
    f.flushFile()
    when defined(windows):
      if flushFileBuffers(Handle(f.getOsFileHandle())) == 0:
        return false
    else:
      if posix.fsync(cint(f.getFileHandle())) != 0:
        return false
    f.close()
    f = nil
    moveFile(tmp, path)
    true
  except CatchableError:
    false

proc writeExif*(path: string; e: ExifData; outPath = ""): bool =
  ## File wrapper over `writeExifBytes`. JPEG: rebuild the APP1 segment,
  ## preserving everything else. Standalone TIFF: write the serialized block.
  ## PNG, WebP, HEIC and AVIF: replace the Exif payload in place. Returns false
  ## on unsupported input or write failure.
  let dst = if outPath.len > 0: outPath else: path
  let output = writeExifBytes(readWholeFile(path), e)
  if output.len == 0: return false
  replaceFile(dst, output)

proc stripMetadataBytesImpl(data: openArray[byte]): seq[byte] =
  ## Return a copy of `data` with metadata removed (image data preserved), or
  ## `@[]` if the container is unsupported or malformed. Pure in-memory, no file I/O.
  ## JPEG: drop APP1 (Exif/XMP), APP13 (IPTC), COM. PNG: drop eXIf/tEXt/iTXt/zTXt.
  ## WebP: drop EXIF/XMP. HEIC/AVIF: neutralize Exif+XMP items in place.
  if data.len < 2: return
  if isPng(data): return stripPng(data)
  if isWebp(data): return stripWebp(data)
  if isIsobmff(data): return stripIsobmff(data)
  if data[0] != 0xFF or data[1] != 0xD8: return
  result = @[byte 0xFF, 0xD8]
  var i = 2
  while i + 4 <= data.len:
    if data[i] != 0xFF: return @[]
    let marker = data[i + 1]
    if marker == 0xD9: # EOI: preserve the complete JPEG terminator and residue
      result.add data.toOpenArray(i, data.len - 1)
      return
    if marker == 0xDA: # SOS: copy the rest verbatim
      result.add data.toOpenArray(i, data.len - 1)
      return
    let segLength = (int(data[i + 2]) shl 8) or int(data[i + 3])
    if segLength < 2 or i + 2 + segLength > data.len: return @[]
    if marker notin [0xE1'u8, 0xED'u8, 0xFE'u8]:
      result.add data.toOpenArray(i, i + 2 + segLength - 1)
    i += 2 + segLength
  if i + 2 <= data.len and data[i] == 0xFF and data[i + 1] == 0xD9:
    result.add data.toOpenArray(i, data.len - 1)
  elif i != data.len:
    return @[]

proc stripMetadataBytes*(data: openArray[byte]): seq[byte] {.contractual.} =
  ## Return metadata-free bytes, or `@[]` for unsupported/malformed input.
  ensure:
    result.len <= data.len
  body:
    result = stripMetadataBytesImpl(data)

proc stripMetadata*(inPath, outPath: string): bool =
  ## File wrapper over `stripMetadataBytes`. JPEG: drop APP1, APP13 and COM.
  ## PNG: drop eXIf, tEXt, iTXt and zTXt. WebP: drop EXIF and XMP. HEIC and
  ## AVIF: neutralize the Exif and XMP items in place. Returns false on
  ## unsupported input or write failure.
  let output = stripMetadataBytes(readWholeFile(inPath))
  if output.len == 0: return false
  replaceFile(outPath, output)
