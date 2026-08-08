# SPDX-License-Identifier: Apache-2.0

import contracts
import ./endian
import std/[options, strutils, tables]

type
  TagType* = enum
    ttByte = 1,
    ttAscii = 2,
    ttShort = 3,
    ttLong = 4,
    ttRational = 5,
    ttSByte = 6,
    ttUndefined = 7,
    ttSShort = 8,
    ttSLong = 9,
    ttSRational = 10,
    ttFloat = 11,
    ttDouble = 12

  Tag* = object
    id*: uint16
    tagType*: TagType
    count*: uint32
    dataOffset*: int
    rawBytes*: seq[byte]
    endian*: TiffEndianness

  IFD* = object
    tags*: Table[uint16, Tag]
    nextIfdOffset*: uint32

proc readTagImpl(data: openArray[byte], offset: int, tiffHeaderOffset: int,
    endian: TiffEndianness): Tag =
  if offset < 0 or offset + 12 > data.len: return
  result.id = readUint16(data, offset, endian)
  result.endian = endian
  let t = readUint16(data, offset + 2, endian)
  if t >= 1 and t <= 12:
    result.tagType = TagType(t)
  else:
    result.tagType = ttUndefined

  result.count = readUint32(data, offset + 4, endian)

  let typeSize = case result.tagType:
    of ttByte, ttAscii, ttSByte, ttUndefined: 1
    of ttShort, ttSShort: 2
    of ttLong, ttSLong, ttFloat: 4
    of ttRational, ttSRational, ttDouble: 8

  let totalSize64 = int64(result.count) * int64(typeSize)
  if totalSize64 < 0 or totalSize64 > int64(high(int)):
    result.rawBytes = @[]
    return
  let totalSize = int(totalSize64)

  if totalSize <= 4:
    # Value is in the offset field itself
    result.dataOffset = offset + 8
    if offset + 8 + totalSize <= data.len:
      result.rawBytes = newSeq[byte](totalSize)
      for i in 0 ..< totalSize:
        result.rawBytes[i] = data[offset + 8 + i]
  else:
    # Value is at an offset relative to tiff header
    let off = int(readUint32(data, offset + 8, endian))
    result.dataOffset = tiffHeaderOffset + off
    if totalSize > 0 and result.dataOffset >= 0 and result.dataOffset +
        totalSize <= data.len:
      result.rawBytes = newSeq[byte](totalSize)
      for i in 0 ..< totalSize:
        result.rawBytes[i] = data[result.dataOffset + i]
    else:
      result.rawBytes = @[]

proc readTag*(data: openArray[byte], offset: int, tiffHeaderOffset: int,
    endian: TiffEndianness): Tag {.contractual.} =
  ## Read one TIFF directory entry; invalid or truncated entries stay empty.
  ensure:
    result.rawBytes.len <= data.len
  body:
    result = readTagImpl(data, offset, tiffHeaderOffset, endian)

proc readLongTag*(tag: Tag): Option[int] =
  ## Decode a LONG offset only when its complete payload is available.
  if tag.rawBytes.len < 4: return none(int)
  some(int(readUint32(tag.rawBytes, 0, tag.endian)))

proc readIFDImpl(data: openArray[byte], offset: int, tiffHeaderOffset: int,
    endian: TiffEndianness): IFD =
  if offset + 2 > data.len: return
  let numTags = readUint16(data, offset, endian)
  var currentOffset = offset + 2

  for i in 0 ..< int(numTags):
    if currentOffset + 12 > data.len: break
    let tag = readTag(data, currentOffset, tiffHeaderOffset, endian)
    result.tags[tag.id] = tag
    currentOffset += 12

  if currentOffset + 4 <= data.len:
    result.nextIfdOffset = readUint32(data, currentOffset, endian)

proc readIFD*(data: openArray[byte], offset: int, tiffHeaderOffset: int,
    endian: TiffEndianness): IFD {.contractual.} =
  ## Read one TIFF image-file directory within the available buffer.
  ensure:
    result.tags.len <= int(high(uint16))
  body:
    result = readIFDImpl(data, offset, tiffHeaderOffset, endian)

proc gcd(a, b: uint32): uint32 =
  var x = a
  var y = b
  while y != 0:
    let t = y
    y = x mod y
    x = t
  return x

proc toStringImpl(tag: Tag): string =
  if tag.rawBytes.len == 0: return ""

  case tag.tagType:
    of ttAscii:
      for b in tag.rawBytes:
        if b == 0: break
        result.add char(b)
      # Trailing space/null padding (e.g. Pentax "PENTAX Corporation ") is trimmed
      # to match exiftool; leading and internal characters are preserved.
      result = result.strip(leading = false, trailing = true)
    of ttUndefined, ttByte, ttSByte:
      # If all bytes are printable ASCII, print as string
      var isAscii = true
      for b in tag.rawBytes:
        if b != 0 and (b < 32 or b > 126):
          isAscii = false
          break
      if isAscii and tag.rawBytes.len > 0:
        for b in tag.rawBytes:
          if b != 0: result.add char(b)
      else:
        for i, b in tag.rawBytes:
          if i > 0: result.add " "
          result.add b.toHex(2)
    of ttShort:
      let limit = min(int(tag.count), tag.rawBytes.len div 2)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        result.add $readUint16(tag.rawBytes, i * 2, tag.endian)
    of ttLong:
      let limit = min(int(tag.count), tag.rawBytes.len div 4)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        result.add $readUint32(tag.rawBytes, i * 4, tag.endian)
    of ttRational:
      let limit = min(int(tag.count), tag.rawBytes.len div 8)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        let num = readUint32(tag.rawBytes, i * 8, tag.endian)
        let den = readUint32(tag.rawBytes, i * 8 + 4, tag.endian)
        if den != 0:
          let d = gcd(num, den)
          let n1 = num div d
          let d1 = den div d
          if d1 == 1: result.add $n1
          else: result.add $n1 & "/" & $d1
        else:
          result.add $num & "/0"
    of ttSRational:
      let limit = min(int(tag.count), tag.rawBytes.len div 8)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        let num = cast[int32](readUint32(tag.rawBytes, i * 8, tag.endian))
        let den = cast[int32](readUint32(tag.rawBytes, i * 8 + 4, tag.endian))
        if den != 0:
          # abs() in int64 — abs(int32.low) would overflow (a real crash seen on
          # Canon SRational values).
          let numU = uint32(abs(int64(num)))
          let denU = uint32(abs(int64(den)))
          let d = gcd(numU, denU)
          let n1 = numU div d
          let d1 = denU div d
          let sign = if (num < 0) xor (den < 0): "-" else: ""
          if d1 == 1: result.add sign & $n1
          else: result.add sign & $n1 & "/" & $d1
        else:
          result.add $num & "/0"
    of ttSShort:
      let limit = min(int(tag.count), tag.rawBytes.len div 2)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        result.add $cast[int16](readUint16(tag.rawBytes, i * 2, tag.endian))
    of ttSLong:
      let limit = min(int(tag.count), tag.rawBytes.len div 4)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        result.add $cast[int32](readUint32(tag.rawBytes, i * 4, tag.endian))
    of ttFloat:
      let limit = min(int(tag.count), tag.rawBytes.len div 4)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        result.add $cast[float32](readUint32(tag.rawBytes, i * 4, tag.endian))
    of ttDouble:
      let limit = min(int(tag.count), tag.rawBytes.len div 8)
      for i in 0 ..< limit:
        if i > 0: result.add " "
        let a = readUint32(tag.rawBytes, i * 8, tag.endian)
        let b = readUint32(tag.rawBytes, i * 8 + 4, tag.endian)
        let bits = if tag.endian == LittleEndian: (uint64(b) shl 32) or uint64(a)
                   else: (uint64(a) shl 32) or uint64(b)
        result.add $cast[float64](bits)

proc toString*(tag: Tag): string {.contractual.} =
  ## Render a TIFF tag without reading beyond its captured payload.
  ensure:
    tag.rawBytes.len != 0 or result.len == 0
  body:
    result = toStringImpl(tag)
