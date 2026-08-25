# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## EXIF/XMP/IPTC round-trip tests over the C-ABI-free Nim surface.
## Self-contained: builds a minimal JPEG in memory, no fixture files.
import std/[unittest, json, tables, options, strutils, os, times]
import UniImage/exif
import UniImage/exif/xmp
import UniImage/exif/edit

## A minimal JPEG carrying one EXIF APP1 with Make="UniImage" and Orientation=1.
const minimalJpeg: seq[byte] = block:
  var tiff: seq[byte] = @[]
  # TIFF header: "II", 42, IFD0 offset = 8
  tiff.add [byte 0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
  # IFD0: 2 entries (Make 0x010F ASCII, Orientation 0x0112 SHORT), then next=0
  tiff.add [byte 0x02, 0x00] # count = 2
                               # Make entry: ASCII count 9, stored at offset 38.
  let makeOff = 8 + 2 + 2 * 12 + 4
  tiff.add [byte 0x0F, 0x01] # tag id 0x010F
  tiff.add [byte 0x02, 0x00] # type ASCII
  tiff.add byte(9) # count=9 incl NUL terminator (4 bytes)
  tiff.add byte(0)
  tiff.add byte(0)
  tiff.add byte(0)
  tiff.add byte(makeOff)
  tiff.add byte(makeOff shr 8)
  tiff.add byte(0)
  tiff.add byte(0)
  # Orientation entry: type 3 (SHORT), count 1, value 1 inline
  tiff.add [byte 0x12, 0x01] # tag id 0x0112
  tiff.add [byte 0x03, 0x00] # type SHORT
  tiff.add [byte 0x01, 0x00, 0x00, 0x00] # count=1
  tiff.add [byte 0x01, 0x00, 0x00, 0x00] # value=1 (inline)
                                           # next IFD = 0
  tiff.add [byte 0x00, 0x00, 0x00, 0x00]
  # Make string "UniImage\0" (9 bytes incl NUL)
  for c in "UniImage": tiff.add byte(c)
  tiff.add byte(0)
  # APP1 segment wrapping the TIFF block
  var app1: seq[byte] = @[]
  let segLen = 2 + 6 + tiff.len
  app1.add [byte 0xFF, 0xE1, byte((segLen shr 8) and 0xFF), byte(segLen and 0xFF)]
  app1.add [byte 0x45, 0x78, 0x69, 0x66, 0x00, 0x00] # "Exif\0\0"
  app1.add tiff
  var jpg: seq[byte] = @[]
  jpg.add [byte 0xFF, 0xD8] # SOI
  jpg.add app1
  jpg.add [byte 0xFF, 0xD9] # EOI
  jpg

proc countExifApp1(data: openArray[byte]): int =
  var pos = 2
  while pos + 4 <= data.len and data[pos] == 0xFF:
    let marker = data[pos + 1]
    if marker == 0xDA or marker == 0xD9: break
    let size = int(data[pos + 2]) shl 8 or int(data[pos + 3])
    if size < 2 or pos + 2 + size > data.len: break
    if marker == 0xE1 and pos + 10 <= data.len and
        data[pos + 4 .. pos + 7] == [byte 0x45, 0x78, 0x69, 0x66]:
      inc result
    pos += 2 + size

suite "exif read":
  test "reads Make and Orientation from a minimal JPEG":
    let m = readMetadataFromBytes(minimalJpeg)
    check m.isValid
    check m.allTags.hasKey("Make")
    check m.allTags["Make"] == "UniImage"
    check m.orientation == 1

  test "empty JPEG has no metadata":
    let m = readMetadataFromBytes([byte 0xFF, 0xD8, 0xFF, 0xD9])
    check not m.isValid

  test "orientation replacement is committed through a temporary file":
    let path = getTempDir() / ("uniimage-orientation-" &
      $getCurrentProcessId() & ".jpg")
    defer:
      if fileExists(path): removeFile(path)
    var raw = newString(minimalJpeg.len)
    for i, value in minimalJpeg: raw[i] = char(value)
    writeFile(path, raw)
    check writeExifOrientation(path, 6)
    check readMetadata(path).orientation == 6
    check not fileExists(path & ".uniimage-" & $getCurrentProcessId() & ".tmp")

  test "non-image is a no-op":
    let m = readMetadataFromBytes([byte 0x00, 0x01, 0x02, 0x03])
    check not m.isValid

suite "exif metaToJson":
  test "JSON contains isValid and tags":
    let m = readMetadataFromBytes(minimalJpeg)
    let j = parseJson(metaToJson(m))
    check j["isValid"].getBool()
    check j["tags"].hasKey("Make")

suite "exif strip":
  test "strip removes APP1 from a JPEG":
    let stripped = stripMetadataBytes(minimalJpeg)
    check stripped.len > 0
    check stripped[0] == 0xFF and stripped[1] == 0xD8
    check stripped[^2] == 0xFF and stripped[^1] == 0xD9
    # the stripped buffer must not carry the APP1 Exif marker
    var hasApp1Exif = false
    var i = 2
    while i + 4 < stripped.len:
      if stripped[i] == 0xFF and stripped[i+1] == 0xE1 and i + 10 <=
          stripped.len and
         stripped[i+4] == 0x45 and stripped[i+5] == 0x78:
        hasApp1Exif = true
        break
      if stripped[i] != 0xFF: break
      let segLen = (int(stripped[i+2]) shl 8) or int(stripped[i+3])
      i += 2 + segLen
    check not hasApp1Exif

  test "strip of a non-image returns empty":
    check stripMetadataBytes([byte 0x00, 0x01, 0x02, 0x03]).len == 0

  test "strip rejects a truncated JPEG segment instead of returning a prefix":
    check stripMetadataBytes([byte 0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x10,
      0x45, 0x78]).len == 0

  test "stripMetadata atomically replaces its destination":
    let stem = getTempDir() / ("uniimage-strip-" & $getCurrentProcessId())
    let src = stem & "-src.jpg"
    let dst = stem & "-dst.jpg"
    defer:
      for path in [src, dst, dst & ".uniimage-" & $getCurrentProcessId() & ".tmp"]:
        if fileExists(path): removeFile(path)
    var raw = newString(minimalJpeg.len)
    for i, value in minimalJpeg: raw[i] = char(value)
    writeFile(src, raw)
    writeFile(dst, "old")
    check stripMetadata(src, dst)
    let stripped = readFile(dst)
    check stripped.len >= 4 and stripped[^2] == char(0xFF) and
      stripped[^1] == char(0xD9)
    check not fileExists(dst & ".uniimage-" & $getCurrentProcessId() & ".tmp")

suite "exif edit":
  test "set Artist and round-trip":
    var e = parseExifBytes(minimalJpeg)
    e.setArtist("Jane Doe")
    let edited = writeExifBytes(minimalJpeg, e)
    check edited.len > minimalJpeg.len
    let m = readMetadataFromBytes(edited)
    check m.allTags.getOrDefault("Artist") == "Jane Doe"

  test "setTagByName rejects unknown tag":
    var e = parseExifBytes(minimalJpeg)
    check not e.setTagByName("NoSuchTag", "x")
    check e.setTagByName("ImageDescription", "hello")

  test "typed values reject EXIF integer narrowing":
    var e = parseExifBytes(minimalJpeg)
    check not e.setTagByName("Orientation", "65536")
    check not e.setTagByName("ExposureTime", "-1/1")
    check e.setTagByName("Orientation", "65535")

  test "byte values derive their serialized count from the payload":
    var e: ExifData
    e.setTag(igIfd0, 0xC001, byteVal([byte 1, 2, 3]))
    let parsed = parseExifBytes(serialize(e))
    check parsed.ifd0[0xC001].count == 3
    check parsed.ifd0[0xC001].bytes == @[byte 1, 2, 3]

  test "only the first Exif APP1 is replaced":
    let size = int(minimalJpeg[4]) shl 8 or int(minimalJpeg[5])
    let appEnd = 2 + 2 + size
    let duplicated = minimalJpeg[0 .. 1] & minimalJpeg[2 ..< appEnd] &
      minimalJpeg[2 ..< appEnd] & minimalJpeg[^2 .. ^1]
    let edited = writeExifBytes(duplicated, parseExifBytes(duplicated))
    check countExifApp1(edited) == 1

  test "writeExif replaces the destination atomically":
    let stem = getTempDir() / ("uniimage-edit-" & $getCurrentProcessId())
    let src = stem & "-src.jpg"
    let dst = stem & "-dst.jpg"
    defer:
      for path in [src, dst, dst & ".uniimage-" & $getCurrentProcessId() & ".tmp"]:
        if fileExists(path): removeFile(path)
    var raw = newString(minimalJpeg.len)
    for i, value in minimalJpeg: raw[i] = char(value)
    writeFile(src, raw)
    writeFile(dst, "old")
    when defined(posix):
      setFilePermissions(dst, {fpUserRead, fpUserWrite})
    var e = parseExifBytes(minimalJpeg)
    e.setArtist("Atomic")
    check writeExif(src, e, dst)
    check readMetadata(dst).allTags.getOrDefault("Artist") == "Atomic"
    when defined(posix):
      check getFilePermissions(dst) == {fpUserRead, fpUserWrite}
    check not fileExists(dst & ".uniimage-" & $getCurrentProcessId() & ".tmp")

suite "XMP preserving merge":
  test "managed edits preserve unknown namespaces and structures":
    let original = """<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:vendor="https://example.invalid/vendor/" vendor:flag="keep">
<dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old</rdf:li></rdf:Alt></dc:title>
<vendor:complex><rdf:Bag><rdf:li>A</rdf:li><rdf:li>B</rdf:li></rdf:Bag></vendor:complex>
</rdf:Description></rdf:RDF></x:xmpmeta>"""
    var patch: XmpPatch
    patch.title = some("New & safe")
    patch.properties["xmp:Rating"] = some("4")
    patch.namespaces["om"] = "https://lituus-lab.com/ns/organize-media/1.0/"
    patch.properties["om:Favorite"] = some("true")
    let merged = mergeXmp(original, patch)
    check "vendor:flag=\"keep\"" in merged
    check "<vendor:complex>" in merged
    check "<rdf:li>A</rdf:li>" in merged
    let parsed = parseXmp(merged)
    check parsed.title == "New & safe"
    check parsed.all["xmp:Rating"] == "4"
    check parsed.all["om:Favorite"] == "true"

  test "a custom property requires an explicit namespace URI":
    let original = buildXmp(XmpData(title: "Keep"))
    var patch: XmpPatch
    patch.properties["private:value"] = some("x")
    expect ValueError:
      discard mergeXmp(original, patch)

  test "structured edits declare Dublin Core when it was absent":
    let original = """<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description/></rdf:RDF></x:xmpmeta>"""
    var patch: XmpPatch
    patch.title = some("Declared")
    patch.keywords = some(@["valid"])
    let merged = mergeXmp(original, patch)
    check "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"" in merged
    let parsed = parseXmp(merged)
    check parsed.title == "Declared"
    check parsed.keywords == @["valid"]
    patch.namespaces["private"] = "https://example.invalid/"
    patch.properties.clear()
    patch.properties["private:bad name"] = some("x")
    expect ValueError:
      discard mergeXmp(original, patch)

  test "none preserves and some empty removes":
    let original = buildXmp(XmpData(title: "Keep", description: "Remove"))
    var patch: XmpPatch
    patch.description = some("")
    let parsed = parseXmp(mergeXmp(original, patch))
    check parsed.title == "Keep"
    check parsed.description.len == 0

suite "a TIFF container takes an EXIF write":
  ## What a vendor RAW is: DNG, NEF, CR2, ARW, RW2 and ORF all carry their
  ## sensor data in a TIFF container, so this is the path a date correction
  ## on one would take. The fixture is generated, not photographed --
  ## tests/fixtures/gen_synthetic_raw.sh regenerates it.
  const Raw = currentSourcePath.parentDir / "fixtures" / "synthetic-raw.tiff"

  test "the EXIF a TIFF carries is read":
    let meta = readMetadata(Raw)
    check meta.isValid
    check meta.cameraModel == "lituus-lab Synthetic RAW Camera"
    check meta.creationDate.format("yyyy-MM-dd") == "2019-03-14"
    check abs(meta.gpsLatitude - 45.9) < 0.001

  test "a rewritten date reads back, and the other tags survive it":
    let target = getTempDir() /
      ("uniimage-raw-" & $getCurrentProcessId() & ".tiff")
    defer: removeFile(target)
    var data = parseExif(Raw)
    data.setDateTimeOriginal("2021:07:04 12:00:00")
    check writeExif(Raw, data, target)
    let after = readMetadata(target)
    check after.creationDate.format("yyyy-MM-dd HH:mm:ss") ==
      "2021-07-04 12:00:00"
    # Rewriting one tag must not drop the rest: a RAW carries lens and
    # authorship data a correction has no business discarding.
    check after.cameraModel == "lituus-lab Synthetic RAW Camera"
    check abs(after.gpsLatitude - 45.9) < 0.001

  test "stripping is refused rather than half-done":
    # No TIFF branch in the strip dispatch, so it reports failure instead of
    # writing a file it did not clean.
    let target = getTempDir() /
      ("uniimage-rawstrip-" & $getCurrentProcessId() & ".tiff")
    check not stripMetadata(Raw, target)


