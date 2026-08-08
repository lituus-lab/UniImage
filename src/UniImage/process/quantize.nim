# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Palette extraction for 8-bit raster images.
##
## UniColor owns the Wu, k-means, k-means++, median-cut, octree and NeuQuant
## implementations. This module only validates and adapts UniImage's packed
## grayscale/RGB/RGBA storage to UniColor's typed sRGB pixels.
import UniImage/core as uiCore
import UniColor/core/color as ucColor
import UniColor/core/color_error as ucError
import UniColor/core/result as ucResult
import UniColor/core/space_tag as ucSpace
import UniColor/image/internal as ucInternal
import UniColor/image/quantize as ucQuantize
import UniColor/palette/types as ucPalette
{.push warning[UnusedImport]: off.}
# Importing these modules registers their algorithms in UniColor's registry.
from UniColor/image/quantize_wu import nil
from UniColor/image/quantize_kmeans import nil
from UniColor/image/quantize_misc import nil
{.pop.}

export ucColor, ucError, ucResult, ucSpace

type
  QuantizeOpts* = ucQuantize.QuantizeOpts
  Palette* = ucPalette.Palette
  PaletteTag* = ucPalette.PaletteTag
  PaletteIntent* = ucPalette.PaletteIntent
  Color* = ucColor.Color

const
  DefaultQuantizeAlgo* = ucQuantize.DefaultQuantizeAlgo
  DefaultQuantizeSpace* = ucQuantize.DefaultQuantizeSpace
  DefaultQuantizeMaxIter* = ucQuantize.DefaultQuantizeMaxIter

proc defaultQuantizeOpts*(): QuantizeOpts {.inline, raises: [].} =
  ## Return UniColor's deterministic reference options.
  ucQuantize.defaultQuantizeOpts()

proc len*(palette: Palette): int {.inline, raises: [].} =
  ## Number of colors produced by the quantizer.
  ucPalette.len(palette)

proc colors*(palette: Palette): seq[Color] {.inline, raises: [].} =
  ## Copy the colors produced by the quantizer.
  ucPalette.colors(palette)

proc tag*(palette: Palette): PaletteTag {.inline, raises: [].} =
  ## Structural palette tag produced by UniColor.
  ucPalette.tag(palette)

proc intent*(palette: Palette): PaletteIntent {.inline, raises: [].} =
  ## Semantic intent produced by UniColor.
  ucPalette.intent(palette)

proc seed*(palette: Palette): int64 {.inline, raises: [].} =
  ## Seed recorded by the quantizer.
  ucPalette.seed(palette)

proc invalidImage(message: string): ucResult.Result[ucInternal.Image,
    ucError.ColorError] {.inline, raises: [].} =
  ucResult.err[ucInternal.Image, ucError.ColorError](ucError.colorError(
      ucError.ColorErrorKind.InvalidImage, message, "UniImage.extractPalette"))

proc toColorImage(img: uiCore.Image[uint8]): ucResult.Result[ucInternal.Image,
    ucError.ColorError] {.raises: [].} =
  if img.width <= 0 or img.height <= 0:
    return invalidImage("image dimensions must be positive")
  if img.channels != uiCore.ChannelCount[img.colorspace]:
    return invalidImage("channel count disagrees with the image colorspace")
  if img.width > high(int) div img.height:
    return invalidImage("image dimensions overflow the addressable size")
  let pixels = img.width * img.height
  if pixels > high(int) div img.channels or
      img.data.len != pixels * img.channels:
    return invalidImage("pixel buffer length disagrees with image dimensions")
  if img.colorspace notin {csGray, csRgb, csRgba}:
    return invalidImage("palette extraction supports Gray, RGB and RGBA images")

  var colors = newSeq[ucColor.Color](pixels)
  for i in 0 ..< pixels:
    let offset = i * img.channels
    var r, g, b, a: float32
    case img.colorspace
    of csGray:
      r = img.data[offset].float32 / 255.0'f32
      g = r
      b = r
      a = 1.0'f32
    of csRgb:
      r = img.data[offset].float32 / 255.0'f32
      g = img.data[offset + 1].float32 / 255.0'f32
      b = img.data[offset + 2].float32 / 255.0'f32
      a = 1.0'f32
    of csRgba:
      r = img.data[offset].float32 / 255.0'f32
      g = img.data[offset + 1].float32 / 255.0'f32
      b = img.data[offset + 2].float32 / 255.0'f32
      a = img.data[offset + 3].float32 / 255.0'f32
    else:
      discard
    let colorResult = ucColor.color(ucSpace.tagSrgb, r, g, b, a)
    if colorResult.isErr:
      return ucResult.err[ucInternal.Image, ucError.ColorError](
          colorResult.error)
    colors[i] = colorResult.get
  ucInternal.image(img.width, img.height, colors, ucSpace.tagSrgb, 8,
      ucInternal.Gamut.gamutSdr)

proc extractPalette*(img: uiCore.Image[uint8]; n: int;
    algo = DefaultQuantizeAlgo; space = DefaultQuantizeSpace;
    opts = defaultQuantizeOpts()): ucResult.Result[Palette,
    ucError.ColorError] {.raises: [].} =
  ## Extract at most `n` perceptual colors with a UniColor quantizer.
  ##
  ## Algorithms are `wu`, `kmeans`, `kmeansPP`, `medianCut`, `octree` and
  ## `neuquant`. Grayscale, RGB and RGBA inputs are accepted; alpha reaches
  ## UniColor as straight alpha but does not participate in the historical
  ## three-component quantizers. Other packed colorspaces return InvalidImage.
  let converted = toColorImage(img)
  if converted.isErr:
    return ucResult.err[Palette, ucError.ColorError](converted.error)
  ucQuantize.extractPalette(converted.get, n, algo, space, opts)
