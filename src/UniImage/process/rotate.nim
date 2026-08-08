# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Orthogonal rotate + flip. These are pure index remaps — no resampling, so
## they are lossless and exact on any colorspace/channel count. `rot90` is
## clockwise, `rot270` counter-clockwise, `rot180` a half-turn; flipH mirrors
## left-right, flipV mirrors top-bottom.
import UniImage/core

type
  RotateOp* = enum
    rot90  ## 90 deg clockwise
    rot180 ## 180 deg
    rot270 ## 90 deg counter-clockwise
    flipH  ## mirror left-right
    flipV  ## mirror top-bottom

proc rotate*(img: Image[uint8]; op: RotateOp): Image[uint8] =
  ## Apply an orthogonal rotate or flip to `img`. Returns a new `Image` with
  ## the colorspace and channel count preserved. 90/270 swap width and height;
  ## 180/flipH/flipV keep the dimensions.
  let ch = img.channels
  let W = img.width
  let H = img.height
  case op
  of rot180:
    result = newImage[uint8](W, H, img.colorspace)
    for y in 0 ..< H:
      for x in 0 ..< W:
        let s = (y * W + x) * ch
        let d = ((H - 1 - y) * W + (W - 1 - x)) * ch
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]
  of rot90: # clockwise: dst width = H, dst height = W
    result = newImage[uint8](H, W, img.colorspace)
    for sy in 0 ..< H:
      for sx in 0 ..< W:
        let dx = H - 1 - sy
        let dy = sx
        let s = (sy * W + sx) * ch
        let d = (dy * H + dx) * ch # result width = H
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]
  of rot270: # counter-clockwise: dst width = H, dst height = W
    result = newImage[uint8](H, W, img.colorspace)
    for sy in 0 ..< H:
      for sx in 0 ..< W:
        let dx = sy
        let dy = W - 1 - sx
        let s = (sy * W + sx) * ch
        let d = (dy * H + dx) * ch # result width = H
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]
  of flipH:
    result = newImage[uint8](W, H, img.colorspace)
    for y in 0 ..< H:
      for x in 0 ..< W:
        let s = (y * W + x) * ch
        let d = (y * W + (W - 1 - x)) * ch
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]
  of flipV:
    result = newImage[uint8](W, H, img.colorspace)
    for y in 0 ..< H:
      for x in 0 ..< W:
        let s = (y * W + x) * ch
        let d = ((H - 1 - y) * W + x) * ch
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]

proc applyExifOrientation*(img: Image[uint8]; orientation: int): Image[uint8] =
  ## Return pixels transformed according to the EXIF Orientation value.
  ##
  ## Values 5 and 7 are the two diagonal reflections. The result always owns
  ## its pixel buffer, including for orientation 1. Values outside 1..8 are
  ## invalid rather than being silently treated as identity.
  case orientation
  of 1:
    result = newImage[uint8](img.width, img.height, img.colorspace)
    for i, value in img.data:
      result.data[i] = value
  of 2:
    result = img.rotate(flipH)
  of 3:
    result = img.rotate(rot180)
  of 4:
    result = img.rotate(flipV)
  of 5:
    result = img.rotate(flipH).rotate(rot270)
  of 6:
    result = img.rotate(rot90)
  of 7:
    result = img.rotate(flipH).rotate(rot90)
  of 8:
    result = img.rotate(rot270)
  else:
    raise UniImageException(code: uiInvalidArg,
      msg: "EXIF orientation must be between 1 and 8")
