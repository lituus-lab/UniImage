# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## HEIF containers, checked against the two encoders that wrote the fixtures.
##
## `sips` is Apple's own and `magick` is ImageMagick over libheif; both are
## asked what size each picture is, and both must agree with what this reader
## says. Two independent writers matter here because they disagree about how to
## express a size: libheif pads the coded picture and crops it back with a clean
## aperture, where Apple writes the size directly.
import std/[unittest, os, osproc, strutils]
import UniImage

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc oracleSize(path: string): string =
  ## `WxH` from ImageMagick, or "" when it is not installed.
  if findExe("magick").len == 0: return ""
  let (output, code) = execCmdEx("magick identify -format '%wx%h' " &
    path.quoteShell)
  if code != 0: return ""
  output.strip().strip(chars = {'\''})

suite "what the container says":
  test "a picture Apple wrote":
    let image = readHeifFile(Fixtures / "apple.heic")
    check (image.width, image.height) == (64, 48)
    check image.codec == "hvc1"
    check image.itemId > 0
    check image.rotation == heifRot0
    check not image.mirrored

  test "a picture libheif wrote, which pads and crops":
    # ispe declares 64x64 and a clean aperture narrows it to 64x48. Reading
    # ispe alone reports a padded size, which is what the oracles disagree with.
    let image = readHeifFile(Fixtures / "libheif.heic")
    check (image.codedWidth, image.codedHeight) == (64, 64)
    check (image.width, image.height) == (64, 48)

  test "a portrait picture keeps its orientation":
    let image = readHeifFile(Fixtures / "portrait.heic")
    check (image.width, image.height) == (48, 64)

  test "every fixture matches what ImageMagick reports":
    for name in ["apple.heic", "libheif.heic", "portrait.heic"]:
      let expected = oracleSize(Fixtures / name)
      if expected.len == 0: continue
      let image = readHeifFile(Fixtures / name)
      check $image.width & "x" & $image.height == expected

suite "where the coded bytes are":
  test "the primary item points inside the file":
    for name in ["apple.heic", "libheif.heic", "portrait.heic"]:
      let data = readFile(Fixtures / name)
      let image = readHeifFile(Fixtures / name)
      check image.dataLength > 0
      check image.dataOffset > 0
      check image.dataOffset + image.dataLength <= data.len

  test "the bytes are the ones mdat holds":
    # The item location must land inside mdat, not in the metadata ahead of it.
    let data = readFile(Fixtures / "apple.heic")
    let image = readHeifFile(Fixtures / "apple.heic")
    let mdat = data.find("mdat")
    check mdat > 0
    check image.dataOffset >= mdat

suite "recognition":
  test "HEIF is told apart from the MP4 it shares a structure with":
    for name in ["apple.heic", "libheif.heic", "portrait.heic"]:
      let data = readFile(Fixtures / name)
      var bytes = newSeq[byte](data.len)
      for index in 0 ..< data.len: bytes[index] = byte(data[index])
      check isHeif(bytes)
      check isIsobmff(bytes) # both, because HEIF is built on it

  test "bytes that are not HEIF are refused":
    var notHeif: seq[byte]
    for character in "not a picture at all, not even close":
      notHeif.add byte(character)
    check not isHeif(notHeif)
    expect ValueError:
      discard readHeif(notHeif)

  test "a truncated file raises rather than reading past its end":
    let data = readFile(Fixtures / "apple.heic")
    var step = 1
    while step < data.len:
      var bytes = newSeq[byte](step)
      for index in 0 ..< step: bytes[index] = byte(data[index])
      try:
        discard readHeif(bytes)
      except ValueError, IOError:
        discard
      step += 37
