# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Bounds-safe little/big-endian readers shared by the format codecs. A read
## past the end yields 0 so an OOB access never becomes an `IndexDefect` that
## would bypass the error model; codecs also check lengths up front to raise a
## precise `uiTruncated`. Reimplemented from the on-disk format specs.
import UniImage/core

const MaxCodecDim* = 1 shl 30 # 1 Gpx — anything larger is a hostile/malformed file.

proc readU16le*(data: openArray[byte]; i: int): uint16 {.inline.} =
  if i < 0 or i > data.len - 2: return 0
  uint16(data[i]) or (uint16(data[i + 1]) shl 8)

proc readU32le*(data: openArray[byte]; i: int): uint32 {.inline.} =
  if i < 0 or i > data.len - 4: return 0
  uint32(data[i]) or (uint32(data[i + 1]) shl 8) or
    (uint32(data[i + 2]) shl 16) or (uint32(data[i + 3]) shl 24)

proc readI32le*(data: openArray[byte]; i: int): int32 {.inline.} =
  cast[int32](readU32le(data, i))

proc readU16be*(data: openArray[byte]; i: int): uint16 {.inline.} =
  if i < 0 or i > data.len - 2: return 0
  (uint16(data[i]) shl 8) or uint16(data[i + 1])

proc readU32be*(data: openArray[byte]; i: int): uint32 {.inline.} =
  if i < 0 or i > data.len - 4: return 0
  (uint32(data[i]) shl 24) or (uint32(data[i + 1]) shl 16) or
    (uint32(data[i + 2]) shl 8) or uint32(data[i + 3])

proc putU16le*(data: var seq[byte]; i: int; v: uint16) {.inline.} =
  data[i] = byte(v and 0xFF)
  data[i + 1] = byte((v shr 8) and 0xFF)

proc putU32le*(data: var seq[byte]; i: int; v: uint32) {.inline.} =
  data[i] = byte(v and 0xFF)
  data[i + 1] = byte((v shr 8) and 0xFF)
  data[i + 2] = byte((v shr 16) and 0xFF)
  data[i + 3] = byte((v shr 24) and 0xFF)

proc putU16be*(data: var seq[byte]; i: int; v: uint16) {.inline.} =
  data[i] = byte((v shr 8) and 0xFF)
  data[i + 1] = byte(v and 0xFF)

proc putU32be*(data: var seq[byte]; i: int; v: uint32) {.inline.} =
  data[i] = byte((v shr 24) and 0xFF)
  data[i + 1] = byte((v shr 16) and 0xFF)
  data[i + 2] = byte((v shr 8) and 0xFF)
  data[i + 3] = byte(v and 0xFF)

proc putU16le*(b: var seq[byte]; v: uint16) {.inline.} =
  b.add byte(v and 0xFF); b.add byte((v shr 8) and 0xFF)

proc putU32le*(b: var seq[byte]; v: uint32) {.inline.} =
  b.add byte(v and 0xFF); b.add byte((v shr 8) and 0xFF)
  b.add byte((v shr 16) and 0xFF); b.add byte((v shr 24) and 0xFF)

proc putU16be*(b: var seq[byte]; v: uint16) {.inline.} =
  b.add byte((v shr 8) and 0xFF); b.add byte(v and 0xFF)

proc putU32be*(b: var seq[byte]; v: uint32) {.inline.} =
  b.add byte((v shr 24) and 0xFF); b.add byte((v shr 16) and 0xFF)
  b.add byte((v shr 8) and 0xFF); b.add byte(v and 0xFF)

proc requireLen*(data: openArray[byte]; need: int; msg: string) {.inline.} =
  if data.len < need:
    raise UniImageException(code: uiTruncated, msg: msg)

const CrcTable: array[256, uint32] = block:
  ## Standard CRC-32 (ISO-HDLC) lookup table, generated at compile time.
  var t: array[256, uint32]
  for n in 0 ..< 256:
    var c = uint32(n)
    for _ in 0 ..< 8:
      c = if (c and 1) != 0: (c shr 1) xor 0xEDB88320'u32 else: c shr 1
    t[n] = c
  t

proc crc32Init*(): uint32 {.inline.} = 0xFFFFFFFF'u32

proc crc32Update*(crc: uint32; b: byte): uint32 {.inline.} =
  ## Fold one byte into a running CRC. Lets callers checksum non-contiguous
  ## spans (PNG chunk type then chunk data) without allocating a buffer.
  (crc shr 8) xor CrcTable[(crc xor uint32(b)) and 0xFF]

proc crc32Final*(crc: uint32): uint32 {.inline.} = crc xor 0xFFFFFFFF'u32

proc crc32*(data: openArray[byte]): uint32 =
  ## CRC-32 (ISO-HDLC, the PNG chunk checksum). Table-driven. Used to verify
  ## chunk integrity; callers with disjoint spans use crc32Init/Update/Final.
  result = crc32Init()
  for b in data: result = crc32Update(result, b)
  result = crc32Final(result)
