# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[algorithm, json, os, osproc, strutils, times]

const
  DefaultRuns = 3
  DefaultIterations = 20
  FullPixels = 1920 * 1080
  HalfPixels = FullPixels div 2

proc median(values: seq[float64]): float64 =
  var ordered = values
  ordered.sort()
  ordered[ordered.len div 2]

proc commandValue(command: string; args: openArray[string]): string =
  try:
    execProcess(command, args = args, options = {poUsePath}).strip
  except OSError:
    "unknown"

proc phaseSummary(reports: seq[JsonNode]; phase: string;
                  pixels: int): JsonNode =
  var means = newSeq[float64](reports.len)
  for index, report in reports:
    means[index] = report[phase]["mean_ms"].getFloat
  let middle = median(means)
  %*{
    "run_mean_ms": means,
    "median_run_mean_ms": middle,
    "median_megapixels_per_second": pixels.float64 / 1_000.0 / middle
  }

proc main() =
  let params = commandLineParams()
  if params.len > 4:
    quit("usage: run_composite_baseline [binary] [output] [runs] [iterations]",
      2)
  let
    binary = if params.len >= 1: params[0] else: "build/benchmark_composite"
    output = if params.len >= 2: params[1] else:
      "build/composite-baseline.json"
    runs = if params.len >= 3: parseInt(params[2]) else: DefaultRuns
    iterations = if params.len >= 4: parseInt(params[3]) else:
      DefaultIterations
  if runs < 1 or (runs and 1) == 0 or iterations < 1:
    quit("runs must be positive and odd; iterations must be positive", 2)
  if not fileExists(binary):
    quit("benchmark binary not found: " & binary, 2)

  var reports = newSeq[JsonNode](runs)
  for run in 0 ..< runs:
    reports[run] = parseJson(execProcess(binary, args = @[$iterations],
      options = {poStdErrToStdOut}))
    if reports[run]["provider"].getStr != "UniImage" or
        reports[run]["iterations"].getInt != iterations:
      quit("benchmark report does not match the requested protocol", 1)

  let
    detectedMachine = when defined(macosx): commandValue("sysctl", ["-n",
      "machdep.cpu.brand_string"])
      else: "unspecified"
    configuredMachine = getEnv("UNIIMAGE_BENCH_MACHINE")
    machine = if configuredMachine.len > 0: configuredMachine
      elif detectedMachine.len > 0: detectedMachine
      else: "unspecified"
  let report = %*{
    "date": now().format("yyyy-MM-dd"),
    "machine": machine,
    "architecture": hostCPU,
    "os": hostOS,
    "os_version": when defined(macosx): commandValue("sw_vers",
      ["-productVersion"])
      else: "unspecified",
    "nim": NimVersion,
    "build": "-d:release",
    "canvas": reports[0]["canvas"],
    "runs": runs,
    "iterations_per_run": iterations,
    "warmup_iterations": reports[0]["warmup_iterations"],
    "opaque_rgb": phaseSummary(reports, "opaque_rgb", FullPixels),
    "translucent_rgba": phaseSummary(reports, "translucent_rgba", FullPixels),
    "half_clipped_rgba": phaseSummary(reports, "half_clipped_rgba", HalfPixels)
  }
  let encoded = pretty(report)
  echo encoded
  writeFile(output, encoded & "\n")

main()
