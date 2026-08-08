# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## process/ tests: resize (nearest/bilinear/box), crop, rotate/flip.
import std/unittest
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
