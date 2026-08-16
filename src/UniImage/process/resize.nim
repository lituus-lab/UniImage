# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Image resize (downscale + upscale). Three filters:
##   * `rfNearest` — point sample, fastest; exact identity at same size.
##   * `rfBilinear` — separable linear interpolation with edge clamping; good
##     for upscaling. Default.
##   * `rfBox` — area-average: each output pixel is the weighted average of the
##     source pixels overlapping its footprint. Correct for downscaling
##     (thumbnails). For upscaling the footprint is narrower than one source
##     pixel, so each output blends the one or two source pixels it overlaps
##     (a box kernel — distinct from bilinear's distance-weighted blend).
## RGBA filtering is performed in premultiplied-alpha space and converted back
## to the public straight-alpha representation. This prevents invisible RGB
## values in transparent pixels from producing coloured fringes.
## Reimplemented from standard sampling theory (not vendored). Operates on
## `Image[uint8]`; the colorspace and channel count are preserved.
import contracts
import UniImage/core

type
  ResizeFilter* = enum
    rfNearest  ## point sample
    rfBilinear ## separable linear, edge-clamped
    rfBox      ## area-average (downscale-correct)

proc clampF32(v: float32): uint8 {.inline.} =
  if v <= 0'f32: 0'u8
  elif v >= 255'f32: 255'u8
  else: uint8(v + 0.5'f32)

# A 1D resample weight row: (source index, weight). Weights already sum to 1
# (bilinear by construction; box normalised per output sample).
type Weight = tuple[i: int, w: float32]

proc bilinearWeights(M, N: int): seq[seq[Weight]] =
  result = newSeq[seq[Weight]](N)
  for d in 0 ..< N:
    # Centre the sample: source coordinate of output d's centre, in source
    # pixels, then clamp to the valid pixel range so edges replicate.
    let s = clamp((float32(d) + 0.5'f32) * float32(M) / float32(N) - 0.5'f32,
        0.0'f32, float32(M) - 1.0'f32)
    let j0 = int(s)
    let frac = s - float32(j0)
    let j1 = min(j0 + 1, M - 1)
    var row: seq[Weight]
    row.add (j0, 1.0'f32 - frac)
    if j1 != j0: row.add (j1, frac)
    result[d] = row

proc boxWeights(M, N: int): seq[seq[Weight]] =
  result = newSeq[seq[Weight]](N)
  for d in 0 ..< N:
    let x0 = float32(d) * float32(M) / float32(N)
    let x1 = float32(d + 1) * float32(M) / float32(N)
    var row: seq[Weight]
    var sumW = 0.0'f32
    var j = int(x0)
    while float32(j) < x1 and j < M:
      if j >= 0:
        let left = max(x0, float32(j))
        let right = min(x1, float32(j + 1))
        let wt = right - left
        if wt > 0.0'f32: row.add (j, wt); sumW += wt
      inc j
    if sumW > 0.0'f32:
      for k in 0 ..< row.len: row[k] = (row[k].i, row[k].w / sumW)
    else:
      row.add (max(0, min(M - 1, d)), 1.0'f32)
    result[d] = row

proc buildWeights(filter: ResizeFilter; M, N: int): seq[seq[Weight]] =
  case filter
  of rfBilinear: bilinearWeights(M, N)
  of rfBox: boxWeights(M, N)
  of rfNearest: @[] # nearest has no weights; handled inline

const MaxResizePixels = 1'i64 shl 30
  ## Upper bound on the output pixel count and the float-intermediate pixel
  ## count. Beyond any real image, it keeps `w * h * channels` within `int64`
  ## and refuses runaway allocations early.

proc productExceeds(a, b, c: int; limit: uint64): bool {.inline.} =
  if a <= 0 or b <= 0 or c <= 0: return true
  let
    first = uint64(a)
    second = uint64(b)
    third = uint64(c)
  first > limit div second or first * second > limit div third

proc resizeImpl(img: Image[uint8]; w, h: int;
                filter: ResizeFilter): Image[uint8] =
  ## Resize `img` to `w` x `h` using `filter`. Preserves the colorspace and
  ## channel count. Raises `UniImageException(uiInvalidArg)` for non-positive
  ## or oversized dimensions.
  if not img.validPackedImage:
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: malformed source image")
  if w <= 0 or h <= 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: non-positive dims")
  # The float intermediate holds `w * img.height` pixels; the result holds
  # `w * h`. Bound both against `MaxResizePixels` before any allocation.
  if productExceeds(w, img.height, 1, uint64(MaxResizePixels)) or
      productExceeds(w, h, 1, uint64(MaxResizePixels)) or
      productExceeds(w, img.height, img.channels, uint64(high(int))) or
      productExceeds(w, h, img.channels, uint64(high(int))):
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: dimensions too large")
  let ch = img.channels
  if filter != rfNearest and productExceeds(w, img.height, ch,
      uint64(high(int) div sizeof(float32))):
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: float intermediate too large")
  result = newImage[uint8](w, h, img.colorspace)
  if filter == rfNearest:
    for dy in 0 ..< h:
      let sy = min(img.height - 1,
          int((float32(dy) + 0.5'f32) * float32(img.height) / float32(h)))
      for dx in 0 ..< w:
        let sx = min(img.width - 1,
            int((float32(dx) + 0.5'f32) * float32(img.width) / float32(w)))
        let s = (sy * img.width + sx) * ch
        let d = (dy * w + dx) * ch
        for c in 0 ..< ch: result.data[d + c] = img.data[s + c]
    return
  # Separable: horizontal pass (img.width -> w) into a float intermediate,
  # then vertical pass (img.height -> h) into the uint8 result. Both passes
  # share the same weight-builder by filter; weights already sum to 1.
  let hw = buildWeights(filter, img.width, w)
  let vw = buildWeights(filter, img.height, h)
  let iw = w
  let ih = img.height
  var inter = newSeq[float32](iw * ih * ch)
  if img.colorspace == csRgba:
    for y in 0 ..< ih:
      for dx in 0 ..< w:
        let row = hw[dx]
        var accumulated: array[4, float32]
        for wt in row:
          let
            source = (y * img.width + wt.i) * 4
            alpha = float32(img.data[source + 3])
            premultiply = wt.w * alpha / 255'f32
          for channel in 0 ..< 3:
            accumulated[channel] += premultiply *
              float32(img.data[source + channel])
          accumulated[3] += wt.w * alpha
        let destination = (y * iw + dx) * 4
        for channel in 0 ..< 4:
          inter[destination + channel] = accumulated[channel]
    for dy in 0 ..< h:
      let row = vw[dy]
      for dx in 0 ..< w:
        var accumulated: array[4, float32]
        for wt in row:
          let source = (wt.i * iw + dx) * 4
          for channel in 0 ..< 4:
            accumulated[channel] += wt.w * inter[source + channel]
        let destination = (dy * w + dx) * 4
        let alpha = clampF32(accumulated[3])
        result.data[destination + 3] = alpha
        if alpha > 0:
          for channel in 0 ..< 3:
            result.data[destination + channel] = if alpha == 255:
              clampF32(accumulated[channel])
            else:
              clampF32(accumulated[channel] * 255'f32 / accumulated[3])
  else:
    for y in 0 ..< ih:
      for dx in 0 ..< w:
        let row = hw[dx]
        for c in 0 ..< ch:
          var acc = 0.0'f32
          for wt in row:
            acc += wt.w * float32(img.data[(y * img.width + wt.i) * ch + c])
          inter[(y * iw + dx) * ch + c] = acc
    for dy in 0 ..< h:
      let row = vw[dy]
      for dx in 0 ..< w:
        for c in 0 ..< ch:
          var acc = 0.0'f32
          for wt in row:
            acc += wt.w * inter[(wt.i * iw + dx) * ch + c]
          result.data[(dy * w + dx) * ch + c] = clampF32(acc)

proc resize*(img: Image[uint8]; w, h: int;
             filter = rfBilinear): Image[uint8] {.contractual.} =
  ## Resize a valid packed image with a release-safe runtime validation at the
  ## public boundary.
  require:
    img.validPackedImage
  body:
    result = resizeImpl(img, w, h, filter)
