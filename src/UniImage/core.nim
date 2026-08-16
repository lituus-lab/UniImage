# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Core image model: error codes, color spaces, and a generic `Image[Pixel]`
## buffer.
import contracts

type
  UniImageError* = enum
    uiOk          ## success
    uiUnsupported ## container/format not handled (yet)
    uiTruncated   ## input ended before the declared length
    uiInvalidArg  ## caller-supplied argument was invalid
    uiEncoding    ## encoder could not represent the image
    uiIo          ## read/write failure

  UniImageException* = ref object of CatchableError
    ## Raised by codecs on a `UniImageError`. The C ABI traps `CatchableError`
    ## at the boundary and maps it to a status code; the `code` field carries
    ## the specific one so the Nim API stays explicit.
    code*: UniImageError

  Colorspace* = enum
    csGray    ## single luma channel
    csRgb     ## 3 channels, no alpha
    csRgba    ## 4 channels, alpha last
    csCmyk    ## 4 channels, subtractive
    csYuv     ## luma + chroma
    csIndexed ## palette-mapped

  Image*[P] = object
    width*: int
    height*: int
    channels*: int
    colorspace*: Colorspace
    data*: seq[P]

const ChannelCount*: array[Colorspace, int] = [1, 3, 4, 4, 3, 1]

proc validPackedImage*[P](image: Image[P]): bool {.inline.} =
  ## Return whether dimensions, colorspace, channel count, and packed storage
  ## describe one complete image without overflowing an `int` length.
  if image.width <= 0 or image.height <= 0 or
      image.channels != ChannelCount[image.colorspace]:
    return false
  if image.width > high(int) div image.height:
    return false
  let pixels = image.width * image.height
  if pixels > high(int) div image.channels:
    return false
  image.data.len == pixels * image.channels

proc newImage*[P](width, height: int; cs: Colorspace = csRgb): Image[
    P] {.contractual.} =
  ## Allocate a zeroed `Image[P]` of `width` x `height` in the requested color
  ## space.
  ##
  ## .. code-block:: nim
  ##   var img: Image[uint8] = newImage[uint8](2, 2, csRgb)
  require:
    width > 0 and height > 0
  ensure:
    result.width == width and result.height == height
    result.data.len == width * height * ChannelCount[cs]
    result.colorspace == cs
  body:
    result.width = width
    result.height = height
    result.channels = ChannelCount[cs]
    result.colorspace = cs
    result.data = newSeq[P](width * height * result.channels)

proc sizeBytes*[P](img: Image[P]): int {.inline.} =
  ## Bytes occupied by `img.data` (element count times element size).
  img.data.len * sizeof(P)
