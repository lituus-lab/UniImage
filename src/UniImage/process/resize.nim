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
## Reimplemented from standard sampling theory (not vendored). Operates on
## `Image[uint8]`; the colorspace and channel count are preserved.
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
  ## (so the allocation size cannot overflow/wrap) and refuses runaway
  ## allocations early. Reached only through the C ABI, which takes `cint` dims.

proc resize*(img: Image[uint8]; w, h: int; filter = rfBilinear): Image[uint8] =
  ## Resize `img` to `w` x `h` using `filter`. Preserves the colorspace and
  ## channel count. Raises `UniImageException(uiInvalidArg)` for non-positive
  ## or oversized dimensions.
  if w <= 0 or h <= 0:
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: non-positive dims")
  # The float intermediate holds `w * img.height` pixels; the result holds
  # `w * h`. Bound both against `MaxResizePixels` before any allocation.
  if int64(w) * int64(img.height) > MaxResizePixels or
      int64(w) * int64(h) > MaxResizePixels:
    raise UniImageException(code: uiInvalidArg,
        msg: "resize: dimensions too large")
  result = newImage[uint8](w, h, img.colorspace)
  let ch = img.channels
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
  for y in 0 ..< ih:
    for dx in 0 ..< w:
      let row = hw[dx]
      for c in 0 ..< ch:
        var acc = 0.0'f32
        for wt in row: acc += wt.w * float32(img.data[(y * img.width + wt.i) *
            ch + c])
        inter[(y * iw + dx) * ch + c] = acc
  for dy in 0 ..< h:
    let row = vw[dy]
    for dx in 0 ..< w:
      for c in 0 ..< ch:
        var acc = 0.0'f32
        for wt in row: acc += wt.w * inter[(wt.i * iw + dx) * ch + c]
        result.data[(dy * w + dx) * ch + c] = clampF32(acc)
