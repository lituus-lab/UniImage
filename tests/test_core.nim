# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Core image-model tests.
import std/unittest
import UniImage/core

suite "core Image":
  test "newImage allocates the right channel count":
    var img = newImage[uint8](2, 3, csRgb)
    check img.width == 2
    check img.height == 3
    check img.channels == 3
    check img.colorspace == csRgb
    check img.data.len == 2 * 3 * 3

  test "csRgba has 4 channels":
    var img = newImage[uint8](1, 1, csRgba)
    check img.channels == 4
    check img.data.len == 4

  test "csGray has 1 channel":
    var img = newImage[uint8](4, 4, csGray)
    check img.channels == 1
    check img.data.len == 16

  test "sizeBytes counts bytes not elements":
    var img = newImage[uint8](2, 2, csRgb)
    check img.sizeBytes() == 2 * 2 * 3 * sizeof(uint8)
