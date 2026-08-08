# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Bounds-checked sub-rect extraction. `crop` returns a new `Image` whose pixels
## are a contiguous copy of the source rectangle — no view/borrow, so the
## result outlives the source. Overruns raise `uiInvalidArg`.
import UniImage/core

type
  Rect* = object
    x*, y*, w*, h*: int

proc crop*(img: Image[uint8]; x, y, w, h: int): Image[uint8] =
  ## Extract the `w` x `h` rectangle at (`x`, `y`) from `img`. Raises
  ## `UniImageException(uiInvalidArg)` for negative offsets, non-positive
  ## dimensions, or a rectangle that runs past the source edges. The colorspace
  ## and channel count are preserved.
  if x < 0 or y < 0 or w <= 0 or h <= 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "crop: non-positive or negative")
  if x + w > img.width or y + h > img.height:
    raise UniImageException(code: uiInvalidArg,
        msg: "crop: rectangle overruns the source")
  result = newImage[uint8](w, h, img.colorspace)
  let ch = img.channels
  for dy in 0 ..< h:
    let s = ((y + dy) * img.width + x) * ch
    let d = (dy * w) * ch
    for k in 0 ..< w * ch:
      result.data[d + k] = img.data[s + k]
