# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "Alpha-correct resizing"

nbText: """
## Alpha-correct resizing

Nearest-neighbour resizing preserves every byte. Bilinear and box filters
instead interpolate RGBA in premultiplied-alpha space and return straight
alpha. Colours stored behind fully transparent pixels therefore cannot create
halos around a visible edge.
"""

nbCode:
  var alphaEdge = newImage[uint8](2, 1, csRgba)
  alphaEdge.data = @[255'u8, 0, 0, 0, 0, 0, 255, 255]
  let enlargedEdge = alphaEdge.resize(240, 80, rfBilinear)
  doAssert enlargedEdge.data[0 .. 3] == @[0'u8, 0, 0, 0]
  doAssert enlargedEdge.data[^4 .. ^1] == @[0'u8, 0, 255, 255]

nbRawHtml: """
<figure><img alt="Alpha-correct blue edge resized over transparency"
style="max-width:100%;image-rendering:pixelated" src="data:image/png;base64,""" &
  base64.encode(enlargedEdge.encodeImage(efPng)) & """">
<figcaption>The hidden red transparent pixel contributes no red fringe.</figcaption>
</figure>
"""

nbText: """
## Straight-alpha compositing

`compositeOver` places Gray, RGB, or straight-alpha RGBA pixels over an RGBA
destination. Coordinates are integer pixels and clip at every edge. Opacity is
an exact 0–255 multiplier. Channel divisions use round-to-nearest with halves
rounded upward, so the same bytes are produced by Nim, C, and Python. Aliased
source and destination buffers are snapshotted before writes.
"""

nbCode:
  var canvas = newImage[uint8](240, 120, csRgba)
  for pixel in 0 ..< canvas.width * canvas.height:
    canvas.data[pixel * 4] = 32
    canvas.data[pixel * 4 + 1] = 48
    canvas.data[pixel * 4 + 2] = 80
    canvas.data[pixel * 4 + 3] = 255
  var overlay = newImage[uint8](120, 80, csRgba)
  for row in 0 ..< overlay.height:
    for column in 0 ..< overlay.width:
      let offset = (row * overlay.width + column) * 4
      overlay.data[offset] = 240
      overlay.data[offset + 1] = uint8(40 + column)
      overlay.data[offset + 2] = 72
      overlay.data[offset + 3] = uint8(64 + row * 2)
  canvas.compositeOver(overlay, 60, 20, 224)
  doAssert canvas.data.len == 240 * 120 * 4

nbRawHtml: """
<figure><img alt="UniImage straight-alpha compositing demonstration"
style="max-width:100%;image-rendering:pixelated" src="data:image/png;base64,""" &
  base64.encode(canvas.encodeImage(efPng)) & """">
<figcaption>Executable RGBA source-over output embedded directly in this HTML.</figcaption>
</figure>
"""

nbText: """
"""

nbSave
