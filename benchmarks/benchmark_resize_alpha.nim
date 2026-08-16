# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[json, monotimes, os, stats, strutils, times]
import UniImage/process

const
  SourceWidth = 1024
  SourceHeight = 1024
  TargetWidth = 800
  TargetHeight = 600
  WarmupIterations = 3

proc elapsedMs(started: MonoTime): float64 =
  inNanoseconds(getMonoTime() - started).float64 / 1_000_000.0

proc summary(samples: RunningStat): JsonNode =
  %*{
    "mean_ms": samples.mean,
    "stdev_ms": samples.standardDeviationS,
    "min_ms": samples.min,
    "max_ms": samples.max,
    "output_megapixels_per_second":
      (TargetWidth * TargetHeight).float64 / 1_000.0 / samples.mean
  }

proc fill(image: var Image[uint8]; translucent: bool) =
  for pixel in 0 ..< image.width * image.height:
    let offset = pixel * image.channels
    image.data[offset] = uint8(pixel mod 251)
    image.data[offset + 1] = uint8((pixel * 3) mod 253)
    image.data[offset + 2] = uint8((pixel * 7) mod 255)
    if image.colorspace == csRgba:
      image.data[offset + 3] = if translucent:
        uint8(pixel mod 256) else: 255'u8

proc main() =
  let params = commandLineParams()
  if params.len > 2:
    quit("usage: benchmark_resize_alpha [iterations] [output.json]", 2)
  let iterations = if params.len >= 1: parseInt(params[0]) else: 10
  if iterations < 1: quit("iterations must be positive", 2)

  var
    rgb = newImage[uint8](SourceWidth, SourceHeight, csRgb)
    opaque = newImage[uint8](SourceWidth, SourceHeight, csRgba)
    translucent = newImage[uint8](SourceWidth, SourceHeight, csRgba)
    rgbTimes, opaqueTimes, translucentTimes, translucentBoxTimes: RunningStat
    guard = 0'u8
  rgb.fill(false)
  opaque.fill(false)
  translucent.fill(true)
  for iteration in 0 ..< iterations + WarmupIterations:
    var started = getMonoTime()
    let rgbOutput = rgb.resize(TargetWidth, TargetHeight, rfBilinear)
    let rgbMs = elapsedMs(started)
    guard = guard xor rgbOutput.data[iteration mod rgbOutput.data.len]

    started = getMonoTime()
    let opaqueOutput = opaque.resize(TargetWidth, TargetHeight, rfBilinear)
    let opaqueMs = elapsedMs(started)
    guard = guard xor opaqueOutput.data[iteration mod opaqueOutput.data.len]

    started = getMonoTime()
    let translucentOutput = translucent.resize(TargetWidth, TargetHeight,
      rfBilinear)
    let translucentMs = elapsedMs(started)
    guard = guard xor translucentOutput.data[
      iteration mod translucentOutput.data.len]

    started = getMonoTime()
    let translucentBoxOutput = translucent.resize(TargetWidth, TargetHeight,
      rfBox)
    let translucentBoxMs = elapsedMs(started)
    guard = guard xor translucentBoxOutput.data[
      iteration mod translucentBoxOutput.data.len]
    if iteration >= WarmupIterations:
      rgbTimes.push(rgbMs)
      opaqueTimes.push(opaqueMs)
      translucentTimes.push(translucentMs)
      translucentBoxTimes.push(translucentBoxMs)

  let report = %*{
    "provider": "UniImage",
    "operation": "weighted-resize",
    "alpha_semantics": "RGBA filters in premultiplied space and publishes straight alpha",
    "iterations": iterations,
    "warmup_iterations": WarmupIterations,
    "source": $SourceWidth & "x" & $SourceHeight,
    "target": $TargetWidth & "x" & $TargetHeight,
    "rgb": summary(rgbTimes),
    "opaque_rgba": summary(opaqueTimes),
    "translucent_rgba": summary(translucentTimes),
    "translucent_rgba_box": summary(translucentBoxTimes),
    "guard": guard
  }
  let encoded = $report
  echo encoded
  if params.len == 2: writeFile(params[1], encoded & "\n")

main()
