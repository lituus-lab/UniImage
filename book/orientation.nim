# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/base64
import nimib, nimibook
import lituus_theme
import UniImage

nbInit(theme = useNimibook)
useLituus()
nb.title = "Display orientation"

nbText: """
## Display orientation

Decoded pixels retain their stored order. `applyExifOrientation` normalizes
that buffer for display using the EXIF Orientation value. It handles all eight
values, including mirrored camera output, without resampling.
"""

nbCode:
  var landscape = newImage[uint8](3, 2, csGray)
  landscape.data = @[1'u8, 2, 3, 4, 5, 6]
  let portrait = landscape.applyExifOrientation(6)
  doAssert (portrait.width, portrait.height) == (2, 3)
  doAssert portrait.data == @[4'u8, 1, 5, 2, 6, 3]

nbText: """
"""

nbSave
