# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[json, monotimes, os, stats, strutils, times]
import UniImage/process

const
  Width = 1920
  Height = 1080
  WarmupIterations = 3

proc elapsedMs(started: MonoTime): float64 =
  inNanoseconds(getMonoTime() - started).float64 / 1_000_000.0

proc summary(samples: RunningStat; pixelsPerIteration: int): JsonNode =
  %*{
    "mean_ms": samples.mean,
    "stdev_ms": samples.standardDeviationS,
    "min_ms": samples.min,
    "max_ms": samples.max,
    "megapixels_per_second":
      pixelsPerIteration.float64 / 1_000.0 / samples.mean
  }

proc fillSource(image: var Image[uint8]) =
  for pixel in 0 ..< image.width * image.height:
    let offset = pixel * image.channels
    image.data[offset] = uint8(pixel mod 251)
    if image.channels >= 3:
      image.data[offset + 1] = uint8((pixel * 3) mod 253)
      image.data[offset + 2] = uint8((pixel * 7) mod 255)
    if image.colorspace == csRgba:
      image.data[offset + 3] = uint8(64 + pixel mod 192)

proc main() =
  let params = commandLineParams()
  if params.len > 2:
    quit("usage: benchmark_composite [iterations] [output.json]", 2)
  let iterations = if params.len >= 1: parseInt(params[0]) else: 20
  if iterations < 1:
    quit("iterations must be positive", 2)

  var
    destination = newImage[uint8](Width, Height, csRgba)
    opaque = newImage[uint8](Width, Height, csRgb)
    translucent = newImage[uint8](Width, Height, csRgba)
    opaqueTimes, translucentTimes, clippedTimes: RunningStat
  for pixel in 0 ..< Width * Height:
    destination.data[pixel * 4 + 3] = 255
  opaque.fillSource()
  translucent.fillSource()

  for iteration in 0 ..< iterations + WarmupIterations:
    var started = getMonoTime()
    destination.compositeOver(opaque, 0, 0)
    let opaqueMs = elapsedMs(started)

    started = getMonoTime()
    destination.compositeOver(translucent, 0, 0, 192)
    let translucentMs = elapsedMs(started)

    started = getMonoTime()
    destination.compositeOver(translucent, -(Width div 2), 0, 192)
    let clippedMs = elapsedMs(started)
    if iteration >= WarmupIterations:
      opaqueTimes.push(opaqueMs)
      translucentTimes.push(translucentMs)
      clippedTimes.push(clippedMs)

  let report = %*{
    "provider": "UniImage",
    "operation": "straight-alpha-source-over",
    "iterations": iterations,
    "warmup_iterations": WarmupIterations,
    "canvas": $Width & "x" & $Height,
    "opaque_rgb": summary(opaqueTimes, Width * Height),
    "translucent_rgba": summary(translucentTimes, Width * Height),
    "half_clipped_rgba": summary(clippedTimes, Width * Height div 2),
    "guard": destination.data[0]
  }
  let encoded = $report
  echo encoded
  if params.len == 2:
    writeFile(params[1], encoded & "\n")

main()
