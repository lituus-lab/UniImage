# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/unittest
import UniImage
import UniColor/core/core

proc sampleImage(): Image[uint8] =
  result = newImage[uint8](3, 2, csRgb)
  result.data = @[
    255'u8, 0, 0, 0, 255, 0, 0, 0, 255,
    255, 255, 255, 0, 0, 0, 255, 255, 0
  ]

suite "palette extraction through UniColor":
  test "all historical quantizers are reachable and deterministic":
    let img = sampleImage()
    for name in ["wu", "kmeans", "kmeansPP", "medianCut", "octree",
        "neuquant"]:
      let first = img.extractPalette(3, name)
      let second = img.extractPalette(3, name)
      check first.isOk
      check second.isOk
      if first.isOk and second.isOk:
        check first.get.len > 0
        check first.get.len <= 3
        check first.get.colors == second.get.colors

  test "grayscale and RGBA adapt to sRGB pixels":
    var gray = newImage[uint8](2, 1, csGray)
    gray.data = @[0'u8, 255]
    check gray.extractPalette(2, "wu").isOk

    var rgba = newImage[uint8](2, 1, csRgba)
    rgba.data = @[255'u8, 0, 0, 64, 0, 0, 255, 192]
    check rgba.extractPalette(2, "medianCut").isOk

  test "invalid requests remain explicit UniColor errors":
    let img = sampleImage()
    check img.extractPalette(0).error.kind == ColorErrorKind.InvalidOp
    check img.extractPalette(2, "missing").error.kind ==
      ColorErrorKind.UnknownAlgorithm

    var cmyk = newImage[uint8](1, 1, csCmyk)
    cmyk.data = @[0'u8, 0, 0, 0]
    check cmyk.extractPalette(1).error.kind == ColorErrorKind.InvalidImage
