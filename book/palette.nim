# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "Perceptual palettes"

nbText: """
## Perceptual palette extraction

UniImage converts packed 8-bit pixels to UniColor's typed sRGB representation.
The actual Wu, k-means, k-means++, median-cut, octree, and NeuQuant algorithms
remain owned by UniColor; there is no duplicate implementation here.
"""

nbCode:
  var swatches = newImage[uint8](3, 1, csRgb)
  swatches.data = @[255'u8, 0, 0, 0, 255, 0, 0, 0, 255]
  let paletteResult = swatches.extractPalette(3, "wu")
  doAssert paletteResult.isOk
  doAssert paletteResult.get.len == 3

nbText: """
"""

nbSave
