# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Deterministic straight-alpha source-over compositing for packed 8-bit images.
import contracts
import UniImage/core

proc validCompositeSource(image: Image[uint8]): bool {.inline.} =
  image.validPackedImage and image.colorspace in {csGray, csRgb, csRgba}

proc invalidArgument(message: string): UniImageException {.inline.} =
  UniImageException(code: uiInvalidArg, msg: message)

proc roundedDivide(numerator, denominator: uint64): uint64 {.inline.} =
  (numerator + denominator div 2'u64) div denominator

proc compositeOver*(destination: var Image[uint8]; source: Image[uint8];
                    x, y: int; opacity = 255'u8) {.contractual.} =
  ## Composite `source` over an RGBA destination at integer pixel `(x, y)`.
  ##
  ## Source pixels may be grayscale, RGB or straight-alpha RGBA. Grayscale is
  ## replicated to RGB; grayscale and RGB are opaque before `opacity` is
  ## applied. Pixels outside the destination are clipped. Source and
  ## destination may share the same buffer: the operation behaves as if the
  ## source were snapshotted before the first write.
  require:
    destination.validPackedImage and destination.colorspace == csRgba
    source.validCompositeSource
  ensure:
    destination.colorspace == csRgba and destination.channels == 4
    destination.validPackedImage
  body:
    if not destination.validPackedImage or destination.colorspace != csRgba:
      raise invalidArgument("compositeOver: destination must be valid RGBA8")
    if not source.validCompositeSource:
      raise invalidArgument("compositeOver: source must be valid Gray/RGB/RGBA8")
    if opacity == 0'u8 or x >= destination.width or y >= destination.height or
        x <= -source.width or y <= -source.height:
      return

    let
      sourceX = if x < 0: -x else: 0
      sourceY = if y < 0: -y else: 0
      destinationX = if x > 0: x else: 0
      destinationY = if y > 0: y else: 0
      copyWidth = min(source.width - sourceX,
        destination.width - destinationX)
      copyHeight = min(source.height - sourceY,
        destination.height - destinationY)
      aliases = destination.data[0].addr == source.data[0].unsafeAddr
    var
      sourceCopy: seq[uint8]
      sourceData: ptr UncheckedArray[uint8]
    if aliases:
      sourceCopy = newSeq[uint8](source.data.len)
      copyMem(sourceCopy[0].addr, source.data[0].unsafeAddr, source.data.len)
      sourceData = cast[ptr UncheckedArray[uint8]](sourceCopy[0].addr)
    else:
      sourceData = cast[ptr UncheckedArray[uint8]](source.data[0].unsafeAddr)

    if opacity == 255'u8 and source.colorspace != csRgba:
      for row in 0 ..< copyHeight:
        for column in 0 ..< copyWidth:
          let
            sourceOffset = ((sourceY + row) * source.width + sourceX +
              column) * source.channels
            destinationOffset = ((destinationY + row) * destination.width +
              destinationX + column) * 4
          for channel in 0 ..< 3:
            destination.data[destinationOffset + channel] =
              if source.colorspace == csGray: sourceData[sourceOffset]
              else: sourceData[sourceOffset + channel]
          destination.data[destinationOffset + 3] = 255
      return

    for row in 0 ..< copyHeight:
      for column in 0 ..< copyWidth:
        let
          sourceOffset = ((sourceY + row) * source.width + sourceX + column) *
            source.channels
          destinationOffset = ((destinationY + row) * destination.width +
            destinationX + column) * 4
          sourceAlpha = if source.colorspace == csRgba:
            uint64(sourceData[sourceOffset + 3])
          else:
            255'u64
          alpha = roundedDivide(sourceAlpha * uint64(opacity), 255'u64)
          inverseAlpha = 255'u64 - alpha
          destinationAlpha = uint64(destination.data[destinationOffset + 3])

        if alpha == 0'u64:
          continue
        if alpha == 255'u64:
          for channel in 0 ..< 3:
            destination.data[destinationOffset + channel] =
              if source.colorspace == csGray: sourceData[sourceOffset]
              else: sourceData[sourceOffset + channel]
          destination.data[destinationOffset + 3] = 255
          continue
        if destinationAlpha == 0'u64:
          for channel in 0 ..< 3:
            destination.data[destinationOffset + channel] =
              if source.colorspace == csGray: sourceData[sourceOffset]
              else: sourceData[sourceOffset + channel]
          destination.data[destinationOffset + 3] = uint8(alpha)
          continue

        let
          outputAlphaNumerator = alpha * 255'u64 +
            destinationAlpha * inverseAlpha
          outputAlpha = roundedDivide(outputAlphaNumerator, 255'u64)
        for channel in 0 ..< 3:
          let
            sourceChannel = if source.colorspace == csGray:
              uint64(sourceData[sourceOffset])
            else:
              uint64(sourceData[sourceOffset + channel])
            destinationChannel = uint64(destination.data[
              destinationOffset + channel])
          let premultiplied = sourceChannel * alpha * 255'u64 +
            destinationChannel * destinationAlpha * inverseAlpha
          destination.data[destinationOffset + channel] = uint8(
            roundedDivide(premultiplied, outputAlphaNumerator))
        destination.data[destinationOffset + 3] = uint8(outputAlpha)
