# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
type
  TiffEndianness* = enum
    LittleEndian,
    BigEndian

proc readUint16*(data: openArray[byte], offset: int,
    endian: TiffEndianness): uint16 =
  ## Two bytes at `offset`, in the byte order the TIFF header declared.
  ## Out of range reads zero rather than raising: EXIF is parsed from files
  ## that may be truncated or hostile, and every caller here treats a zero as
  ## "absent" already.
  if offset < 0 or offset + 1 >= data.len: return 0
  if endian == LittleEndian:
    result = uint16(data[offset]) or (uint16(data[offset+1]) shl 8)
  else:
    result = (uint16(data[offset]) shl 8) or uint16(data[offset+1])

proc readUint32*(data: openArray[byte], offset: int,
    endian: TiffEndianness): uint32 =
  ## Four bytes at `offset`, in the declared byte order, with the same
  ## out-of-range behaviour as `readUint16`.
  if offset < 0 or offset + 3 >= data.len: return 0
  if endian == LittleEndian:
    result = uint32(data[offset]) or
             (uint32(data[offset+1]) shl 8) or
             (uint32(data[offset+2]) shl 16) or
             (uint32(data[offset+3]) shl 24)
  else:
    result = (uint32(data[offset]) shl 24) or
             (uint32(data[offset+1]) shl 16) or
             (uint32(data[offset+2]) shl 8) or
             uint32(data[offset+3])

proc writeUint16*(data: var openArray[byte], offset: int, value: uint16,
    endian: TiffEndianness) =
  ## Write two bytes at `offset` in the declared byte order. Out of range
  ## writes nothing, so a caller cannot corrupt a neighbouring field by being
  ## wrong about a length.
  if offset < 0 or offset + 1 >= data.len: return
  if endian == LittleEndian:
    data[offset] = byte(value and 0xFF)
    data[offset+1] = byte((value shr 8) and 0xFF)
  else:
    data[offset] = byte((value shr 8) and 0xFF)
    data[offset+1] = byte(value and 0xFF)

proc writeUint32*(data: var openArray[byte], offset: int, value: uint32,
    endian: TiffEndianness) =
  ## Write four bytes at `offset`, with the same guard as `writeUint16`.
  if offset < 0 or offset + 3 >= data.len: return
  if endian == LittleEndian:
    data[offset] = byte(value and 0xFF)
    data[offset+1] = byte((value shr 8) and 0xFF)
    data[offset+2] = byte((value shr 16) and 0xFF)
    data[offset+3] = byte((value shr 24) and 0xFF)
  else:
    data[offset] = byte((value shr 24) and 0xFF)
    data[offset+1] = byte((value shr 16) and 0xFF)
    data[offset+2] = byte((value shr 8) and 0xFF)
    data[offset+3] = byte(value and 0xFF)
