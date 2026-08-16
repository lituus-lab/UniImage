# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## process/ tests: resize (nearest/bilinear/box), crop, rotate/flip.
import std/unittest
when not defined(release) and not defined(danger):
  import contracts
import UniImage/core
import UniImage/process

# Build a csGray image from a flat data list (row-major, w*h values).
proc gray(data: openArray[uint8]; w, h: int): Image[uint8] =
  result = newImage[uint8](w, h, csGray)
  for i in 0 ..< data.len: result.data[i] = data[i]

# unittest `expect` cannot read `.code`, so catch by hand and compare.
proc raisesInvalidArg(p: proc()): bool =
  try: p()
  except UniImageException as e: return e.code == uiInvalidArg
  false

proc rgba(data: openArray[uint8]; w, h: int): Image[uint8] =
  result = newImage[uint8](w, h, csRgba)
  for i in 0 ..< data.len: result.data[i] = data[i]

suite "process composite":
  test "straight alpha source-over is pixel exact":
    var destination = rgba([0'u8, 0, 255, 255], 1, 1)
    let source = rgba([255'u8, 0, 0, 128], 1, 1)
    destination.compositeOver(source, 0, 0)
    check destination.data == [128'u8, 0, 127, 255]

  test "transparent destination preserves straight source channels":
    var destination = rgba([0'u8, 0, 0, 0], 1, 1)
    let source = rgba([10'u8, 20, 30, 128], 1, 1)
    destination.compositeOver(source, 0, 0)
    check destination.data == source.data

  test "partial source and destination alpha use the unrounded denominator":
    var destination = rgba([255'u8, 255, 255, 15], 1, 1)
    let source = rgba([254'u8, 254, 254, 8], 1, 1)
    destination.compositeOver(source, 0, 0)
    check destination.data == [255'u8, 255, 255, 23]

  test "equal straight channels remain equal across partial alpha pairs":
    for channel in [0'u8, 1, 127, 254, 255]:
      for sourceAlpha in [0'u8, 1, 7, 8, 15, 127, 254, 255]:
        for destinationAlpha in [0'u8, 1, 7, 8, 15, 127, 254, 255]:
          var destination = rgba([channel, channel, channel,
            destinationAlpha], 1, 1)
          let source = rgba([channel, channel, channel, sourceAlpha], 1, 1)
          destination.compositeOver(source, 0, 0)
          if destination.data[3] > 0:
            check destination.data[0 .. 2] == [channel, channel, channel]

  test "gray and RGB sources apply global opacity":
    var destination = rgba([0'u8, 0, 0, 0, 0, 0, 0, 0], 2, 1)
    let
      graySource = gray([80'u8], 1, 1)
      rgbSource = block:
        var image = newImage[uint8](1, 1, csRgb)
        image.data = @[10'u8, 20, 30]
        image
    destination.compositeOver(graySource, 0, 0, 128)
    destination.compositeOver(rgbSource, 1, 0, 128)
    check destination.data == [80'u8, 80, 80, 128, 10, 20, 30, 128]

  test "placement clips every destination edge":
    let source = rgba([
      1'u8, 0, 0, 255, 2, 0, 0, 255,
      3, 0, 0, 255, 4, 0, 0, 255], 2, 2)
    var destination = rgba(newSeq[uint8](3 * 3 * 4), 3, 3)
    destination.compositeOver(source, -1, -1)
    destination.compositeOver(source, 2, 2)
    check destination.data[0] == 4
    check destination.data[(2 * 3 + 2) * 4] == 1
    check destination.data[4] == 0

  test "aliased source is snapshotted before writes":
    var image = rgba([
      255'u8, 0, 0, 255,
      0, 255, 0, 255,
      0, 0, 255, 255], 3, 1)
    image.compositeOver(image, 1, 0)
    check image.data == [
      255'u8, 0, 0, 255,
      255, 0, 0, 255,
      0, 255, 0, 255]

  test "zero opacity and fully clipped placement are no-ops":
    var destination = rgba([1'u8, 2, 3, 4], 1, 1)
    let source = rgba([200'u8, 201, 202, 203], 1, 1)
    destination.compositeOver(source, 0, 0, 0)
    destination.compositeOver(source, high(int), low(int))
    check destination.data == [1'u8, 2, 3, 4]

  test "malformed images and non-RGBA destinations are rejected":
    let source = rgba([1'u8, 2, 3, 4], 1, 1)
    var rgbDestination = newImage[uint8](1, 1, csRgb)
    var malformed = source
    malformed.data.setLen(3)
    var destination = rgba([0'u8, 0, 0, 0], 1, 1)
    when defined(release) or defined(danger):
      check raisesInvalidArg(proc() =
        rgbDestination.compositeOver(source, 0, 0))
      check raisesInvalidArg(proc() =
        destination.compositeOver(malformed, 0, 0))
    else:
      expect PreConditionDefect:
        rgbDestination.compositeOver(source, 0, 0)
      expect PreConditionDefect:
        destination.compositeOver(malformed, 0, 0)

suite "process resize":
  test "nearest identity is exact":
    let img = gray([0'u8, 10, 20, 30, 40, 50, 60, 70, 80], 3, 3)
    let r = img.resize(3, 3, rfNearest)
    check r.width == 3
    check r.height == 3
    check r.data == img.data

  test "box downscale of a flat block is the flat value":
    let img = gray([200'u8, 200, 200, 200, 200, 200, 200, 200, 200, 200,
        200, 200, 200, 200, 200, 200], 4, 4)
    let r = img.resize(2, 2, rfBox)
    check r.width == 2
    check r.height == 2
    check r.data == [200'u8, 200, 200, 200]

  test "box downscale averages a 2x2 block":
    # 4x4 where each 2x2 block is flat: top-left 10, top-right 20, bottom-left
    # 30, bottom-right 40. A 2x2 box downscale samples one block per output, so
    # the result is [[10,20],[30,40]].
    let img = gray([10'u8, 10, 20, 20, 10, 10, 20, 20, 30, 30, 40, 40, 30,
        30, 40, 40], 4, 4)
    let r = img.resize(2, 2, rfBox)
    check r.data == [10'u8, 20, 30, 40]

  test "bilinear upscale preserves edge endpoints":
    let img = gray([0'u8, 100], 2, 1)
    let r = img.resize(4, 1, rfBilinear)
    check r.width == 4
    check r.height == 1
    check r.data[0] == 0 # left edge clamps to src[0]
    check r.data[3] == 100 # right edge clamps to src[1]

  test "bilinear RGBA ignores colours hidden by zero alpha":
    let image = rgba([
      255'u8, 0, 0, 0,
      0, 0, 255, 255], 2, 1)
    let resized = image.resize(3, 1, rfBilinear)
    check resized.data == [
      0'u8, 0, 0, 0,
      0, 0, 255, 128,
      0, 0, 255, 255]

  test "box RGBA averages premultiplied colours and alpha":
    let image = rgba([
      255'u8, 0, 0, 0,
      0, 255, 0, 255], 2, 1)
    check image.resize(1, 1, rfBox).data == [0'u8, 255, 0, 128]

  test "filtered fully transparent RGBA has canonical zero colour":
    let image = rgba([
      255'u8, 10, 20, 0,
      1, 200, 30, 0], 2, 1)
    check image.resize(3, 1, rfBilinear).data == newSeq[uint8](3 * 4)
    check image.resize(1, 1, rfBox).data == newSeq[uint8](4)

  test "sub-byte filtered alpha publishes canonical transparent black":
    let image = rgba([
      255'u8, 0, 0, 1,
      0, 0, 0, 0,
      0, 0, 0, 0], 3, 1)
    check image.resize(1, 1, rfBox).data == [0'u8, 0, 0, 0]

  test "vertical and two-dimensional RGBA filtering are premultiplied":
    let vertical = rgba([
      255'u8, 0, 0, 0,
      0, 0, 255, 255], 1, 2)
    check vertical.resize(1, 3, rfBilinear).data == [
      0'u8, 0, 0, 0,
      0, 0, 255, 128,
      0, 0, 255, 255]
    let square = rgba([
      255'u8, 0, 0, 0, 0, 0, 255, 255,
      0, 255, 0, 255, 255, 255, 0, 0], 2, 2)
    check square.resize(1, 1, rfBox).data == [0'u8, 128, 128, 128]

  test "opaque RGBA filtering matches the RGB channels exactly":
    var rgb = newImage[uint8](2, 2, csRgb)
    rgb.data = @[10'u8, 20, 30, 80, 90, 100,
      140, 150, 160, 220, 230, 240]
    var opaque = newImage[uint8](2, 2, csRgba)
    for pixel in 0 ..< 4:
      for channel in 0 ..< 3:
        opaque.data[pixel * 4 + channel] = rgb.data[pixel * 3 + channel]
      opaque.data[pixel * 4 + 3] = 255
    let
      rgbResult = rgb.resize(3, 3, rfBilinear)
      rgbaResult = opaque.resize(3, 3, rfBilinear)
    for pixel in 0 ..< 9:
      check rgbaResult.data[pixel * 4 .. pixel * 4 + 2] ==
        rgbResult.data[pixel * 3 .. pixel * 3 + 2]
      check rgbaResult.data[pixel * 4 + 3] == 255

  test "nearest RGBA retains caller bytes including hidden colours":
    let image = rgba([255'u8, 10, 20, 0], 1, 1)
    check image.resize(2, 2, rfNearest).data == [
      255'u8, 10, 20, 0, 255, 10, 20, 0,
      255, 10, 20, 0, 255, 10, 20, 0]

  test "malformed source layouts are rejected at the public boundary":
    var image = rgba([1'u8, 2, 3, 4], 1, 1)
    image.channels = 3
    when defined(release) or defined(danger):
      check raisesInvalidArg(proc() = discard image.resize(1, 1, rfBilinear))
      check raisesInvalidArg(proc() = discard image.resize(1, 1, rfNearest))
    else:
      expect PreConditionDefect:
        discard image.resize(1, 1, rfBilinear)
      expect PreConditionDefect:
        discard image.resize(1, 1, rfNearest)

  test "colorspace is preserved (csRgb and csGray)":
    var rgb = newImage[uint8](2, 2, csRgb)
    for i in 0 ..< rgb.data.len: rgb.data[i] = uint8(i)
    let r = rgb.resize(4, 4, rfBilinear)
    check r.colorspace == csRgb
    check r.channels == 3
    let g = gray([1'u8, 2, 3, 4], 2, 2)
    let rg = g.resize(4, 4, rfNearest)
    check rg.colorspace == csGray
    check rg.channels == 1

  test "1x1 input bilinear fills the target":
    let img = gray([42'u8], 1, 1)
    let r = img.resize(3, 3, rfBilinear)
    check r.width == 3
    check r.height == 3
    for v in r.data: check v == 42

  test "non-positive dims raise uiInvalidArg":
    let img = gray([1'u8, 2, 3, 4], 2, 2)
    check raisesInvalidArg(proc() = discard img.resize(0, 2))
    check raisesInvalidArg(proc() = discard img.resize(2, -1))

  test "oversized dims raise uiInvalidArg before allocating":
    # 40000x40000 (~1.6e9 px) exceeds the MaxResizePixels cap; the guard fires
    # before newImage, so no large buffer is allocated.
    let img = gray([1'u8, 2, 3, 4], 2, 2)
    check raisesInvalidArg(proc() = discard img.resize(40000, 40000))
    check raisesInvalidArg(proc() = discard img.resize(high(int), 1))

suite "process crop":
  test "sub-rect is exact":
    # 4x4 with data = its linear index.
    let img = gray([0'u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
        15], 4, 4)
    let r = img.crop(1, 1, 2, 2)
    check r.width == 2
    check r.height == 2
    # rows y=1..2, cols x=1..2 of the source.
    check r.data == [5'u8, 6, 9, 10]

  test "full-size crop equals the original":
    let img = gray([0'u8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
        15], 4, 4)
    let r = img.crop(0, 0, 4, 4)
    check r.data == img.data

  test "out-of-bounds and negative offsets raise uiInvalidArg":
    let img = gray([0'u8, 1, 2, 3], 2, 2)
    check raisesInvalidArg(proc() = discard img.crop(0, 0, 3, 1))
    check raisesInvalidArg(proc() = discard img.crop(1, 1, 2, 2))
    check raisesInvalidArg(proc() = discard img.crop(-1, 0, 1, 1))
    check raisesInvalidArg(proc() = discard img.crop(0, 0, 0, 1))

suite "process rotate/flip":
  test "rot90 of [[1,2],[3,4]] is [[3,1],[4,2]] (clockwise)":
    let img = gray([1'u8, 2, 3, 4], 2, 2)
    let r = img.rotate(rot90)
    check r.width == 2
    check r.height == 2
    check r.data == [3'u8, 1, 4, 2]

  test "rot270 of [[1,2],[3,4]] is [[2,4],[1,3]] (counter-clockwise)":
    let img = gray([1'u8, 2, 3, 4], 2, 2)
    let r = img.rotate(rot270)
    check r.data == [2'u8, 4, 1, 3]

  test "rot90 composed 4 times is identity":
    let img = gray([1'u8, 2, 3, 4, 5, 6, 7, 8, 9], 3, 3)
    var r = img
    for _ in 0 ..< 4: r = r.rotate(rot90)
    check r.width == 3
    check r.height == 3
    check r.data == img.data

  test "rot180 swaps both axes":
    let img = gray([1'u8, 2, 3, 4], 2, 2)
    let r = img.rotate(rot180)
    check r.data == [4'u8, 3, 2, 1]

  test "flipH twice is identity":
    let img = gray([1'u8, 2, 3, 4, 5, 6], 3, 2)
    var r = img
    r = r.rotate(flipH); r = r.rotate(flipH)
    check r.data == img.data

  test "flipV twice is identity":
    let img = gray([1'u8, 2, 3, 4, 5, 6], 3, 2)
    var r = img
    r = r.rotate(flipV); r = r.rotate(flipV)
    check r.data == img.data

  test "rot90/270 swap width and height":
    let img = gray([1'u8, 2, 3, 4, 5, 6], 3, 2)
    check img.rotate(rot90).width == 2
    check img.rotate(rot90).height == 3
    check img.rotate(rot270).width == 2
    check img.rotate(rot270).height == 3

suite "EXIF orientation":
  test "all eight orientations map a non-square image exactly":
    let img = gray([1'u8, 2, 3, 4, 5, 6], 3, 2)
    let expected = [
      @[1'u8, 2, 3, 4, 5, 6],
      @[3'u8, 2, 1, 6, 5, 4],
      @[6'u8, 5, 4, 3, 2, 1],
      @[4'u8, 5, 6, 1, 2, 3],
      @[1'u8, 4, 2, 5, 3, 6],
      @[4'u8, 1, 5, 2, 6, 3],
      @[6'u8, 3, 5, 2, 4, 1],
      @[3'u8, 6, 2, 5, 1, 4]
    ]
    for orientation in 1 .. 8:
      let r = img.applyExifOrientation(orientation)
      check r.data == expected[orientation - 1]
      if orientation in {5, 6, 7, 8}:
        check (r.width, r.height) == (2, 3)
      else:
        check (r.width, r.height) == (3, 2)

  test "identity owns an independent pixel buffer":
    let img = gray([1'u8, 2], 2, 1)
    var r = img.applyExifOrientation(1)
    r.data[0] = 9
    check img.data[0] == 1

  test "values outside the EXIF range raise uiInvalidArg":
    let img = gray([1'u8], 1, 1)
    check raisesInvalidArg(proc() = discard img.applyExifOrientation(0))
    check raisesInvalidArg(proc() = discard img.applyExifOrientation(9))
