# SPDX-License-Identifier: Apache-2.0

## EXIF thumbnail extraction (IFD1 JPEGInterchangeFormat and its length tag).
##
## A privacy-relevant feature: a thumbnail can retain the original, uncropped
## framing even after the main image is edited. LeakAudit/MetaStrip surface it.

import ./endian, ./tiff, ./jpeg
import std/[options, tables]

proc tiffBase(data: openArray[byte]): int =
  ## Offset of the TIFF header (II/MM) for a JPEG or a raw TIFF, or -1.
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8:
    let blk = findExifAPP1(data)
    if blk.length > 0: return blk.offset
    return -1
  if data.len >= 2 and ((data[0] == byte('I') and data[1] == byte('I')) or
                        (data[0] == byte('M') and data[1] == byte('M'))):
    return 0
  -1

proc extractExifThumbnailAt*(data: openArray[byte]; base: int): seq[byte] =
  ## The embedded JPEG thumbnail (EXIF IFD1) bytes given the TIFF-header offset
  ## `base` (the II/MM position within `data`), or `@[]` when absent. `base` may
  ## come from any container's EXIF locator (JPEG APP1, a raw TIFF, a PNG/WebP
  ## EXIF chunk, or a HEIC/AVIF Exif item).
  if base < 0 or base + 8 > data.len: return
  let endian = if char(data[base]) == 'I': LittleEndian else: BigEndian
  let firstIfd = int(readUint32(data, base + 4, endian))
  if base + firstIfd + 2 > data.len: return
  let ifd0 = readIFD(data, base + firstIfd, base, endian)
  if ifd0.nextIfdOffset == 0: return
  let ifd1Off = base + int(ifd0.nextIfdOffset)
  if ifd1Off + 2 > data.len: return
  let ifd1 = readIFD(data, ifd1Off, base, endian)
  if not (ifd1.tags.hasKey(0x0201) and ifd1.tags.hasKey(0x0202)): return
  let offOpt = readLongTag(ifd1.tags[0x0201])
  let lenOpt = readLongTag(ifd1.tags[0x0202])
  if offOpt.isNone or lenOpt.isNone: return
  let thumbOff = base + offOpt.get
  let thumbLen = lenOpt.get
  if thumbLen <= 0 or thumbOff < 0 or thumbOff + thumbLen > data.len: return
  result = newSeq[byte](thumbLen)
  for k in 0 ..< thumbLen: result[k] = data[thumbOff + k]

proc extractExifThumbnail*(data: openArray[byte]): seq[byte] =
  ## The embedded JPEG thumbnail (EXIF IFD1) bytes for a JPEG or TIFF file,
  ## or `@[]` when absent.
  extractExifThumbnailAt(data, tiffBase(data))

proc readThumbnail*(path: string): seq[byte] =
  ## Read the embedded EXIF thumbnail from a JPEG or TIFF file (`@[]` if none).
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0: copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  extractExifThumbnail(bytes)
