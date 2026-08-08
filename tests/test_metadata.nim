# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Behavioral coverage for the public metadata helpers that do not require
## external fixtures or codec tooling.

import std/[options, os, strutils, tables, unittest]
import UniImage/exif/[endian, enums, iptc, isobmff, tiff]

proc be16(value: int): seq[byte] =
  @[byte((value shr 8) and 0xFF), byte(value and 0xFF)]

proc be32(value: int): seq[byte] =
  @[byte((value shr 24) and 0xFF), byte((value shr 16) and 0xFF),
    byte((value shr 8) and 0xFF), byte(value and 0xFF)]

proc box(kind: string; payload: seq[byte]): seq[byte] =
  result.add be32(payload.len + 8)
  for c in kind: result.add byte(c)
  result.add payload

proc fullBox(kind: string; version: byte; payload: seq[byte]): seq[byte] =
  box(kind, @[version, byte 0, 0, 0] & payload)

proc countJpegMarker(data: openArray[byte]; wanted: byte): int =
  var pos = 2
  while pos + 4 <= data.len and data[pos] == 0xFF:
    let marker = data[pos + 1]
    if marker == 0xDA or marker == 0xD9: break
    let size = int(data[pos + 2]) shl 8 or int(data[pos + 3])
    if size < 2 or pos + 2 + size > data.len: break
    if marker == wanted: inc result
    pos += 2 + size

proc isobmffV2Exif(): seq[byte] =
  let itemId = 0x00010002
  var infePayload = be32(itemId) & be16(0)
  for c in "Exif": infePayload.add byte(c)
  infePayload.add 0
  let iinf = fullBox("iinf", 1, be32(1) & fullBox("infe", 3, infePayload))
  var ilocPayload = @[byte 0x44, 0x00] & be32(1) & be32(itemId) & be16(0) &
    be16(0) & be16(1) & be32(0)
  let tiff = @[byte 0x49, 0x49, 0x2A, 0x00, 0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  ilocPayload.add be32(tiff.len + 4)
  let ftyp = box("ftyp", @[byte 0x68, 0x65, 0x69, 0x63])
  let metaPrefix = fullBox("meta", 0, iinf & fullBox("iloc", 2, ilocPayload))
  let payloadOffset = ftyp.len + metaPrefix.len + 8
  let offsetPos = ilocPayload.len - 8
  ilocPayload[offsetPos ..< offsetPos + 4] = be32(payloadOffset)
  let iloc = fullBox("iloc", 2, ilocPayload)
  result = ftyp
  result.add fullBox("meta", 0, iinf & iloc)
  result.add box("mdat", @[byte 0, 0, 0, 0] & tiff)

suite "TIFF tag bounds":
  test "a truncated public tag read stays empty":
    let tag = readTag(@[byte 1, 2, 3], 0, 0, LittleEndian)
    check tag.rawBytes.len == 0
    check readLongTag(tag).isNone

suite "ISOBMFF item locations":
  test "iloc version 2 uses 32-bit counts and item identifiers":
    let data = isobmffV2Exif()
    let loc = locateExifItem(data)
    check loc.found
    check loc.ec == 1 and loc.cmeth == 0
    check findExifTiffInIsobmff(data) == loc.off + 4

suite "EXIF enum rendering":
  test "orientation and basic enums render known and unknown values":
    check getOrientation(1) == "Horizontal (normal)"
    check getOrientation(2) == "Mirror horizontal"
    check getOrientation(3) == "Rotate 180"
    check getOrientation(4) == "Mirror vertical"
    check getOrientation(5) == "Mirror horizontal and rotate 270 CW"
    check getOrientation(6) == "Rotate 90 CW"
    check getOrientation(7) == "Mirror horizontal and rotate 90 CW"
    check getOrientation(8) == "Rotate 270 CW"
    check getOrientation(99) == "99"

    for (value, expected) in [(1, "None"), (2, "inches"), (3, "cm"), (9, "9")]:
      check getResolutionUnit(value) == expected
    for (value, expected) in [(0, "Not Defined"), (1, "Manual"),
        (2, "Program AE"), (3, "Aperture-priority AE"),
        (4, "Shutter speed priority AE"), (5, "Creative (Slow speed)"),
        (6, "Action (High speed)"), (7, "Portrait"), (8, "Landscape"),
        (99, "99")]:
      check getExposureProgram(value) == expected
    for (value, expected) in [(0, "Unknown"), (1, "Average"),
        (2, "Center-weighted average"), (3, "Spot"), (4, "Multi-spot"),
        (5, "Multi-segment"), (6, "Partial"), (255, "Other"), (99, "99")]:
      check getMeteringMode(value) == expected

  test "light, capture and color enums cover their documented values":
    let lights = [(0, "Unknown"), (1, "Daylight"), (2, "Fluorescent"),
      (3, "Tungsten (Incandescent)"), (4, "Flash"), (9, "Fine weather"),
      (10, "Cloudy"), (11, "Shade"),
      (12, "Daylight fluorescent (D 5700 - 7100K)"),
      (13, "Day white fluorescent (N 4600 - 5500K)"),
      (14, "Cool white fluorescent (W 3800 - 4500K)"),
      (15, "White fluorescent (WW 3200 - 3700K)"),
      (16, "Warm white fluorescent (L 2600 - 3200K)"),
      (17, "Standard light A"), (18, "Standard light B"),
      (19, "Standard light C"), (20, "D55"), (21, "D65"), (22, "D75"),
      (23, "D50"), (24, "ISO studio tungsten"), (255, "Other"), (99, "99")]
    for (value, expected) in lights:
      check getLightSource(value) == expected
    for (value, expected) in [(0, "Auto"), (1, "Manual"), (9, "9")]:
      check getWhiteBalance(value) == expected
    for (value, expected) in [(1, "sRGB"), (2, "Adobe RGB"),
        (0xFFFD, "Wide Gamut RGB"), (0xFFFE, "ICC Profile"),
        (0xFFFF, "Uncalibrated"), (9, "9")]:
      check getColorSpace(value) == expected
    for (value, expected) in [(0, "Auto"), (1, "Manual"),
        (2, "Auto bracket"), (9, "9")]:
      check getExposureMode(value) == expected
    for (value, expected) in [(0, "Standard"), (1, "Landscape"),
        (2, "Portrait"), (3, "Night"), (4, "Other"), (9, "9")]:
      check getSceneCaptureType(value) == expected
    for (value, expected) in [(1, "Not defined"), (2, "One-chip color area"),
        (3, "Two-chip color area"), (4, "Three-chip color area"),
        (5, "Color sequential area"), (7, "Trilinear"),
        (8, "Color sequential linear"), (9, "9")]:
      check getSensingMethod(value) == expected
    check getGpsAltitudeRef(0) == "Above Sea Level"
    check getGpsAltitudeRef(1) == "Below Sea Level"
    check getGpsAltitudeRef(9) == "9"

  test "flash bit masks render every supported combination":
    let flashes = [(0x00, "No Flash"), (0x01, "Fired"),
      (0x05, "Fired, Return not detected"), (0x07, "Fired, Return detected"),
      (0x08, "On, Did not fire"), (0x09, "On, Fired"),
      (0x0d, "On, Return not detected"), (0x0f, "On, Return detected"),
      (0x10, "Off, Did not fire"),
      (0x14, "Off, Did not fire, Return not detected"),
      (0x18, "Auto, Did not fire"), (0x19, "Auto, Fired"),
      (0x1d, "Auto, Fired, Return not detected"),
      (0x1f, "Auto, Fired, Return detected"), (0x20, "No flash function"),
      (0x30, "Off, No flash function"), (0x41, "Fired, Red-eye reduction"),
      (0x45, "Fired, Red-eye reduction, Return not detected"),
      (0x47, "Fired, Red-eye reduction, Return detected"),
      (0x49, "On, Red-eye reduction"),
      (0x4d, "On, Red-eye reduction, Return not detected"),
      (0x4f, "On, Red-eye reduction, Return detected"),
      (0x50, "Off, Red-eye reduction"),
      (0x58, "Auto, Did not fire, Red-eye reduction"),
      (0x59, "Auto, Fired, Red-eye reduction"),
      (0x5d, "Auto, Fired, Red-eye reduction, Return not detected"),
      (0x5f, "Auto, Fired, Red-eye reduction, Return detected")]
    for (value, expected) in flashes:
      check parseFlash(value) == expected
    check parseFlash(2) == "Unknown (2)"

suite "IPTC-IIM round trip":
  const fields = [
    ("ObjectName", "A title"), ("Caption-Abstract", "A caption"),
    ("Headline", "A headline"), ("Keywords", "one"),
    ("Keywords", "two"), ("By-line", "Ada"), ("By-line", "Grace"),
    ("CopyrightNotice", "Copyright holder"), ("Credit", "Agency"),
    ("Source", "Camera"), ("City", "Paris"),
    ("Province-State", "Ile-de-France"),
    ("Country-PrimaryLocationName", "France"), ("UnknownField", "ignored")]

  test "all structured and generic fields survive JPEG insertion":
    let jpeg = @[byte 0xFF, 0xD8, 0xFF, 0xD9]
    let encoded = setIptcInJpeg(jpeg, @fields)
    let metadata = parseIptc(encoded)
    check encoded[0 .. 1] == jpeg[0 .. 1]
    check metadata.title == "A title"
    check metadata.caption == "A caption"
    check metadata.headline == "A headline"
    check metadata.keywords == @["one", "two"]
    check metadata.byline == @["Ada", "Grace"]
    check metadata.copyright == "Copyright holder"
    check metadata.credit == "Agency"
    check metadata.source == "Camera"
    check metadata.city == "Paris"
    check metadata.state == "Ile-de-France"
    check metadata.country == "France"
    check metadata.all["Keywords"] == "one, two"
    check metadata.all["ApplicationRecordVersion"] == "4"
    check not metadata.all.hasKey("UnknownField")

  test "a new APP13 replaces the previous IPTC resource":
    let jpeg = @[byte 0xFF, 0xD8, 0xFF, 0xD9]
    let first = setIptcInJpeg(jpeg, @[("ObjectName", "old")])
    let second = setIptcInJpeg(first, @[("ObjectName", "new")])
    check parseIptc(second).title == "new"
    check "old" notin cast[string](second)
    check "new" in cast[string](second)
    check countJpegMarker(second, 0xED) == 1

  test "scan data and ordinary segments are preserved":
    let jpeg = @[byte 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x12, 0x34,
      0xFF, 0xDA, 0x00, 0x02, 0xAA, 0xBB]
    let encoded = setIptcInJpeg(jpeg, @[("ObjectName", "scan")])
    check parseIptc(encoded).title == "scan"
    check encoded[^6 .. ^1] == jpeg[^6 .. ^1]

  test "invalid input and oversized payload fail safely":
    check setIptcInJpeg(@[byte 0, 1], @fields).len == 0
    check parseIptc(@[byte 0, 1]).all.len == 0
    let tooLarge = repeat('x', 70_000)
    let truncated = setIptcInJpeg(@[byte 0xFF, 0xD8, 0xFF, 0xD9],
      @[("Caption-Abstract", tooLarge)])
    check parseIptc(truncated).caption.len == 0x7FFF

  test "readIptc reads the same public representation from disk":
    let path = getTempDir() / ("uniimage-test-iptc-" &
      $getCurrentProcessId() & ".jpg")
    defer:
      if fileExists(path): removeFile(path)
    let encoded = setIptcInJpeg(@[byte 0xFF, 0xD8, 0xFF, 0xD9],
      @[("ObjectName", "disk")])
    var raw = newString(encoded.len)
    for i, value in encoded: raw[i] = char(value)
    writeFile(path, raw)
    check readIptc(path).title == "disk"
