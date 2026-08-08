# SPDX-License-Identifier: Apache-2.0

type
  MetadataBlock* = object
    offset*: int
    length*: int

proc findExifAPP1*(data: openArray[byte]): MetadataBlock =
  ## Scans JPEG for APP1 EXIF marker.
  if data.len < 4: return
  if data[0] != 0xFF or data[1] != 0xD8: return # Not a JPEG SOI

  var i = 2
  while i + 4 < data.len:
    if data[i] != 0xFF: break
    let marker = data[i+1]
    if marker == 0xDA: break # Start of Scan, stop here

    let length = (int(data[i+2]) shl 8) or int(data[i+3])

    if marker == 0xE1: # APP1
      # Check if it's Exif
      if length >= 8 and i + 10 < data.len and
         data[i+4] == 0x45 and data[i+5] == 0x78 and
         data[i+6] == 0x69 and data[i+7] == 0x66 and
         data[i+8] == 0x00 and data[i+9] == 0x00:
        result.offset = i + 10
        result.length = length - 8
        return

    i += length + 2
