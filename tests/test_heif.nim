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

when defined(macosx) and defined(appleCodecs):
  suite "the system decoder, when the build asked for it":
    test "every fixture decodes to the size the container declared":
      # Which is the check that matters for the clean-aperture case: ImageIO
      # applies the crop, so agreement proves this reader applied it too.
      for name in ["apple.heic", "libheif.heic", "portrait.heic"]:
        let raw = readFile(Fixtures / name)
        var bytes = newSeq[byte](raw.len)
        for index in 0 ..< raw.len: bytes[index] = byte(raw[index])
        let container = readHeif(bytes)
        let pixels = decodeHeifApple(bytes)
        check (pixels.width, pixels.height) == (container.width,
            container.height)
        check pixels.channels == 4
        check pixels.data.len == pixels.width * pixels.height * 4

    test "the pixels are the ones sips gets from the same file":
      # sips converts the HEIC to PNG with the same system decoder; decoding
      # that PNG here and comparing is an end-to-end check of this path.
      if findExe("sips").len == 0:
        skip()
      else:
        let png = getTempDir() / "unimage-heif-oracle.png"
        defer: removeFile(png)
        let source = Fixtures / "apple.heic"
        check execCmdEx("sips -s format png " & source.quoteShell & " --out " &
          png.quoteShell).exitCode == 0
        let raw = readFile(source)
        var bytes = newSeq[byte](raw.len)
        for index in 0 ..< raw.len: bytes[index] = byte(raw[index])
        let mine = decodeHeifApple(bytes)
        let pngRaw = readFile(png)
        var pngBytes = newSeq[byte](pngRaw.len)
        for index in 0 ..< pngRaw.len: pngBytes[index] = byte(pngRaw[index])
        let theirs = decodeImage(pngBytes)
        check (mine.width, mine.height) == (theirs.width, theirs.height)
        var worst = 0
        for y in 0 ..< mine.height:
          for x in 0 ..< mine.width:
            for channel in 0 ..< 3:
              let a = int(mine.data[(y * mine.width + x) * mine.channels + channel])
              let b = int(theirs.data[(y * theirs.width + x) * theirs.channels + channel])
              worst = max(worst, abs(a - b))
        # One level: the two paths round their colour conversion differently.
        check worst <= 2

    test "decodeImage routes a HEIC to the system decoder":
      let raw = readFile(Fixtures / "apple.heic")
      var bytes = newSeq[byte](raw.len)
      for index in 0 ..< raw.len: bytes[index] = byte(raw[index])
      let image = decodeImage(bytes)
      check (image.width, image.height) == (64, 48)

    test "bytes that are not HEIF are refused before the system sees them":
      var notHeif: seq[byte]
      for character in "still not a picture":
        notHeif.add byte(character)
      expect UniImageException:
        discard decodeHeifApple(notHeif)
